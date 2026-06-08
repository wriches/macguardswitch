#!/bin/bash
#
# Rebuild the double-click launcher apps from their AppleScript sources and apply
# the custom icons. This is the canonical way to (re)build the .app bundles —
# plain `osacompile` alone would ship osacompile's 455 KB default icon.
#
# Needs only macOS built-ins (osacompile, PlistBuddy, codesign). To regenerate the
# .icns themselves (optional, needs Swift), see make-icons.swift in this folder.

set -euo pipefail
cd "$(dirname "$0")/.."   # repo root (apps + .applescript live here)

build_one() {
  local name="$1" icns="$2"
  rm -rf "$name.app"
  osacompile -o "$name.app" "$name.applescript"
  # Swap osacompile's default icon (Assets.car ~375 KB + applet.icns ~70 KB) for
  # our small custom one (~90 KB), and point the bundle at it.
  rm -f "$name.app/Contents/Resources/Assets.car" "$name.app/Contents/Resources/applet.icns"
  cp "$icns" "$name.app/Contents/Resources/appicon.icns"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIconFile appicon" "$name.app/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string appicon" "$name.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconName" "$name.app/Contents/Info.plist" 2>/dev/null || true
  # Removing files invalidates osacompile's ad-hoc signature; re-sign.
  codesign --remove-signature "$name.app" 2>/dev/null || true
  codesign --force -s - "$name.app"
  echo "built $name.app ($(du -sh "$name.app" | cut -f1))"
}

build_one "Connect VPN" "tools/Connect.icns"
build_one "Disconnect VPN" "tools/Disconnect.icns"

-- macguard VPN — Connect
--
-- Thin GUI launcher for macguardswitch-vpn.sh. All real logic lives in the shell
-- scripts; this just runs them behind the native macOS admin prompt and shows
-- the result, so no Terminal window appears.
--
-- The compiled "Connect VPN.app" must sit in the SAME folder as macguardswitch-vpn.sh.
-- Rebuild after editing:
--   osacompile -o "Connect VPN.app" "Connect VPN.applescript"

on run
	-- Folder containing this .app (dirname of the bundle path; avoids Finder's
	-- `container of`, which isn't available without an application target).
	set appFolder to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set wrapper to quoted form of (appFolder & "/macguardswitch-vpn.sh")

	-- Capture the launching user's id WITHOUT elevation. `do shell script … with
	-- administrator privileges` runs as root and sets no SUDO_UID, so we pass the
	-- real user explicitly; the supervisor watches them and tears down on logout.
	set uid to do shell script "id -u"

	try
		display notification "Connecting and arming the kill-switch…" with title "macguard VPN"
		do shell script wrapper & " connect " & uid with administrator privileges
		display dialog "✅ Connected and protected by the kill-switch." buttons {"OK"} default button "OK" with title "macguard VPN" with icon note
	on error errMsg number errNum
		if errNum is -128 then return -- user cancelled the password prompt
		display dialog "❌ Couldn't connect." & return & return & errMsg buttons {"OK"} default button "OK" with title "macguard VPN" with icon stop
	end try
end run

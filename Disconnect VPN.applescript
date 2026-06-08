-- macguard VPN — Disconnect
--
-- Thin GUI launcher for macguardswitch-vpn.sh (see "Connect VPN.applescript").
-- The compiled "Disconnect VPN.app" must sit in the SAME folder as macguardswitch-vpn.sh.
-- Rebuild after editing (compiles + applies the custom icon):
--   tools/build-apps.sh

on run
	-- Folder containing this .app (see "Connect VPN.applescript" for why dirname).
	set appFolder to do shell script "dirname " & quoted form of (POSIX path of (path to me))
	set wrapper to quoted form of (appFolder & "/macguardswitch-vpn.sh")
	try
		do shell script wrapper & " disconnect" with administrator privileges
		display dialog "✅ Disconnected. Normal internet restored." buttons {"OK"} default button "OK" with title "macguard VPN" with icon note
	on error errMsg number errNum
		if errNum is -128 then return -- user cancelled the password prompt
		display dialog "⚠️ Problem disconnecting." & return & return & errMsg buttons {"OK"} default button "OK" with title "macguard VPN" with icon caution
	end try
end run

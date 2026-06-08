-- macguard VPN — Disconnect
--
-- Thin GUI launcher for macguardswitch-vpn.sh (see "Connect VPN.applescript").
-- The compiled "Disconnect VPN.app" must sit in the SAME folder as macguardswitch-vpn.sh.
-- Rebuild after editing:
--   osacompile -o "Disconnect VPN.app" "Disconnect VPN.applescript"

on run
	set wrapper to quoted form of ((POSIX path of (container of (path to me))) & "macguardswitch-vpn.sh")
	try
		do shell script wrapper & " disconnect" with administrator privileges
		display dialog "✅ Disconnected. Normal internet restored." buttons {"OK"} default button "OK" with title "macguard VPN" with icon note
	on error errMsg number errNum
		if errNum is -128 then return -- user cancelled the password prompt
		display dialog "⚠️ Problem disconnecting." & return & return & errMsg buttons {"OK"} default button "OK" with title "macguard VPN" with icon caution
	end try
end run

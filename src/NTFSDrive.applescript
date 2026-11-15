on run
	set appIcon to path to resource "applet.icns"
	set mountScript to quoted form of (POSIX path of (path to resource "mount-ntfs.sh"))
	set ejectScript to quoted form of (POSIX path of (path to resource "eject-ntfs.sh"))
	repeat
		set connected to (do shell script "diskutil list external | grep -cE 'Windows_NTFS|Microsoft Basic Data' || true") as integer
		set rwCount to (do shell script "mount | grep -c ' on /Volumes/NTFS-.*macfuse' || true") as integer
		if connected is 0 then
			set statusText to "No NTFS drive connected." & return & return & "Plug in your drive, then click Refresh."
			set btns to {"Close", "Refresh"}
		else if rwCount ≥ connected then
			set statusText to "✅ Drive is mounted READ/WRITE (" & rwCount & " partitions)." & return & return & "Click Eject before unplugging."
			set btns to {"Close", "Eject", "Refresh"}
		else
			set statusText to "🔒 Drive connected (" & connected & " partitions) — READ-ONLY." & return & return & "Click Mount to enable read/write."
			set btns to {"Close", "Eject", "Mount Read/Write"}
		end if
		set choice to button returned of (display dialog statusText with title "NTFS Drive" buttons btns default button (item -1 of btns) cancel button "Close" with icon appIcon)
		if choice is "Mount Read/Write" then
			try
				set out to do shell script mountScript & " 2>&1" with administrator privileges
				if out contains "Operation not permitted" then
					display dialog "macOS blocked disk access." & return & return & "Open System Settings → Privacy & Security → Full Disk Access, add \"NTFS Drive\" (in Applications), switch it on, then try again." with title "NTFS Drive" buttons {"OK"} default button "OK" with icon caution
				else if out contains "FAILED" then
					display dialog "Mount failed:" & return & return & out with title "NTFS Drive" buttons {"OK"} default button "OK" with icon caution
				end if
			on error errMsg number errNum
				if errNum is not -128 then display dialog errMsg with title "NTFS Drive" buttons {"OK"} default button "OK" with icon caution
			end try
		else if choice is "Eject" then
			try
				set out to do shell script ejectScript & " 2>&1" with administrator privileges
				display dialog out with title "NTFS Drive" buttons {"OK"} default button "OK" with icon appIcon
			on error errMsg number errNum
				if errNum is not -128 then display dialog errMsg with title "NTFS Drive" buttons {"OK"} default button "OK" with icon caution
			end try
		end if
	end repeat
end run

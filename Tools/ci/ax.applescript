-- Lists the main window's UI elements with their place and size (CI layout checks).
on run
	set out to ""
	tell application "System Events" to tell (first process whose bundle identifier is "com.vorantx.vory.demo")
		repeat with e in (entire contents of window 1)
			try
				set p to position of e
				set s to size of e
				set d to ""
				try
					set d to description of e
				end try
				set t to ""
				try
					set t to (name of e) as string
				end try
				set out to out & (role of e) & " | " & d & " | " & t & " | " & (item 1 of p) & "," & (item 2 of p) & " " & (item 1 of s) & "x" & (item 2 of s) & linefeed
			end try
		end repeat
	end tell
	return out
end run

-- **DiaRouter** — puts a url in the Dia profile it belongs to, reuses a tab that already
-- has it, and doubles as the editor for its own rules.
--
-- Dia takes no profile on the command line: `open -a Dia <url>` lands in whichever
-- window is in front, and `--profile-directory` opens nothing at all. Its extensions
-- cannot reach across profiles either — an extension is sandboxed per profile and
-- Chrome exposes no cross-profile tab api by design. **AppleScript is the one surface
-- that can**, which is why this is a url handler rather than a browser flag.
--
-- **`on run` is the editor and `on open location` is the router**, and they are separate
-- entry points: launching the app shows the rules, clicking a link never does. Measured
-- rather than assumed — a `run` handler that fired on url delivery would put a modal
-- dialog in front of every link.
--
-- Deciding is route.sh's job and editing is rules.sh's. This file draws and drives Dia.

property workProfile : "All Gravy"
property personalProfile : "Personal"
property home : "$HOME/.dia-router/"

-- MARK: the router

on open location theURL
	routeURL(theURL)
end open location

on routeURL(theURL)
	-- **An unreadable router means hand over, never refuse.** A link that opens in the
	-- wrong profile is a nuisance; a link that does not open is a broken machine.
	set verdict to "native"
	try
		set verdict to do shell script home & "route.sh " & quoted form of theURL
	end try

	set wanted to ""
	if verdict is "work" then set wanted to workProfile
	if verdict is "personal" then set wanted to personalProfile

	tell application "Dia" to activate

	if not hasWindow() then
		if verdict is "native" then
			handOff(theURL)
			return
		end if
		-- **`windows` is read-only in Dia's dictionary**, so a window cannot be made
		-- from here. Asking Dia to open itself is the only way to get one.
		do shell script "open -a Dia"
		if not waitForWindow(30) then
			handOff(theURL)
			return
		end if
	end if

	-- **A tab that already holds this url is focused rather than duplicated.** Scoped to
	-- the profile the url belongs to, so a copy stranded in the other profile is not
	-- treated as a hit — reusing it would undo the routing this exists for. An unrouted
	-- url has no profile to be right about, so it matches anywhere.
	try
		if findAndFocus(theURL, wanted) then return
	end try

	if verdict is "native" then
		handOff(theURL)
		return
	end if

	try
		tell application "Dia"
			set p to (first profile of front window whose name is wanted)
			set t to make new tab at end of tabs of p with properties {URL:theURL}
		end tell
	on error
		-- **A renamed profile lands here**, which is the one failure this is likely to
		-- meet: the names above are the lookup key and Dia lets them be edited.
		handOff(theURL)
		return
	end try

	-- **Focusing is a separate try from creating.** Folded together, a focus that failed
	-- would fall through to the hand-off and open the url a second time.
	try
		tell application "Dia"
			focus p
			focus t
		end tell
	end try
end routeURL

on findAndFocus(theURL, wanted)
	set target to normalise(theURL)
	tell application "Dia"
		-- **Indexed, not `repeat with p in profiles of w`.** That form builds a reference
		-- into a reference and Dia cannot resolve it — `URL of every tab` then fails with
		-- -1700 on every window.
		repeat with wi from 1 to (count of windows)
			set ps to profiles of window wi
			repeat with pi from 1 to (count of ps)
				set p to item pi of ps
				if wanted is "" or (name of p as text) is wanted then
					-- **The explicit `get` is load-bearing.** Without it Dia answers with
					-- tab references rather than strings: `count` works, every comparison
					-- fails with -1700, and the `try` upstream swallows it — so the
					-- dedupe would look healthy and do nothing.
					set us to (get URL of every tab of p)
					repeat with i from 1 to (count of us)
						if my normalise(item i of us) is target then
							focus p
							focus (item i of tabs of p)
							return true
						end if
					end repeat
				end if
			end repeat
		end repeat
	end tell
	return false
end findAndFocus

-- **A trailing slash is not a different page**, and nothing else is normalised away: a
-- fragment and a query each name somewhere specific, so a link to one comment on a pull
-- request must not be answered by focusing the tab showing the whole thread.
on normalise(u)
	set u to u as text
	if (count of u) > 1 and u ends with "/" then set u to text 1 thru -2 of u
	return u
end normalise

on hasWindow()
	try
		tell application "Dia" to return (count of windows) > 0
	on error
		return false
	end try
end hasWindow

on waitForWindow(tenths)
	repeat with i from 1 to tenths
		if hasWindow() then return true
		delay 0.1
	end repeat
	return false
end waitForWindow

on handOff(theURL)
	do shell script "open -a Dia " & quoted form of theURL
end handOff

-- MARK: the editor

on run
	repeat
		set picked to choose from list {"Test a url…", "Rules…", "Add a rule…", "Open rules.tsv in an editor"} with title "DiaRouter" with prompt "Which Dia profile a link opens in." default items {"Test a url…"} OK button name "Choose" cancel button name "Done"
		if picked is false then exit repeat
		set choice to item 1 of picked
		if choice begins with "Test" then
			testURL()
		else if choice begins with "Rules" then
			browseRules()
		else if choice begins with "Add" then
			addRule()
		else
			do shell script "open -t " & home & "rules.tsv"
			exit repeat
		end if
	end repeat
end run

on testURL()
	try
		set answer to text returned of (display dialog "Paste a url to see where it would open." default answer "https://" with title "DiaRouter · test a url")
	on error
		return
	end try
	if answer is "" then return
	set out to do shell script home & "route.sh --explain " & quoted form of answer
	set fields to splitTabs(out)
	set verdict to item 1 of fields
	set why to "no rule matched"
	if (count of fields) > 1 then set why to item 2 of fields
	set dest to "Dia's own default profile, untouched"
	if verdict is "work" then set dest to workProfile
	if verdict is "personal" then set dest to personalProfile
	display dialog "Opens in:" & tab & dest & return & "Because:" & tab & why buttons {"OK"} default button "OK" with title "DiaRouter · test a url"
end testURL

on browseRules()
	set rows to ruleRows()
	if rows is {} then
		display dialog "No rules yet, so every url opens in Dia's own default profile." buttons {"OK"} default button "OK" with title "DiaRouter · rules"
		return
	end if
	set labels to {}
	repeat with r in rows
		set f to splitTabs(r as text)
		set end of labels to (item 3 of f) & "  " & (item 4 of f) & "   →   " & (item 2 of f)
	end repeat
	-- **The prompt states the precedence** because the list is in file order and the
	-- matching is not: someone reading a list top to bottom would otherwise assume the
	-- first line wins and go looking for a bug when it does not.
	set chosen to choose from list labels with title "DiaRouter · rules" with prompt "The most specific rule wins, whatever order these are in." OK button name "Delete…" cancel button name "Back"
	if chosen is false then return
	set i to indexOf(labels, item 1 of chosen)
	if i is 0 then return
	set f to splitTabs(item i of rows as text)
	set verdictLine to (item 3 of f) & " " & (item 4 of f) & " → " & (item 2 of f)
	try
		if button returned of (display dialog "Delete this rule?" & return & return & verdictLine buttons {"Cancel", "Delete"} default button "Cancel" with icon caution with title "DiaRouter · rules") is "Delete" then
			do shell script home & "rules.sh delete " & quoted form of (item 1 of f)
		end if
	end try
	browseRules()
end browseRules

on addRule()
	set profiles_ to {"work — opens in " & workProfile, "personal — opens in " & personalProfile}
	set p to choose from list profiles_ with title "DiaRouter · add a rule" with prompt "Which profile should it open in?" OK button name "Next" cancel button name "Cancel"
	if p is false then return
	set profileName to "work"
	if (item 1 of p) begins with "personal" then set profileName to "personal"

	set kinds to {"host — a domain and its subdomains", "prefix — a url starting with this", "pathhas — host, then a word in its path", "regex — a raw extended regex"}
	set k to choose from list kinds with title "DiaRouter · add a rule" with prompt "How should a url be matched?" OK button name "Next" cancel button name "Cancel"
	if k is false then return
	set kindName to word 1 of (item 1 of k)

	set hint to "allgravy.com"
	if kindName is "prefix" then set hint to "github.com/buttersolutions"
	if kindName is "pathhas" then set hint to "linear.app:all-gravy"
	if kindName is "regex" then set hint to "^https?://example\\.com/(a|b)"
	try
		set pat to text returned of (display dialog "Pattern for this " & kindName & " rule:" default answer hint with title "DiaRouter · add a rule")
	on error
		return
	end try
	if pat is "" then return

	try
		set res to do shell script home & "rules.sh add " & quoted form of profileName & " " & quoted form of kindName & " " & quoted form of pat
		display dialog res buttons {"OK"} default button "OK" with title "DiaRouter"
	on error e
		-- **rules.sh refuses rather than storing something that cannot match**, and its
		-- reason is the message: a half-written pathhas, a pattern already present, a
		-- regex that does not compile.
		display dialog e buttons {"OK"} default button "OK" with icon stop with title "DiaRouter"
	end try
end addRule

on ruleRows()
	set out to do shell script home & "rules.sh list"
	if out is "" then return {}
	return paragraphs of out
end ruleRows

on splitTabs(s)
	set saved to AppleScript's text item delimiters
	set AppleScript's text item delimiters to tab
	set f to text items of (s as text)
	set AppleScript's text item delimiters to saved
	return f
end splitTabs

on indexOf(lst, target)
	repeat with i from 1 to (count of lst)
		if (item i of lst as text) is (target as text) then return i
	end repeat
	return 0
end indexOf

(* Locates and answers the system dialogs a scenario has to get past that
   are not app state — Gatekeeper's "are you sure you want to open this"
   sheet, and the Calendar/Automation permission prompts — plus a generic
   "alert" kind for an app's own native alert, matched purely by role and
   position since it carries no fixed title at all. Every dialog answered
   this way gets an evidence line (process, window title, button title,
   timestamp), because none of it is something the app's own journal could
   record (KTD2).

   Usage: osascript dialogs.applescript <verb> [args]
     wait   <kind> <timeout-seconds> -> {"present":true,"process":...,"title":...,"buttons":[...]}
     answer <kind> <allow or deny> [--evidence <path>] -> {"answered":"allow","process":...,"title":...,"button":...}
     probe                            -> {"dialogs":[...]}   every modal-looking window on screen
     kinds: gatekeeper, calendar, automation, screenrecording, alert

   "--evidence <path>" is parsed out of argv by hand — AppleScript's
   "on run argv" only ever gets a flat list, there is no flag parser, and a
   separate shell wrapper is not used here because it would be a ninth file
   this unit does not own; the calling shape is unaffected either way.

   ===== Each kind's process names, button substrings and identifying text
   are marked PINNED or UNPINNED where they are declared below.

   UNPINNED means a best-effort guess from general knowledge of macOS system
   dialogs. PINNED means it was read off a real dialog on the golden image,
   and the note says when and what was observed. Confirm an UNPINNED value on
   the first run that raises its dialog — `probe` prints every window on
   screen with its process, title and buttons — then correct it here and mark
   it PINNED with the date.

   Matching prefers role and position over title everywhere it is practical,
   so a wrong button substring degrades to the position fallback rather than a
   wrong click. Two things that must be right: the process names, or
   "wait"/"answer" never find the window at all; and the identifying text in
   kindTextSubstrings, because one process (UserNotificationCenter) owns every
   TCC sheet on the system and the text is the only thing that tells them
   apart. "alert" makes no assumption at all — an app's own alert has no fixed
   wording. *)

-- PINNED 2026-09-19 against the real dialog on macOS 26.6.2 in a clone of
-- first-run-golden, raised by opening the shipped AgentMenu v0.1.0 zip:
--   {"present":true,"process":"CoreServicesUIAgent","title":"",
--    "buttons":["missing value","Cancel","Open"]}
-- The window carries NO title, so title matching would never have worked;
-- the process name and the role/position matching below are what find it.
-- The deny button is "Cancel", not "Move to Trash". "Move to Trash" belongs to
-- the OTHER Gatekeeper sheet, pinned 2026-09-20 against a Developer ID build
-- that was signed but NOT notarized:
--   "AgentMenu" Not Opened / Apple could not verify "AgentMenu" is free of
--   malware... / buttons: ["missing value", "Move to Trash", "Done"]
-- That sheet has no affirmative button at all -- it cannot be answered Open,
-- because macOS will not open the app. Its DEFAULT button is "Move to Trash",
-- which is why the position fallback below refuses destructive buttons: an
-- `answer allow` there must fail honestly, not delete the app under test.
-- Both deny wordings are listed and tried in order. One button reports its name as
-- `missing value`, which is why every name read in this file goes through
-- nameOrEmpty().
property gatekeeperProcessNames : {"CoreServicesUIAgent"}
property gatekeeperAllowSubstrings : {"open"}
property gatekeeperDenySubstrings : {"cancel", "trash"}

-- UNPINNED: the process that actually owns a Calendar/Automation TCC
-- sheet varies by macOS version; both candidates are tried in order.
property calendarProcessNames : {"UserNotificationCenter", "tccd"} -- UNPINNED
property calendarAllowSubstrings : {"allow"} -- PINNED 2026-09-20 (was "ok",
-- which matches nothing on this macOS and sent the run to the position
-- fallback)
property calendarDenySubstrings : {"don"} -- UNPINNED ("Don't Allow" — matched
-- by prefix so a curly apostrophe does not break the match)

property automationProcessNames : {"UserNotificationCenter", "tccd"} -- UNPINNED
property automationAllowSubstrings : {"allow"} -- see calendarAllowSubstrings
property automationDenySubstrings : {"don"} -- UNPINNED

-- PINNED 2026-09-21 against the real dialog on macOS 26.6.2 in a manually
-- cloned first-run-golden guest, raised by `osascript -e 'tell application
-- "Finder" to move ...'` over ssh (the Finder-move translocation test that
-- disproved `clear_quarantine`'s old assumption — see
-- MeetingHopKit.BundleTranslocation's doc comment). System Events read the
-- window's own text as:
--   "sshd-keygen-wrapper" wants access to control "Finder". Allowing
--   control will provide access to documents and data in "Finder", and to
--   perform actions within that app.
-- None of the three old guesses ("controlling", "apple events",
-- "automation") appear anywhere in that sentence, so `wait automation`
-- reported present:false with the dialog on screen and the run would have
-- hung on this kind's own timeout. "wants access to control" is what is
-- actually there, is not tied to which client or which target app the
-- sentence names, and was confirmed present for real on the dialog above.
property automationTextSubstrings : {"wants access to control"}

-- macOS 26 asks separately, and repeatedly, for ScreenCaptureKit's "bypass the
-- system private window picker" consent, even though kTCCServiceScreenCapture
-- is already granted in the image (verified on a clone: the access row is
-- auth_value 2 and `screencapture -x` works). The approval is not a TCC access
-- row, so tcc-seed.sh cannot pre-grant it; the harness answers it instead.
-- UserNotificationCenter owns it, which is exactly why kinds need the text
-- test below.
property screenrecordingProcessNames : {"UserNotificationCenter", "tccd"}
property screenrecordingAllowSubstrings : {"allow"}
property screenrecordingDenySubstrings : {"open system settings"}

-- A button the position fallback must never pick. Matching one of these by an
-- explicit deny substring is fine -- that is a scenario asking for it by name.
-- Guessing one from its position is not: on the non-notarized Gatekeeper sheet
-- "Move to Trash" is the default button, so a fallback that takes the
-- first-or-last named button is one button-order change away from deleting the
-- app under test and reporting success.
property destructiveSubstrings : {"trash", "delete", "erase", "remove"}

-- ===== What each kind's dialog must SAY =====
--
-- A process name alone does not identify a dialog. UserNotificationCenter owns
-- every TCC sheet on the system, so `wait calendar` matched macOS 26's
-- screen-recording approval and `answer calendar allow` clicked its "Open
-- System Settings" button, while the run logged "calendar permission prompted
-- and was answered Allow" and passed. The Calendar grant was never requested.
-- Observed on the first real MeetingHop stranger run, 2026-09-20.
--
-- So a kind whose dialog has identifying words lists them here, and a window
-- whose text carries none of them is NOT that kind. "alert" and "gatekeeper"
-- keep an empty list: an app's own alert has no fixed wording, and Gatekeeper
-- is identified by CoreServicesUIAgent, which owns nothing else.
on kindTextSubstrings(kind)
    return item 4 of my kindSpec(kind)
end kindTextSubstrings

-- Every piece of static text in a window, lowercased and joined, for the test
-- above.
on windowText(win)
    tell application "System Events"
        set out to ""
        try
            repeat with t in (static texts of win)
                set tText to my propOrEmpty(t, "value")
                if tText is "" then set tText to my nameOf(t)
                set out to out & " " & tText
            end repeat
        end try
        set out to out & " " & my nameOf(win)
        return my toLower(out)
    end tell
end windowText

on matchesAny(theText, subs)
    set hay to my toLower(theText)
    repeat with sub in subs
        if hay contains (my toLower(sub as text)) then return true
    end repeat
    return false
end matchesAny

on windowMatchesKind(win, kind)
    set wanted to my kindTextSubstrings(kind)
    if (count of wanted) is 0 then return true
    set haystack to my windowText(win)
    repeat with sub in wanted
        if haystack contains (sub as text) then return true
    end repeat
    return false
end windowMatchesKind

on run argv
    if (count of argv) < 1 then
        return my jsonError("usage", "a verb is required. Verbs: wait, answer, probe.")
    end if
    set theVerb to item 1 of argv

    if theVerb is "probe" then
        try
            return my verbProbe()
        on error errText number errNum
            return my jsonError("driver", errText)
        end try
    end if

    if theVerb is "wait" then
        if (count of argv) < 3 then return my jsonError("usage", "wait requires a kind and a timeout in seconds.")
        set theKind to item 2 of argv
        if not (my isKnownKind(theKind)) then return my jsonError("usage", "unknown dialog kind: " & theKind & ".")
        set theTimeout to (item 3 of argv) as text
        try
            set theTimeoutNum to theTimeout as number
        on error
            return my jsonError("usage", "timeout must be a number of seconds, got '" & theTimeout & "'.")
        end try
        try
            return my verbWait(theKind, theTimeoutNum)
        on error errText number errNum
            return my jsonError("driver", errText)
        end try
    end if

    if theVerb is "answer" then
        if (count of argv) < 3 then return my jsonError("usage", "answer requires a kind and allow or deny.")
        set theKind to item 2 of argv
        if not (my isKnownKind(theKind)) then return my jsonError("usage", "unknown dialog kind: " & theKind & ".")
        set theChoice to item 3 of argv
        if theChoice is not "allow" and theChoice is not "deny" then
            return my jsonError("usage", "answer's second argument must be allow or deny, got '" & theChoice & "'.")
        end if
        set evidencePath to missing value
        if (count of argv) is 5 and item 4 of argv is "--evidence" then
            set evidencePath to item 5 of argv
        else if (count of argv) > 3 then
            return my jsonError("usage", "unrecognized trailing arguments after allow/deny.")
        end if
        try
            return my verbAnswer(theKind, theChoice, evidencePath)
        on error errText number errNum
            if errNum is 1 then
                return my jsonError("notfound", errText)
            else
                return my jsonError("driver", errText)
            end if
        end try
    end if

    return my jsonError("usage", "unknown verb: " & theVerb & ".")
end run

on isKnownKind(theKind)
    return theKind is "gatekeeper" or theKind is "calendar" or theKind is "automation" or theKind is "screenrecording" or theKind is "alert"
end isKnownKind

-- ===== Locating a dialog =====

-- One place that knows what a kind is, instead of three ladders switching on
-- the same string. Adding a kind is one entry here plus its properties above.
-- {process names, allow substrings, deny substrings, identifying text}
-- "alert" is all-empty on purpose: it is matched structurally (frontmost
-- window) and makes no assumption about process, wording or title.
on kindSpec(kind)
    if kind is "gatekeeper" then
        return {gatekeeperProcessNames, gatekeeperAllowSubstrings, gatekeeperDenySubstrings, {}}
    else if kind is "calendar" then
        return {calendarProcessNames, calendarAllowSubstrings, calendarDenySubstrings, {"calendar"}}
    else if kind is "automation" then
        return {automationProcessNames, automationAllowSubstrings, automationDenySubstrings, automationTextSubstrings}
    else if kind is "screenrecording" then
        return {screenrecordingProcessNames, screenrecordingAllowSubstrings, screenrecordingDenySubstrings, {"window picker", "record your screen", "screen and audio"}}
    else
        return {{}, {}, {}, {}}
    end if
end kindSpec

on candidateProcessNames(kind)
    return item 1 of my kindSpec(kind)
end candidateProcessNames

-- Returns {process, window}, or raises number 3 (driver) when nothing
-- matches — "the dialog is not there" is a driver-class condition for wait
-- to retry, and for answer to report as a failure to act on.
on locateDialogWindow(kind)
    tell application "System Events"
        set names to my candidateProcessNames(kind)
        repeat with aName in names
            try
                set proc to first application process whose name is aName
                repeat with w in (windows of proc)
                    if my windowMatchesKind(w, kind) then return {proc, w}
                end repeat
            end try
        end repeat
        if kind is "alert" or (count of names) is 0 then
            -- Generic fallback for "alert": the frontmost process's front
            -- window, whatever it is — matched purely by role/position,
            -- never by title, since a native alert's title is the app's own
            -- and this file has no business assuming one.
            try
                set proc to first application process whose frontmost is true
                if (count of windows of proc) > 0 then
                    return {proc, window 1 of proc}
                end if
            end try
        end if
        error "no " & kind & " dialog is on screen." number 3
    end tell
end locateDialogWindow

-- A System Events element whose name is unset answers `missing value`, and a
-- `try` around the read does NOT catch that: the assignment succeeds and the
-- caller is left holding `missing value` instead of a string. Passing that to
-- anything expecting text fails with "missing value doesn't understand the
-- count message", which is what stopped `answer gatekeeper allow` dead on the
-- real Gatekeeper sheet (its first button reports no name). Every name read in
-- this file goes through here.
on nameOrEmpty(theValue)
    if theValue is missing value then return ""
    try
        return theValue as text
    on error
        return ""
    end try
end nameOrEmpty

-- Reading a property that may be unset, in one place. `try` alone is not
-- enough (the assignment succeeds and yields `missing value`), and the
-- five-line guard this replaces was hand-copied at eight sites, which is how
-- two of them ended up without the guard at all.
on propOrEmpty(el, propName)
    set v to missing value
    try
        if propName is "value" then
            set v to value of el
        else if propName is "role" then
            set v to role of el
        else
            set v to name of el
        end if
    end try
    return my nameOrEmpty(v)
end propOrEmpty

on nameOf(el)
    return my propOrEmpty(el, "name")
end nameOf

on windowButtonNames(win)
    tell application "System Events"
        set out to {}
        try
            repeat with b in (buttons of win)
                set end of out to my nameOf(b)
            end repeat
        end try
        return out
    end tell
end windowButtonNames

on buttonSubstrings(kind, choice)
    if choice is "allow" then
        return item 2 of my kindSpec(kind)
    else
        return item 3 of my kindSpec(kind)
    end if
end buttonSubstrings

-- ===== Verbs =====

on verbWait(kind, timeoutSeconds)
    set startTime to (current date)
    set deadline to startTime + timeoutSeconds
    repeat
        try
            set {proc, win} to my locateDialogWindow(kind)
            tell application "System Events"
                set procName to my nameOf(proc)
                set winTitle to my nameOf(win)
            end tell
            set buttonNames to my windowButtonNames(win)
            return "{\"present\":true,\"process\":" & my jsonString(procName) & ",\"title\":" & my jsonString(winTitle) & ",\"buttons\":[" & my joinComma(my jsonStringList(buttonNames)) & "]}"
        end try
        if (current date) ≥ deadline then
            return "{\"present\":false,\"process\":null,\"title\":null,\"buttons\":[]}"
        end if
        delay 0.5
    end repeat
end verbWait

on verbAnswer(kind, choice, evidencePath)
    set {proc, win} to my locateDialogWindow(kind)
    tell application "System Events"
        set procName to my nameOf(proc)
        set winTitle to my nameOf(win)
        set candidates to my buttonSubstrings(kind, choice)
        set targetButton to missing value
        set targetButtonName to ""
        set matchedBy to "substring"
        set allButtons to buttons of win
        repeat with b in allButtons
            set bName to my nameOf(b)
            repeat with sub in candidates
                if (my toLower(bName)) contains (my toLower(sub as text)) then
                    set targetButton to b
                    set targetButtonName to bName
                    exit repeat
                end if
            end repeat
            if targetButton is not missing value then exit repeat
        end repeat
        if targetButton is missing value then
            set matchedBy to "position"
            -- Position fallback (KTD2's "prefer role and position over
            -- title"): the affirmative action is conventionally the
            -- right-most/default button on a macOS system dialog, the
            -- negative one the left-most.
            --
            -- Only NAMED buttons are eligible. The real Gatekeeper sheet
            -- carries an unnamed leading button (the "?" help button), and
            -- taking it as the left-most would make `deny` open Help instead
            -- of dismissing the dialog -- a silent wrong click, which is worse
            -- than the honest "no button found" error below.
            set namedButtons to {}
            repeat with b in allButtons
                set bName to my nameOf(b)
                if bName is not "" and not (my matchesAny(bName, destructiveSubstrings)) then
                    set end of namedButtons to b
                end if
            end repeat
            if (count of namedButtons) > 0 then
                if choice is "allow" then
                    set targetButton to item (count of namedButtons) of namedButtons
                else
                    set targetButton to item 1 of namedButtons
                end if
                set targetButtonName to my nameOf(targetButton)
            end if
        end if
        if targetButton is missing value then
            error "no " & choice & " button found on the " & kind & " dialog." number 1
        end if
        click targetButton
    end tell
    if evidencePath is not missing value then
        my appendEvidence(evidencePath, procName, winTitle, targetButtonName)
    end if
    return "{\"answered\":" & my jsonString(choice) & ",\"process\":" & my jsonString(procName) & ",\"title\":" & my jsonString(winTitle) & ",\"button\":" & my jsonString(targetButtonName) & ",\"matched_by\":" & my jsonString(matchedBy) & "}"
end verbAnswer

-- Every application process with a window, NOT only the foreground ones.
--
-- This used to filter on `background only is false`, which silently excluded
-- the one process probe exists to find: CoreServicesUIAgent, the owner of the
-- Gatekeeper sheet, is a background-only agent. Probed against the real
-- dialog on 2026-09-19 the old filter returned Terminal alone, while
-- `wait gatekeeper` found the sheet -- so the tool this file's header tells
-- the maintainer to run first was the one that could not see it.
-- Processes with no windows are skipped, which is what the filter was really
-- for.
on verbProbe()
    tell application "System Events"
        set out to {}
        set allProcs to every application process
        repeat with proc in allProcs
            try
                set procName to my nameOf(proc)
                repeat with w in (windows of proc)
                    set wTitle to my nameOf(w)
                    set wRole to my propOrEmpty(w, "role")
                    set buttonNames to my windowButtonNames(w)
                    set end of out to "{\"process\":" & my jsonString(procName) & ",\"title\":" & my jsonString(wTitle) & ",\"role\":" & my jsonString(wRole) & ",\"buttons\":[" & my joinComma(my jsonStringList(buttonNames)) & "]}"
                end repeat
            end try
        end repeat
        return "{\"dialogs\":[" & my joinComma(out) & "]}"
    end tell
end verbProbe

-- ===== Evidence =====

on appendEvidence(path, procName, winTitle, buttonName)
    try
        set ts to do shell script "date -u +%Y-%m-%dT%H:%M:%SZ"
        set evidenceLine to "{\"process\":" & my jsonString(procName) & ",\"window_title\":" & my jsonString(winTitle) & ",\"button\":" & my jsonString(buttonName) & ",\"t\":" & my jsonString(ts) & "}" & linefeed
        set fileRef to open for access path with write permission
        write evidenceLine to fileRef starting at (get eof fileRef)
        close access fileRef
    on error
        try
            close access path
        end try
    end try
end appendEvidence

-- ===== String / JSON helpers =====

on toLower(theText)
    set out to ""
    repeat with ch in theText
        set c to ch as text
        set n to (id of c)
        if n ≥ 65 and n ≤ 90 then
            set out to out & (character id (n + 32))
        else
            set out to out & c
        end if
    end repeat
    return out
end toLower

on replaceText(sourceText, searchString, replacementString)
    set {tid, AppleScript's text item delimiters} to {AppleScript's text item delimiters, searchString}
    set theItems to text items of sourceText
    set AppleScript's text item delimiters to replacementString
    set resultText to theItems as text
    set AppleScript's text item delimiters to tid
    return resultText
end replaceText

on jsonEscapeString(theText)
    set theText to my replaceText(theText, "\\", "\\\\")
    set theText to my replaceText(theText, "\"", "\\\"")
    set theText to my replaceText(theText, return, "\\n")
    set theText to my replaceText(theText, linefeed, "\\n")
    set theText to my replaceText(theText, tab, "\\t")
    return theText
end jsonEscapeString

on jsonString(theText)
    if theText is missing value then return "null"
    return "\"" & my jsonEscapeString(theText as text) & "\""
end jsonString

on jsonStringList(theList)
    set out to {}
    repeat with anItem in theList
        set end of out to my jsonString(anItem as text)
    end repeat
    return out
end jsonStringList

on joinComma(theList)
    set {tid, AppleScript's text item delimiters} to {AppleScript's text item delimiters, ","}
    set out to theList as text
    set AppleScript's text item delimiters to tid
    return out
end joinComma

on jsonError(kind, message)
    return "{\"error\":" & my jsonString(message) & ",\"kind\":" & my jsonString(kind) & "}"
end jsonError

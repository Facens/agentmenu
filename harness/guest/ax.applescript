(* Finds, clicks and reads controls in the app under test by AXIdentifier,
   over System Events, so a scenario can drive a real UI the way a person
   would (KTD2) — never by coordinate, never by title. Also answers KTD2's
   deferred question: whether the status item is addressed as "menu bar 2"
   of the app's own process or of SystemUIServer on macOS 26. Both idioms
   are probed, in that order, and whichever answers is reported back so a
   scenario (and this file's own callers) can learn the real answer instead
   of guessing it. AXorcist's `axorc` is the documented fallback if
   identifier matching proves unreliable on the built app; not implemented
   here, only noted, per the plan.

   Usage: osascript ax.applescript <verb> [args]
     windows     <target>              -> {"windows":[{"name":...,"role":...}]}
     find        <target> <identifier> -> {"found":true or false,"role":...,"title":...}
     click       <target> <identifier> -> {"clicked":true,"identifier":...}
     read        <target> <identifier> -> {"value":...,"title":...}
     statusitem  <target>              -> {"found":true,"idiom":"app-menu-bar-<n>" or "systemuiserver"}
     statusclick <target>              -> {"clicked":true,"idiom":...}
     list-ids    <target>              -> {"identifiers":[...]}

   <target> is either a bundle id (dev.facens.agentmenu) or "pid:<n>",
   naming one running process by its unix process id (pid:66679) —
   U-defect-2: two processes can share a bundle id (the harness's own
   app-fresh instance and the maintainer's own installed copy both answer
   to dev.facens.agentmenu on the very machine that surfaced this), so a
   bundle id alone cannot say which one a verb should drive; pid: can,
   unambiguously. The stranger tier, where only one instance of the app
   under test is ever running, keeps using the bundle-id form unchanged.
   A pid: target additionally refuses statusitem/statusclick's
   SystemUIServer fallback below: that menu bar lists every third-party
   status item on the system, not only this process's, so a pid: caller
   that cannot see its own item under its own process is told "not found"
   rather than risk resolving to — and statusclick actually clicking —
   some other process's item.

   Argument validation (missing verb, unknown verb, missing required
   arguments, and a malformed pid: target) happens before this script ever
   touches "tell application System Events", and returns its JSON the
   normal way — so calling this file with no verb, a bad one, or a
   non-numeric pid:, is safe to run for real, and is exactly what this
   unit's host-side tests do.

   IMPORTANT DEVIATION FROM THE HARNESS CONTRACT'S EXIT CODES: `osascript`
   itself can only ever exit 0 (the script ran to completion) or 1 (an
   uncaught AppleScript error propagated, with its message going to STDERR,
   never STDOUT, wrapped as "<file>:<line>:<col>: execution error: ... (N)"
   regardless of what error number was raised) — verified by hand here,
   this is not a guess: no AppleScript construct makes the OS process exit
   with a caller-chosen code while still putting clean JSON on stdout. So
   this file always lets `on run argv` complete normally and always prints
   one JSON object to stdout, on success AND on failure — `osascript`'s own
   exit code is always 0. A failure is instead signalled by the JSON
   itself: an "error" field with a message, and a "kind" field of "usage",
   "notfound" (the verb's target does not exist, including no running
   process at all matching the given bundle id or pid: — the contract's
   exit 1; a real absence is "not found", never a driver failure — see
   processForTarget below, which was fixed to raise exactly this after
   `exists (application process whose bundle identifier is …)` was found
   to raise -1728 instead of returning false, taking every bundle-id verb
   down with it), or "driver" (System Events/Apple Events access was
   refused — the contract's exit 3, including a -1743 Apple Events denial,
   the same failure Sources/AgentMenuKit/Launch/TerminalLauncher.swift's
   isAppleEventDenial detects for the app itself — or any other
   AppleScript runtime error this file did not anticipate).
   Any bash caller (harness/lib/, U2's territory) must branch on the JSON's
   "kind", not on osascript's process exit status.

   U-defect-3, probed by hand against an isolated instance (never the
   maintainer's own running copy): `list-ids` and `find` came back empty
   against a status item whose AXIdentifier was confirmed present by a raw,
   one-shot `osascript -e` query. The cause was not a missing attribute —
   it was how the reference to it was built. "value of attribute
   AXIdentifier of X" only resolves for a menu-bar-item-rooted X when the
   *entire* chain from "application process" down to X is one live, inline
   expression, evaluated without ever passing through a `set` assignment —
   not for the process (processForTarget's own return value, stored by
   every caller the normal way, silently breaks every attribute query
   underneath a menu bar once it is reused, though role/class/count of the
   very same elements still resolve fine through it), not for the
   UI-elements list (`set kids to UI elements of X` before `repeat with kid
   in kids` breaks it; writing the same expression directly as the
   repeat's own source does not), and not even across a `return` (a
   handler that builds the list inline and hands it back still poisons it
   for the caller). The one exception, verified through several recursion
   levels against a real nested tree (Finder's own menu bar, never
   AgentMenu's): an element bound by `repeat with kid in (<live expr>)`
   stays live when passed on to another handler *as an argument* — that is
   what makes findByIdentifier/collectIdentifiers's ordinary recursion
   still work once the walk actually reaches a live element. Window-rooted
   trees never showed this fragility — `windows of proc` and everything
   under it tolerated a stored `proc` fine, attribute queries included; it
   is specifically a menu bar in the path that requires the live-inline
   discipline. statusBarWalk below exists because of this: it re-resolves
   the process from the target string fresh, inline, every time it is
   called, rather than accepting the same already-resolved process every
   other verb safely reuses. Separately, some element classes never answer
   the attribute at all — a real, on-this-machine example is a macOS Apple
   menu's separator items, which raise rather than return `missing value` —
   and that must not abort a branch either; each attribute read already
   sits in its own `try`, which is what makes that non-fatal.

   Popover content, probed the same way: pressing the status item
   (`perform action "AXPress"`) opens AgentMenu's popover, and its content
   — setup.done, popover.gear, popover.row.*, setup.folder.*.toggle, and
   the rest — surfaced through `list-ids` with no code beyond the fix
   above; it did not need a separate window-walk, because it is not
   exposed as a separate AXWindow at all (`windows` stayed `{"windows":[]}`
   throughout every one of these probes, open or closed) — it appears as
   further descendants of the status item itself, inside the same menu-bar
   branch statusBarWalk already covers. That answers the plan's deferred
   question — identifiers set on NSPopover content do surface to System
   Events — but two caveats belong on the record rather than papered over:
   first, the display had gone from asleep to awake on its own partway
   through this probing session, through no action taken here (no
   `caffeinate`, nothing that touches display power was ever run), so the
   successful capture happened against an *awake* display, not the asleep
   one this file's own callers may still be facing — that combination
   remains unconfirmed. Second, and independent of the display: the
   popover was observed to close on its own well under a second after
   opening when driven this way (a real capture succeeded at a 0.2s delay
   after the click, and consistently failed by 0.5s, and on several later
   attempts even sooner) — most likely because a synthetic AXPress does
   not hand the app the same "active application" status a real click
   would, and this popover's dismissal behavior reacts to that. A scenario
   that needs popover-content identifiers should query immediately after
   clicking, not after any other work in between. *)

on run argv
    if (count of argv) < 1 then
        return my jsonError("usage", "a verb is required. Verbs: windows, find, click, read, statusitem, statusclick, list-ids.")
    end if
    set theVerb to item 1 of argv

    if theVerb is "windows" then
        if (count of argv) < 2 then return my jsonError("usage", "windows requires a bundle id or pid:<n>.")
    else if theVerb is "find" then
        if (count of argv) < 3 then return my jsonError("usage", "find requires a bundle id or pid:<n>, and an identifier.")
    else if theVerb is "click" then
        if (count of argv) < 3 then return my jsonError("usage", "click requires a bundle id or pid:<n>, and an identifier.")
    else if theVerb is "read" then
        if (count of argv) < 3 then return my jsonError("usage", "read requires a bundle id or pid:<n>, and an identifier.")
    else if theVerb is "statusitem" then
        if (count of argv) < 2 then return my jsonError("usage", "statusitem requires a bundle id or pid:<n>.")
    else if theVerb is "statusclick" then
        if (count of argv) < 2 then return my jsonError("usage", "statusclick requires a bundle id or pid:<n>.")
    else if theVerb is "list-ids" then
        if (count of argv) < 2 then return my jsonError("usage", "list-ids requires a bundle id or pid:<n>.")
    else
        return my jsonError("usage", "unknown verb: " & theVerb & ".")
    end if

    -- Every verb above takes its target — a bundle id, or "pid:<n>" naming
    -- one running process unambiguously (see this file's header) — as argv
    -- item 2. Its shape is checked here, before "tell application System
    -- Events" is ever reached, so a malformed pid: is a usage error (2)
    -- like every other argument problem, and never a driver error.
    set theTarget to item 2 of argv
    if theTarget starts with "pid:" then
        if (count of theTarget) < 5 or not my isAllDigits(text 5 thru -1 of theTarget) then
            return my jsonError("usage", "pid: must be followed by digits, got " & theTarget & ".")
        end if
    end if

    try
        if theVerb is "windows" then
            return my verbWindows(theTarget)
        else if theVerb is "find" then
            return my verbFind(theTarget, item 3 of argv)
        else if theVerb is "click" then
            return my verbClick(theTarget, item 3 of argv)
        else if theVerb is "read" then
            return my verbRead(theTarget, item 3 of argv)
        else if theVerb is "statusitem" then
            return my verbStatusItem(theTarget)
        else if theVerb is "statusclick" then
            return my verbStatusClick(theTarget)
        else
            return my verbListIds(theTarget)
        end if
    on error errText number errNum
        if errNum is 1 then
            return my jsonError("notfound", errText)
        else
            return my jsonError("driver", errText)
        end if
    end try
end run

-- ===== Process and element lookup =====

-- U-defect-1: `exists (application process whose bundle identifier is …)`
-- itself raises -1728 instead of returning false when nothing matches — the
-- guard was failing before the real lookup ever ran, so every bundle-id verb
-- came back "kind":"driver" against an app that was actually running.
-- Verified by hand: `exists (application process whose bundle identifier is
-- "dev.facens.agentmenu")` raises, while `count of (application processes
-- whose bundle identifier is "dev.facens.agentmenu")` answers 0 or 1 for a
-- real absence or presence respectively, so `count` is the guard now.
--
-- U-defect-2: theTarget is either a bundle id or "pid:<n>" (already
-- validated as all-digits in `run`, before this ever touched System
-- Events) naming one running process by its unix process id — the only
-- unambiguous way to say which instance to drive when two processes answer
-- to the same bundle id, which happens whenever the harness's own
-- app-fresh instance runs beside the maintainer's own installed AgentMenu.
--
-- Raises number 1 (notfound) so the top-level catch reports
-- "kind":"notfound" — a real absence, whichever form named it, is "not
-- found", never a driver problem.
on processForTarget(theTarget)
    tell application "System Events"
        if theTarget starts with "pid:" then
            set targetPid to (text 5 thru -1 of theTarget) as integer
            if (count of (application processes whose unix id is targetPid)) is 0 then
                error "no running process has pid " & targetPid & "." number 1
            end if
            return (first application process whose unix id is targetPid)
        end if
        if (count of (application processes whose bundle identifier is theTarget)) is 0 then
            error "no running process has bundle id " & theTarget & "." number 1
        end if
        return (first application process whose bundle identifier is theTarget)
    end tell
end processForTarget

-- True when every character of theText is a digit 0-9, and theText is not
-- empty — used only to validate a pid:<n> target before it is ever coerced
-- to a number or handed to System Events.
on isAllDigits(theText)
    set digits to "0123456789"
    if (count of theText) is 0 then return false
    repeat with i from 1 to (count of theText)
        if digits does not contain (character i of theText) then return false
    end repeat
    return true
end isAllDigits

-- U-defect-3: this recursive step used to read "set kids to UI elements of
-- elementRef" followed by "repeat with kid in kids" — an intermediate
-- variable holding the list. That one extra assignment is enough to break
-- every "get attribute" underneath it: verified by hand, over and over,
-- that "repeat with kid in (UI elements of X)" written inline as the
-- repeat's own source resolves "value of attribute ..." of kid correctly,
-- while "set kids to UI elements of X" first, then "repeat with kid in
-- kids", makes the exact same attribute query raise -1728 ("Can't get
-- attribute ...") for every element the list produces — not a missing
-- value, an outright error, which is why it was invisible under this
-- handler's own try/catch: the error just meant "nothing found here",
-- indistinguishable from a real absence. Non-attribute reads (role, class,
-- count) tolerate the stored-variable form fine, which is what made this
-- so easy to miss by spot-checking those instead of AXIdentifier itself.
-- So: never assign a UI-elements (or similar reference-yielding) list to a
-- variable before iterating it — always write the source expression
-- directly in the repeat statement, at every recursion depth.
on findByIdentifier(elementRef, targetID)
    tell application "System Events"
        try
            if (value of attribute "AXIdentifier" of elementRef) is targetID then return elementRef
        end try
        try
            repeat with kid in (UI elements of elementRef)
                set found to my findByIdentifier(kid, targetID)
                if found is not missing value then return found
            end repeat
        end try
    end tell
    return missing value
end findByIdentifier

-- Recursively within every window, then the status item's own menu bar
-- (the approach note's "within windows and the status item's menu bar").
on locate(theTarget, targetID)
    tell application "System Events"
        set proc to my processForTarget(theTarget)
        set found to missing value
        try
            repeat with w in windows of proc
                set found to my findByIdentifier(w, targetID)
                if found is not missing value then return found
            end repeat
        end try
        try
            set barIndex to my statusBarIndexFor(proc)
            if barIndex > 0 then set found to my statusBarWalk(theTarget, barIndex, targetID, missing value)
        end try
        return found
    end tell
end locate

-- U-defect-3, continued: windows tolerate being reached through "proc" —
-- a process reference resolved once by processForTarget and stored in a
-- variable, exactly like every other verb does — but a menu bar does not.
-- Verified by hand: "windows of proc" then "UI elements of" each window,
-- both off a stored proc, still answers "value of attribute AXIdentifier"
-- correctly (proven against Finder's own window, a process with real
-- content, since driving AgentMenu's own windows is not this defect's
-- territory); but "menu bar N of proc" — proc stored the very same way —
-- fails the identical query even after the fix above, and so does a list
-- this handler *returns* to its caller instead of walking inline (also
-- verified by hand: returning "UI elements of (menu bar N of process)"
-- from a handler poisons it for the caller just as storing it would).
-- So the process itself must be re-resolved fresh, inline, in the exact
-- statement that walks the status bar's top-level items — never handed in
-- as an already-resolved reference, and never handed back out as one.
-- Only the *elements themselves*, once obtained this way, survive being
-- passed on to another handler as an argument (findByIdentifier and
-- collectIdentifiers both do exactly that, and both were verified to
-- still answer AXIdentifier correctly several recursion levels deep).
--
-- Doubles as both verbs' status-bar entry point: with targetID given, it
-- searches (find/click/read's use, mirroring findByIdentifier's return
-- convention — missing value for "not found here"); with targetID itself
-- missing value, it collects into acc instead (list-ids' use, mirroring
-- collectIdentifiers' accumulate-by-reference convention).
on statusBarWalk(theTarget, barIndex, targetID, acc)
    tell application "System Events"
        if theTarget starts with "pid:" then
            set targetPid to (text 5 thru -1 of theTarget) as integer
            repeat with kid in (UI elements of (menu bar barIndex of (first application process whose unix id is targetPid)))
                if targetID is not missing value then
                    set found to my findByIdentifier(kid, targetID)
                    if found is not missing value then return found
                else
                    my collectIdentifiers(kid, acc)
                end if
            end repeat
        else
            repeat with kid in (UI elements of (menu bar barIndex of (first application process whose bundle identifier is theTarget)))
                if targetID is not missing value then
                    set found to my findByIdentifier(kid, targetID)
                    if found is not missing value then return found
                else
                    my collectIdentifiers(kid, acc)
                end if
            end repeat
        end if
    end tell
    return missing value
end statusBarWalk

on collectIdentifiers(elementRef, acc)
    tell application "System Events"
        try
            set anID to value of attribute "AXIdentifier" of elementRef
            if anID is not missing value and anID is not "" then
                set end of acc to (anID as text)
            end if
        end try
        try
            repeat with kid in (UI elements of elementRef)
                my collectIdentifiers(kid, acc)
            end repeat
        end try
    end tell
end collectIdentifiers

-- ===== Verbs =====

on verbWindows(theTarget)
    tell application "System Events"
        set proc to my processForTarget(theTarget)
        set entries to {}
        repeat with w in windows of proc
            set wName to ""
            set wRole to ""
            try
                set wName to name of w
            end try
            try
                set wRole to role of w
            end try
            set end of entries to "{\"name\":" & my jsonString(wName) & ",\"role\":" & my jsonString(wRole) & "}"
        end repeat
        return "{\"windows\":[" & my joinComma(entries) & "]}"
    end tell
end verbWindows

on verbFind(theTarget, targetID)
    set el to my locate(theTarget, targetID)
    if el is missing value then
        return "{\"found\":false}"
    end if
    tell application "System Events"
        set theRole to ""
        set theTitle to ""
        try
            set theRole to role of el
        end try
        try
            set theTitle to name of el
        end try
        return "{\"found\":true,\"role\":" & my jsonString(theRole) & ",\"title\":" & my jsonString(theTitle) & "}"
    end tell
end verbFind

on verbClick(theTarget, targetID)
    set el to my locate(theTarget, targetID)
    if el is missing value then
        error "no element with AXIdentifier " & targetID & " under " & theTarget & "." number 1
    end if
    tell application "System Events"
        click el
    end tell
    return "{\"clicked\":true,\"identifier\":" & my jsonString(targetID) & "}"
end verbClick

on verbRead(theTarget, targetID)
    set el to my locate(theTarget, targetID)
    if el is missing value then
        error "no element with AXIdentifier " & targetID & " under " & theTarget & "." number 1
    end if
    tell application "System Events"
        set theValue to ""
        set theTitle to ""
        try
            set theValue to (value of el) as text
        end try
        try
            set theTitle to name of el
        end try
        return "{\"value\":" & my jsonString(theValue) & ",\"title\":" & my jsonString(theTitle) & "}"
    end tell
end verbRead

-- Probes "menu bar 2" of the app's own process first, then of
-- SystemUIServer, in that order, and reports whichever answered — the open
-- question this unit's job is to probe, not assume. The SystemUIServer
-- fallback is skipped for a pid: target (U-defect-2): that menu bar lists
-- every third-party status item on the system, not only this process's, so
-- a pid: caller that finds nothing under its own process is told
-- "not found" rather than reported an idiom statusclick would then have to
-- guess at.
-- Which of the process's own menu bars holds its status item.
--
-- Probed on macOS 26.6 against a running AgentMenu rather than assumed: a
-- regular app has its application menu bar as "menu bar 1" and its status
-- items as "menu bar 2", but AgentMenu and MeetingHop are both background
-- only, so they have no application menu bar at all and the status item is
-- the single item of "menu bar 1". Asking for "menu bar 2" there raises
-- -1719, which is why the old probe reported no status item on an app whose
-- item was plainly on screen. SystemUIServer, the other candidate the plan
-- named, reports zero menu bars on this macOS and cannot answer at all; the
-- system's own extras live in ControlCenter, which does not list a
-- third-party item either.
--
-- So: walk the process's menu bars from the last to the first and take the
-- first one that actually holds an item, reporting which index answered, so
-- a report says what was true on the machine rather than what was expected.
on statusBarIndexFor(proc)
    tell application "System Events"
        set barCount to 0
        try
            set barCount to count of menu bars of proc
        end try
        repeat with i from barCount to 1 by -1
            try
                if (count of menu bar items of menu bar i of proc) > 0 then return i
            end try
        end repeat
    end tell
    return 0
end statusBarIndexFor

on verbStatusItem(theTarget)
    tell application "System Events"
        set proc to my processForTarget(theTarget)
        set barIndex to my statusBarIndexFor(proc)
        if barIndex > 0 then
            return "{\"found\":true,\"idiom\":\"app-menu-bar-" & barIndex & "\"}"
        end if
        if theTarget does not start with "pid:" then
            try
                set sysProc to first application process whose name is "SystemUIServer"
                if (count of menu bar items of menu bar 2 of sysProc) > 0 then
                    return "{\"found\":true,\"idiom\":\"systemuiserver\"}"
                end if
            end try
        end if
        error "no status item found under either idiom for " & theTarget & "." number 1
    end tell
end verbStatusItem

on verbStatusClick(theTarget)
    tell application "System Events"
        set proc to my processForTarget(theTarget)
        set barIndex to my statusBarIndexFor(proc)
        if barIndex > 0 then
            set theItems to menu bar items of menu bar barIndex of proc
            click item 1 of theItems
            return "{\"clicked\":true,\"idiom\":\"app-menu-bar-" & barIndex & "\"}"
        end if
        -- U-defect-2: never fall back to SystemUIServer for a pid: target.
        -- That menu bar is shared by every status item on the system, so
        -- clicking "item 1" there cannot be verified to belong to the pid
        -- that was asked for — on a machine running both the harness's own
        -- isolated instance and the maintainer's own AgentMenu, guessing
        -- wrong here means clicking a control nothing here is allowed to
        -- touch. A pid: caller that cannot see its own item is told
        -- "not found", never routed through this fallback.
        if theTarget does not start with "pid:" then
            try
                set sysProc to first application process whose name is "SystemUIServer"
                set theItems to menu bar items of menu bar 2 of sysProc
                if (count of theItems) > 0 then
                    -- Best effort: correct only when this app's status item
                    -- is the only one present, which is true on the vanilla
                    -- golden image before any other app under test is
                    -- installed — the bundle-id form is only ever used on
                    -- the stranger tier, where that holds.
                    click item 1 of theItems
                    return "{\"clicked\":true,\"idiom\":\"systemuiserver\"}"
                end if
            end try
        end if
        error "no status item to click under either idiom for " & theTarget & "." number 1
    end tell
end verbStatusClick

on verbListIds(theTarget)
    tell application "System Events"
        set proc to my processForTarget(theTarget)
        set acc to {}
        try
            repeat with w in windows of proc
                my collectIdentifiers(w, acc)
            end repeat
        end try
        set barIndex to my statusBarIndexFor(proc)
        if barIndex > 0 then
            try
                my statusBarWalk(theTarget, barIndex, missing value, acc)
            end try
        end if
        return "{\"identifiers\":[" & my joinComma(my jsonStringList(acc)) & "]}"
    end tell
end verbListIds

-- ===== JSON helpers (no framework dependency, plain AppleScript) =====

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

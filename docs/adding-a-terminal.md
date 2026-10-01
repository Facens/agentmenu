# Adding a terminal

Terminal support is data too. A terminal manifest says how to open a window or
tab in a folder and run one command in it. There are two kinds, and both are
expressible without a Swift change.

- Bundled manifests: `AgentMenu.app/Contents/Resources/terminals/`
- Yours: `~/.config/agentmenu/terminals/` — overlays a bundled one with the same `id`
- A manifest that did not ship in the bundle is **untrusted** until you confirm
  it in settings: like an agent manifest, it names a process to run.

## The two kinds

**`applescript`** — the terminal is a scriptable macOS application. AgentMenu
builds one shell command string and hands it to your script, which delivers it
into a new tab or window. `write text` (iTerm2) and `do script` (Terminal.app)
run it in an interactive login shell.

**`argv`** — the terminal is a binary that takes a working directory and a
command as arguments. Nothing is interpreted by a shell unless the terminal
itself does it.

## Every key the loader reads

```toml
schema = 1                  # required
id = "iterm2"               # required, unique
display_name = "iTerm2"     # required
kind = "applescript"        # required: "applescript" or "argv"
enabled = true              # optional, default true
unverified = false          # optional, default false — `true` means it was never actually run
bundle_id = "com.googlecode.iterm2"   # applescript kind: required. Also the availability probe —
                                      # a terminal whose application is not installed is shown
                                      # as unavailable and cannot be launched.
binary = "ghostty"          # argv kind: required. Resolved and cached like an agent binary.
args = []                   # argv kind: required. Placeholders below.
applescript = """…"""       # applescript kind: required. The script, see below.
focus_applescript = """…"""     # applescript kind: optional. Brings a session's tab forward, see
                                # "Focusing a session" below. Without it AgentMenu cannot focus
                                # this terminal, and a click on its rows says so.
frontmost_tty_applescript = """…"""  # applescript kind: optional. Answers the tty of the tab on
                                # screen, see "Not notifying for the tab you are looking at"
                                # below. Without it a session here is never "frontmost".
```

### Placeholders

| Placeholder | Expands to |
|---|---|
| `{dir}` | the launch target's folder, unquoted |
| `{command}` | the full command line, already shell-quoted (`cd '…' && ENV=… /abs/path/agent --flags`) |
| `{dir_applescript}` | `{dir}` escaped for an AppleScript string literal |
| `{command_applescript}` | `{command}` escaped for an AppleScript string literal |

For an `applescript` manifest, prefer a script with `on run argv`: AgentMenu
passes the command as argument 1 and the folder as argument 2, so nothing has to
be escaped into the script text at all. Quoting a path for a shell does nothing
about the double quote and the backslash that delimit and escape an AppleScript
string — and both are legal in a macOS filename. The
`{command_applescript}` placeholder exists for scripts that must inline the
command, and it escapes for that layer too, but the argv form is the one that
cannot go wrong.

## Focusing a session

Clicking a live row in the Sessions tab brings that session's terminal window
and tab to the front. A terminal opts in with `focus_applescript`. Leave it out
and the terminal still launches sessions; clicking one of its rows just says
"`<name>` can't be focused from AgentMenu." An overlay written before this key
existed keeps working exactly that way.

The script is an `on run argv` script, and it gets the session's tty as
argument 1, always in the form `/dev/ttys004` — the form Terminal.app and
iTerm2 both report for a tab or session. The tty is an `osascript` argument
(`osascript -e '<script>' -- /dev/ttys004`), never spliced into the script
text, and a focus script gets none of the `{dir}` / `{command}` placeholders
above: what you read in the manifest is exactly what runs.

What the script returns:

- `not found` — no tab has that tty (the window or tab was closed). The row
  says so.
- anything else, including nothing — it found the tab and brought it forward.
- an error — shown on the row with the terminal's own words. A denied Apple
  Event (`-1743`) is recognised and shown with the fix: System Settings ›
  Privacy & Security › Automation.

Two things AgentMenu does for you, and one it asks of the script:

- Before any script runs, AgentMenu checks the application is running, by its
  `bundle_id`. Telling an application that is not running to do anything
  launches it, and clicking a row must not open an empty terminal. If it is
  not running the row says so and no script runs.
- Only a click runs a focus script. Listing sessions never sends an Apple
  Event.
- The script should also un-minimise the window and `activate` the app, which
  is what moves macOS to the window's Space.

Reading every tab's tty with one query (`tty of every tab of every window`)
is much faster than asking each tab in turn; the Terminal.app example does.
Only `applescript` terminals can be focused — an `argv` terminal has no Apple
Event to send, and a manifest that sets `focus_applescript` on one is
rejected.

## Not notifying for the tab you are looking at

When a session has been in Needs you for three seconds, AgentMenu posts a
notification, unless that session's tab is the one on screen: a prompt you are
already answering needs no banner. A terminal opts in to that check with
`frontmost_tty_applescript`.

The script takes no arguments and answers one thing: the tty of the tab (or
session) the user is looking at right now, in the same `/dev/ttys004` form as
the focus script, or nothing when the terminal has no window. Terminal.app:
`tty of selected tab of front window`. iTerm2: `tty of current session of
current tab of current window`.

What AgentMenu does around it:

- It asks once, when a hold-down expires, and only when the terminal is the
  frontmost app (`NSWorkspace`). A terminal in the background is never sent an
  Apple Event, so asking can never launch it.
- It asks only when this access was already granted (System Settings › Privacy
  & Security › Automation). It never raises the permission sheet from a
  background timer; focusing a row is what asks.
- Whatever goes wrong — no key, no grant, a script error, an answer that is not
  a tty — the session counts as **not** frontmost and the notification posts.
  A missing banner is worse than a redundant one.

Only `applescript` terminals can answer; an `argv` manifest that sets the key
is rejected.

## iTerm2, the verified example

```toml
schema = 1
id = "iterm2"
display_name = "iTerm2"
kind = "applescript"
bundle_id = "com.googlecode.iterm2"
enabled = true
unverified = false
applescript = """
on run argv
  set cmd to item 1 of argv
  tell application "iTerm"
    activate
    if (count of windows) = 0 then
      set w to (create window with default profile)
      tell current session of w to write text cmd
    else
      tell current window
        set t to (create tab with default profile)
        tell current session of t to write text cmd
      end tell
    end if
  end tell
end run
"""
focus_applescript = """
on run argv
  set target to item 1 of argv
  tell application "iTerm"
    repeat with w from 1 to count of windows
      set theWindow to window w
      repeat with t from 1 to count of tabs of theWindow
        set theTab to tab t of theWindow
        repeat with s from 1 to count of sessions of theTab
          set theSession to session s of theTab
          if (tty of theSession) is target then
            try
              if miniaturized of theWindow then set miniaturized of theWindow to false
            end try
            select theWindow
            select theTab
            select theSession
            activate
            return "focused"
          end if
        end repeat
      end repeat
    end repeat
  end tell
  return "not found"
end run
"""
frontmost_tty_applescript = """
tell application "iTerm"
  if (count of windows) = 0 then return ""
  return tty of current session of current tab of current window
end tell
"""
```

A new tab in the existing window, a new window when the app has none — the
behaviour of the SwiftBar plugin this app replaces. It only ever types into the
session it has just created (`write text` is sent to the new tab's or new
window's own session, never to an existing one). The focus script selects the
session whose `tty` matches, then its tab, then its window.

## Terminal.app, enabled and verified

```toml
schema = 1
id = "terminal-app"
display_name = "Terminal"
kind = "applescript"
bundle_id = "com.apple.Terminal"
enabled = true
unverified = false
applescript = """
on run argv
  set cmd to item 1 of argv
  tell application "Terminal"
    activate
    do script cmd
  end tell
end run
"""
focus_applescript = """
on run argv
  set target to item 1 of argv
  tell application "Terminal"
    set ttyLists to tty of every tab of every window
    if ttyLists is {} then return "not found"
    -- One window can answer a flat list; make it a list of lists either way.
    if class of item 1 of ttyLists is not list then set ttyLists to {ttyLists}
    repeat with w from 1 to count of ttyLists
      set tabTTYs to item w of ttyLists
      repeat with t from 1 to count of tabTTYs
        if (item t of tabTTYs) is target then
          set theWindow to window w
          set selected tab of theWindow to tab t of theWindow
          try
            if miniaturized of theWindow then set miniaturized of theWindow to false
          end try
          set index of theWindow to 1
          activate
          return "focused"
        end if
      end repeat
    end repeat
  end tell
  return "not found"
end run
"""
frontmost_tty_applescript = """
tell application "Terminal"
  if (count of windows) = 0 then return ""
  return tty of selected tab of front window
end tell
"""
```

This one is enabled, and it is the only terminal that is enabled without
being installed-and-chosen first, because Terminal.app is the one a stock Mac
always has: without it, a first run ends with a configured folder and nothing
to launch it in. iTerm2 still wins where it exists — terminals load in
filename order, so `iterm2` is offered the default first.

Verified 2026-09-21 the way step 2 below asks, in a folder named
`~/dev/it's a project` — a space and an apostrophe, the case that breaks
naive quoting. It claims nothing beyond what `do script` documents with no
target: a new window every time, never the front window's active tab. A script
that typed into an existing window would send the command into whatever is
running there, a session AgentMenu hosts included, so a terminal manifest
must always open a fresh tab or window. If you want a new tab instead of a
new window, changing it is exactly the kind of manifest-only fix a user
overlay is for.

## An argv example

```toml
schema = 1
id = "ghostty"
display_name = "Ghostty"
kind = "argv"
binary = "ghostty"
args = ["--working-directory={dir}", "-e", "{command}"]
enabled = false
unverified = true
```

## Writing one

1. Copy the closest example into `~/.config/agentmenu/terminals/<id>.toml`.
2. Run the script or the command by hand first — `osascript` for the AppleScript
   kind, the binary directly for the argv kind — with a folder whose name
   contains a space and an apostrophe. That is the case that breaks naive
   quoting.
3. Set `unverified = false` only once you have actually launched a session
   through it.
4. Confirm the untrusted manifest in settings, then select it.

## What ships today

| id | kind | state |
|---|---|---|
| `iterm2` | applescript | verified — the plugin this app replaces proves it; focus script |
| `terminal-app` | applescript | enabled, verified 2026-09-21; focus script |
| `ghostty` | argv | present, disabled, unverified |

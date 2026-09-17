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
```

A new tab in the existing window, a new window when the app has none — the
behaviour of the SwiftBar plugin this app replaces.

## Terminal.app, present but unverified

```toml
schema = 1
id = "terminal-app"
display_name = "Terminal"
kind = "applescript"
bundle_id = "com.apple.Terminal"
enabled = false
unverified = true
applescript = """
on run argv
  set cmd to item 1 of argv
  tell application "Terminal"
    activate
    if (count of windows) = 0 then
      do script cmd
    else
      do script cmd in window 1
    end if
  end tell
end run
"""
```

Nobody has run this one by hand yet (see step 2 below), so it claims nothing
beyond what `do script` itself documents: a new window when Terminal has
none, or the front window's active tab when one is already open. Verifying it
— and, if it does not already do what you want, changing it to open a new tab
instead — is exactly the kind of manifest-only fix a user overlay is for.

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
| `iterm2` | applescript | verified — the plugin this app replaces proves it |
| `terminal-app` | applescript | present, disabled, unverified |
| `ghostty` | argv | present, disabled, unverified |

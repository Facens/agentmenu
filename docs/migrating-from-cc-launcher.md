# Migrating from cc-launcher

Before AgentMenu, the maintainer's shell kept its own copy of the
folder→account mapping in `~/.config/cc-launcher/folders.conf`, read by
`~/.local/bin/claude-id`. AgentMenu is now the place that mapping lives —
`config.toml`'s `[[profiles]]` and `[[folders]]`. This doc covers two things:
importing the old file once, and the status-line bridge that came along
separately (R26/R47). A plan to also wire `claude-id` itself to ask AgentMenu
(R30) is dropped — see [§2](#2-no-shell-resolver).

## 1. The old file

There is no import button. Each line of `folders.conf` is
`Label | /absolute/path | identity`, and each one becomes a `[[folders]]`
entry in `config.toml` — add them from **Settings → Folders**, on the account
tab the identity names. The bundled CLI's `import` subcommand carries the
mapping below, but it is an internal diagnostic, not a command you are
expected to type: nothing puts `agentmenu` on your `PATH`.

A missing third field is not an error — the folder is imported with no
profile pinned, the same way `claude-id` itself falls through to its other
precedence layers when the line names none. An identity is matched to a
profile by the configuration directory it names (`work` → `~/.claude`,
anything else `x` → `~/.claude-x`, matching `claude-id`'s own mapping), so an
existing profile for that directory is reused whatever it is called — first
run names the suffix-less `~/.claude` "default", and `work` must not become a
second profile pointing at the same account. Only when no profile has that
directory is one created, rather than the folder being dropped. Importing
again is safe: a folder already at a normalized path already in
`config.toml` is skipped and reported, never duplicated.

## 2. No shell resolver

The plan to rewire `claude-id` — replacing its own scan of `folders.conf`
with a call to `agentmenu resolve` (R30) — is reversed. AgentMenu does not
offer a shell resolver. The app is the launcher: you pick the folder from its
popover, not from a hand-typed `cc` in a terminal that is already sitting in
the wrong account. A shell script that still needs the folder→account
mapping keeps its own copy, the same way `claude-id` always has;
`folders.conf` stays that copy's home, and AgentMenu does not replace it.

`agentmenu resolve <dir> [--profile|--config-dir|--command]` still exists in
the bundled CLI, but as a diagnostic — it is not wired into any shell, and
there is no guarantee its output or its exit codes stay the same across
releases:

```
agentmenu resolve <dir> --profile      # prints the profile id, e.g. "personal"
agentmenu resolve <dir> --config-dir   # prints the expanded CLAUDE_CONFIG_DIR
agentmenu resolve <dir> --command      # prints the exact command the popover would launch
```

`resolve` exits non-zero and prints nothing on stdout when the directory
isn't configured, and the same is true for a folder that `import` brought in
with no third field: `--profile`/`--config-dir` exit non-zero for it too
rather than guessing.

## 3. The status-line bridge (R26, R47)

Claude Code hands rate-limit data to exactly one place: the stdin JSON of
whatever command `statusLine` names in `settings.json`, under
`rate_limits` → `{five_hour, seven_day}`. There is no `claude usage`
subcommand and no hook receives this. AgentMenu points `statusLine` at a
small bridge script so it can read the same data every other user's shell
already has.

Install it from **Settings → Accounts**, per profile. Installing:

1. Prints the settings file path and the key it is about to touch
   (`statusLine.command`) before writing anything.
2. Writes `agentmenu-statusline.sh` into the profile's configuration
   directory (`chmod 0755`).
3. Rewrites `statusLine` in that profile's `settings.json` to run the
   script — every other key in the file survives byte-for-byte.
4. **Chains, never replaces (R26).** If a status line was already
   configured, the script invokes it with the same stdin and mirrors its
   stdout and exit status, so it keeps working exactly as before —
   AgentMenu is additive, not a replacement.
5. Installing again is idempotent: it recognises its own script and
   recovers the original chain instead of nesting a bridge inside a bridge.

### `statusline-bridge` (hidden)

`agentmenu statusline-bridge --profile-dir <dir> [--chain <command>]` is
what the installed script execs on every refresh. It is not meant to be
typed by hand — it is left out of `--help` — but if you are reading
`agentmenu-statusline.sh` and wondering what it calls: this is it. It reads
stdin once, writes `tb-rate-snapshot.json` and `tb-rate-history.jsonl`
(throttled to once a minute — a status line runs constantly and neither
file needs to track every refresh), then runs `--chain`, if any, with the
same stdin and copies its stdout/exit status through unchanged. A failure
writing either file is swallowed — the chained status line's own output
must still appear no matter what; a failure in the chained command itself
is not swallowed, and propagates its exit status.

### Undoing an install

There is no uninstall button — the change is small enough to reverse by
hand:

1. Open the profile's `settings.json` and replace the `statusLine` value
   with whatever chain the install reported finding (shown at install time,
   and readable afterwards from `agentmenu-statusline.sh`'s own `--chain
   '...'` argument — everything between the quotes after `--chain` is
   exactly the command that was there before). An empty `--chain ''` means
   there was nothing configured before install; delete the `statusLine` key
   entirely in that case.
2. Delete `agentmenu-statusline.sh` from the profile's configuration
   directory.
3. `tb-rate-snapshot.json` and `tb-rate-history.jsonl` are harmless to leave
   behind — they stop being written once `statusLine` no longer points at
   the bridge — but delete them too if you want a clean directory.

### `AGENTMENU_CONFIG`

Every `agentmenu` command reads `~/.config/agentmenu/config.toml` unless
the environment variable `AGENTMENU_CONFIG` names a different path, in
which case that path is used instead. This exists for testing — it is how
this project's own test suite points the CLI at a throwaway `config.toml`
instead of ever touching the real one — not for routine use; it is not
documented in `--help` for the same reason `statusline-bridge` isn't.

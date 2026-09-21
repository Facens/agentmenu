# Adding an agent

Agent support in AgentMenu is **data**. An agent is a TOML manifest declaring
the binary to run, how a profile reaches it, and which flags carry model,
effort, permission mode and advisor state. Adding one needs no Swift change and
no release.

- Bundled manifests live in `AgentMenu.app/Contents/Resources/agents/`.
- Your own live in `~/.config/agentmenu/agents/`.
- A manifest in your directory **overlays** a bundled one with the same `id`, so
  you can fix a shipped agent without forking anything.

A manifest names the binary that will be executed, the environment variable it
runs with, and static arguments it always receives. That makes it an executable
specification, not inert configuration — so **any manifest that did not ship
inside the app bundle is marked untrusted and must be confirmed before it can
become the active agent.**

## Every key the loader reads

```toml
schema = 1                       # required. The loader refuses a schema it does not know.
id = "claude-code"               # required, unique. Matching a bundled id overlays it.
display_name = "Claude Code"     # required. Shown in the settings window.
binary = "claude"                # required. Resolved with `zsh -ilc 'whence -p -- "$1"'`
                                 #   once (the binary is passed as a positional parameter, never
                                 #   spliced into the script text), then cached in config.toml.
                                 #   Never a shell alias. Must be an absolute path or a plain name
                                 #   matching `^[A-Za-z0-9._+-]+$` — anything else is refused at
                                 #   parse time, before it ever reaches the shell.
enabled = true                   # optional, default true. `false` = listed but not selectable.
unverified = false               # optional, default false. `true` = the flags below were not
                                 #   executed against the real binary; the UI says so and the
                                 #   agent cannot be selected until you enable it anyway.
verified_version = "2.1.266"     # optional. Which binary version the values were checked against.
verified_on = "2026-09-09"       # optional. When.

project_arg = "none"             # optional, default "none".
                                 #   "none"       the folder is the terminal's working directory
                                 #   "positional" the folder is passed as the last argument
extra_args = []                  # optional. Static arguments added to every launch.
                                 #   REJECTED if one of them is a value this manifest also
                                 #   declares under permission_mode.values — a permission
                                 #   bypass may only arrive through the structured field, which
                                 #   is the one the dropdown marks before you click. Caught both
                                 #   as an exact element ("bypassPermissions") and as the value
                                 #   half of a "--flag=value" element, since a real CLI's parser
                                 #   accepts both forms. The same rejection applies to
                                 #   [advisor].disable_args — any static-argument field, not just
                                 #   extra_args — and to model.flag / effort.flag / advisor.flag /
                                 #   profile_flag naming the exact same flag as
                                 #   permission_mode.flag: two capabilities may never share one
                                 #   CLI flag, because that is how an unmarked value could ride
                                 #   the flag the dropdown marks.

profile_env = "CLAUDE_CONFIG_DIR"  # either this…
profile_flag = "--config-dir"      # …or this. A profile is an account; it reaches the agent as
                                   # an environment variable holding the profile's directory, or
                                   # as a flag taking that directory. Declare exactly one, or
                                   # neither if the agent has no notion of separate accounts.

settings_file  = "{profile_dir}/settings.json"          # optional. Read once, on first run, to
                                                        # seed the defaults. Never written.
usage_snapshot = "{profile_dir}/tb-rate-snapshot.json"  # optional. Omit it and the rate-limit
                                                        # readout is simply hidden for this agent.
```

`{profile_dir}` is the only placeholder, and it expands to the profile's
configuration directory.

### Capability sections

Each section below is **optional, and omitting it means the agent does not have
that capability** — the control disappears from the interface rather than being
shown disabled or, worse, sent to a binary that does not understand it.

```toml
[model]
flag = "--model"                       # required in this section
values = ["fable", "opus", "sonnet"]   # required. The only values the UI offers.
seed_from_settings = "model"           # optional. Key read from settings_file on first run.

[effort]
flag = "--effort"
values = ["low", "medium", "high", "xhigh", "max"]

[permission_mode]
flag = "--permission-mode"
values = ["acceptEdits", "auto", "bypassPermissions", "manual", "dontAsk", "plan"]
bypass_values = ["bypassPermissions"]  # optional. A target whose *effective* permission mode is
                                       # one of these is marked in the dropdown before the click,
                                       # inherited or not. Declare it if the agent has a mode that
                                       # stops asking. OMITTING this key does NOT mean "nothing is
                                       # marked" — it defaults to *every* value in permission_mode.
                                       # values, so a mode you forget to classify is marked rather
                                       # than silently unmarked. Write `bypass_values = []`
                                       # explicitly if the agent genuinely has no bypassing mode.
                                       # Every declared value must also appear in
                                       # permission_mode.values — a manifest is rejected otherwise.

[advisor]
flag = "--advisor"                     # takes a model argument
values = ["opus", "sonnet", "fable"]
disable_args = ["--settings", "{\"advisorModel\":\"\"}"]  # optional. How to turn it off for one
                                                          # session. Omit it and the advisor
                                                          # becomes enable-only, and the off
                                                          # switch is not shown.
seed_from_settings = "advisorModel"
rank_order = ["sonnet", "opus", "fable"]  # optional. The agent's models weakest first, for an
                                          # agent that refuses to let a weaker model advise a
                                          # stronger one. Declare it and every [model].values and
                                          # [advisor].values entry must appear in it, or the
                                          # manifest is rejected — a model ranked nowhere is a
                                          # model the rule would skip. Omit it and every pairing
                                          # is accepted.
```

**A value can be refused for the company it keeps.** Claude Code accepts `opus`
as an advisor and `fable` as a model, and refuses the two together: `"opus"
cannot advise "claude-fable-5-1" (the advisor must be at least as capable as the
main model)`, after which it runs with no advisor at all. `rank_order` is how a
manifest says so, and AgentMenu then **raises** the advisor to a model that
reaches the main model's class rather than dropping the flag — dropping it would
hand the decision back to `advisorModel` in the agent's own settings file, which
is where the weaker advisor usually came from.

**Values are validated before launch, not after.** Claude Code, for instance,
answers an unknown `--effort` value with a warning and then quietly uses its
default. An unsupported value therefore never reaches the binary: it is reported
as unsupported for that agent and the flag is omitted.

## Writing one

1. Copy `Resources/agents/claude-code.toml` to
   `~/.config/agentmenu/agents/<your-agent>.toml`.
2. Change `id`, `display_name`, `binary`, and the profile mechanism.
3. **Execute each flag against the real binary** before you list its values, and
   record what you found in `verified_version` / `verified_on`. Leave
   `unverified = true` until you have.
4. Delete every section the agent does not have. An absent section is the honest
   answer; a present one with guessed values is not.
5. Open AgentMenu's settings, Agents pane. Your manifest appears as untrusted;
   confirm it, then select it.

If it works, open an issue with the file attached — verified community manifests
get listed in the README. That route needs no contribution grant, because the
file is yours (see [CONTRIBUTING.md](../CONTRIBUTING.md)).

## What ships today

| id | state | why |
|---|---|---|
| `claude-code` | verified, enabled | every flag executed against 2.1.266 |
| `opencode` | present, disabled, unverified | the binary is installed but its model and effort flags were never executed |
| `codex` | present, disabled, unverified | the binary was not installed on the development machine, so any flag here would be a guess |

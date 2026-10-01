# Sessions

The popover has two tabs, Launch and Sessions. It always opens on Launch,
because starting a session is still the thing you open it for. Sessions is where
you see what is already running, find the one that is waiting for you, and bring
back the ones that ended.

This page covers the tab, "keep running when the window closes", restore,
notifications, the macOS permissions involved, where AgentMenu keeps its own
state, and what it never does.

## The Sessions tab

**Live and Closed.** A toggle at the top switches between the sessions running
now and the ones that ended. Closed is described under "Restore" below.

**What a row shows.** Live sessions are grouped by folder, and a pill on each
row names the account (Work, Personal) it runs on. A session that is waiting
for you moves into a Needs you group at the top. Each row carries one status:

| Status | Meaning |
|---|---|
| Working | The agent is in the middle of a turn. |
| Needs you | The agent has stopped and is asking you something: a permission prompt, a question, a sandbox request. |
| Your turn | The agent finished its turn and is waiting for your next message. |
| Unknown | AgentMenu has no usable signal. It shows the session as running and does not guess. |

A session AgentMenu launched with "keep running" on and whose window you have
closed also carries a **Detached** marker. Detached is not a status: a detached
session can be Working or Needs you like any other.

**Rename.** The row menu has Rename. The name is AgentMenu's own and is stored
with its state, not in the agent's files.

**Quit.** The row menu has Quit, for any live session, whether or not AgentMenu
started it. If the session is in the middle of a turn, a dialog says so first:
quitting then loses the answer it was working on, and the conversation up to
your last message is kept. The menu in the tab's header has **Quit all**, which
ends only the sessions AgentMenu started, and says how many and on which
accounts before it does.

**Click a row.** Clicking a live row brings its Terminal.app or iTerm2 tab to
the front. It only does this when that terminal is already running: AgentMenu
will not open a terminal to answer a click. A terminal that has no focus script
(see [adding-a-terminal.md](adding-a-terminal.md)) is told so on the row.

**Other agents.** A session of an agent other than Claude Code is listed with
process-level status only: it is running, or it is not. There is no Working or
Needs you for it, because nothing on the machine says so.

### Where the status comes from

Claude Code keeps a registry of its running sessions, one file per process, in
each account's configuration directory (`sessions/<pid>.json`), and a transcript
of each conversation under `projects/`. AgentMenu watches those files for
changes and reads them. It **never writes to them**, and it adds nothing to the
agent's configuration to get this. Both are undocumented Claude Code
internals, so a format change in a future release shows up as Unknown rather
than as a wrong status.

## Keep running when the window closes

By default, a session launched from AgentMenu keeps going when you close its
terminal window. It is not tied to the window.

It works by running the agent under a small, invisible tmux that ships inside
the app (a static tmux 3.7c in `Contents/Helpers`). AgentMenu starts that tmux
with its own socket and its own configuration. It never touches a tmux you run
yourself and never reads or writes `~/.tmux.conf`.

- **Closing the window** leaves the agent running. The row shows Detached.
- **Clicking the row** opens a window and reattaches to it. iTerm2 uses the same
  plain attach as Terminal.app.
- **Quitting AgentMenu** does not end these sessions. They live in the tmux
  server, not in the app.
- **Every launch is a new window.** Terminal.app launches always open a new
  window, never a tab of an existing one, so a command can never be typed into a
  session that is already running.

### The setting

`keep_running` is a field of a preset, like model and effort. It is on by
default and can be set three ways:

- globally, in the global default;
- per folder, in that folder's preset — this is the off switch for a folder where
  you want an ordinary session that ends with its window;
- once, for one launch, in the row's expanded options. The saved preset is left
  alone, as with any other one-shot override.

In `config.toml` it is a boolean: `keep_running = false`.

### Terminal.app: Shift+Enter

Inside tmux, Terminal.app cannot tell Shift+Enter from Enter, so Shift+Enter
sends the message instead of starting a new line. Two ways round it, in any
Claude Code session in Terminal.app:

- press **Ctrl+J** for a new line, or
- type `\` and then Enter.

Two more things differ from a plain Terminal.app session. Scroll with the mouse
wheel. To select text, hold **Option** and drag. These are
Terminal.app's limits. iTerm2 attaches the same way, and nothing here has
been found to differ for it.

If these cost more than keeping the session running is worth to you, turn
`keep_running` off for that folder. The session is then an ordinary one: no tmux,
no Detached, and it ends when its window does.

## Restore

AgentMenu records the sessions it starts as they happen, not at quit, so the
record is there after a crash or a power cut. What each ended session becomes
depends on how it ended.

**Quit a session yourself** (the row's Quit). It moves to Closed. **Reopen last
closed** brings back the most recent one, from the header menu or with
**Shift-Command-T** while the popover is open.

**Everything else** — Quit all, a restart, a crash, a power loss, or the session
host dying — puts the sessions in one set
that **Reopen all** from the header menu brings back ("Reopen all from last
time"). After a restart a banner at the top of the popover offers the same
button, with a cross to dismiss it without losing the set.

**Reopen sessions at login** is a setting that does this for you when you log
in. AgentMenu asks about it once, in that banner, and not before. The setting
can be changed afterwards in Settings.

**Host death never restores on its own.** If the tmux server stops unexpectedly,
AgentMenu posts one notification saying how many sessions ended and offering Reopen
all. It does not start anything until you say so.

**History.** The Closed view also lists Claude Code conversations AgentMenu did not
start: any transcript from the last 30 days. Resuming one uses the account of
the profile whose configuration directory holds that transcript.

Every resume is guarded. AgentMenu checks that the session is not already
running, in any account, and refuses to resume one that is. A session that never
got a first message has nothing to resume and is left out of the list.

## Notifications

Two notifications, each with its own toggle under **Settings → General →
Notifications**:

- **Needs you.** When a session has been in Needs you for **3 seconds**, a
  notification names it. If that session's tab is the one in front of you, there
  is no notification: you are already looking at the prompt. The 3 seconds is so a
  prompt you answer at once never banners at all.
- **Your turn**, for sessions AgentMenu started only: when one finishes a turn
  that took **30 seconds or more**. A short answer is not worth a banner.

Both are on by default. macOS is asked for notification permission the first
time you launch a session from AgentMenu or switch one of the toggles on. If
you refuse, the toggles say so next to themselves rather than reading as on.

## Permissions

| Permission | Why | When it is asked |
|---|---|---|
| **Automation** (System Settings → Privacy & Security → Automation) | Bringing a Terminal.app or iTerm2 tab forward is an Apple Event sent to that terminal. | The first time you click a row, per terminal. Denied, the row says so and names the setting, with `tccutil reset AppleEvents dev.facens.agentmenu` as the fallback. While the sheet is up AgentMenu waits for your answer and does not time the launch out: macOS would record a timed-out sheet as "Don't Allow". |
| **Notifications** | The two notifications above. | See "Notifications". |

The Needs you check for "is this tab in front" also uses the Automation grant,
but only when it was already given: it never raises the permission sheet from a
timer. Without the grant the notification posts as if the tab were not in front,
because a missing banner is worse than a redundant one.

Nothing here needs Full Disk Access, Accessibility or a login.

## Where state lives

AgentMenu's own record of sessions is in
`~/Library/Application Support/<bundle id>/` (`dev.facens.agentmenu` for a
release), not in `config.toml`. `config.toml` is settings you can edit by hand;
this is state the app writes on every launch, quit and rename. In that folder:

- `sessions.json` — the sessions AgentMenu started, the closed stack and the set
  waiting to be reopened. It is written atomically, and a file that cannot be
  read is left alone rather than replaced.
- `host/<tmux version>/` — the bundled tmux's copy, its configuration and its
  socket. The socket is a file in that directory, not a network port. If your home
  directory path is too long for a Unix socket, the host uses
  `/Users/Shared/.agentmenu-<uid>/…` instead, still yours alone.

The agent's own files — registry, transcripts, settings — stay where Claude Code
keeps them, and are read only. The one thing AgentMenu writes into an agent's
configuration is the optional status-line bridge; see the README.

## What AgentMenu never does

- It never writes to an agent's session registry or transcripts.
- It never edits an agent's configuration directory except for the status-line
  bridge you install yourself.
- It never touches your own tmux, its sockets or `~/.tmux.conf`.
- It never resumes a session that is already running, and never starts one
  because a host died. It offers, and waits.
- It never opens a terminal to answer a click on a row.

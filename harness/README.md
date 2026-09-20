# First-run harness

A first run is the one thing neither app has ever been watched doing. This
directory is the test bed that watches it: one command per tier per app, one
scenario vocabulary, one report shape.

Two tiers:

- **stranger** — a Tart macOS VM cloned per run from the golden image
  `first-run-golden` and discarded afterwards, so no run ever sees another
  run's state. This is the tier that sees Gatekeeper, permission prompts and a
  machine with no tools on it.
- **app-fresh** — a local Developer ID build on the maintainer's Mac against
  an isolated configuration root. Faster to iterate on, blind to system state.

## Commands

```
harness/run.sh start --app <agentmenu|meetinghop> --tier <stranger|app-fresh> \
                     --scenario <name> [--asset <zip>] [--nonce <hex>]
harness/run.sh wait <run-id> [--max-secs N]
harness/run.sh status <run-id> [--json]
harness/run.sh selfcheck --tier stranger [--list-ids <bundle-id>|pid:<n>]
harness/run.sh clean [--age-days N] [--dry-run]
harness/sync-check.sh [--other-dir DIR] [--require] [--list]
```

`start` prints one thing on stdout: the run id. Everything else — logs,
warnings, refusals — goes to stderr, so `RUN=$(harness/run.sh start …)` is the
intended idiom.

### Exit codes

The same taxonomy everywhere under `harness/`, host side and in the guest:

| code | meaning |
|---|---|
| 0 | pass — the scenario reached its stated end state |
| 1 | scenario fail — it did not |
| 2 | usage error — bad arguments, an unknown run id, two guests already running |
| 3 | harness error — the harness could not decide: a watchdog fired, the guest never came up, the supervisor vanished |

`wait` mirrors the run's code. `wait --max-secs N` expiring while the run is
genuinely still alive is a harness error (3), not a pass — the run keeps
going, and `status` still reports it. `status` is a query: 0 whenever it could
report, 2 on an unknown run id.

A verdict and a finding are different things. `verdict` is `pass`, `fail` or
`error`; `findings[]` is an orthogonal list of codes, and a scenario can pass
and carry a finding at the same time — "the vanilla first run ends with no
usable terminal" is a finding about the product, not a failed run.

## Run directories

Runs land under `dist/harness/<run-id>/`, which is gitignored:

```
report.json          run state and report, rewritten atomically
journal.ndjson       the app journal pulled back from the guest
evidence.ndjson      one line per system dialog answered
steps.ndjson         one line per step, appended as the run goes
findings.list        one finding code per line, appended by the scenario
screenshots/NNN-<label>.png
clone.name           the clone this run owns, written before it is created
supervisor.pid       the supervisor's PID and its start time
supervisor.log       everything the supervisor and the scenario printed
start.ok             the handover marker (see below)
```

The run id is `<app>-<tier>-<scenario>-<UTC yyyymmddTHHMMSSZ>-<6 hex>` and
always matches `^[A-Za-z0-9._-]{1,128}$` — it names a directory and a VM
clone, so it is validated rather than trusted.

`report.json` carries `run_id`, `nonce`, `supervisor_pid`, `supervisor_token`,
`app`, `tier`, `scenario`, `scenario_path`, `asset`, `asset_sha256`,
`golden_image`, `clone`, `image` (the golden image's build inputs, read from
`/etc/first-run-golden.json` in the guest), `status`, `verdict`,
`outcome_kind`, `stale`, `findings[]`, `retries`, `steps[]`, `started_at`,
`ended_at`, `exit_code` and `run_dir`.

`HARNESS_DIST_ROOT` moves the run root elsewhere; the test suite uses it so
nothing ever writes into the repository's own `dist/`.

## How a run is supervised

`start` is synchronous and short. It validates, refuses, allocates the run id,
writes `report.json` with `status: "running"`, forks the supervisor with its
output redirected into `supervisor.log`, records the supervisor's PID and
start time, and only then touches `start.ok`. The supervisor blocks on
`start.ok` before it writes anything, so exactly one process owns
`report.json` at any moment and every write is a temp file moved into place —
a reader never sees half a document.

Nothing polls for "the process I started" with the `wait` builtin: the
supervisor is nobody's child once `start` returns. Two facts stand in for it:

- **The supervisor's exit code is written into `report.json` before it
  exits.** `wait` reads it from there.
- **Liveness is PID plus a start token**, the process's own start time as
  `ps -o lstart=` reports it. A PID alone can be recycled and would make a
  finished run look eternally alive; a recycled PID cannot reproduce the
  token.

A supervisor that vanished without writing an exit code — SIGKILL, a host
crash, a pulled power cable — is resolved by `wait` and `status` to
`outcome_kind: "harness_error"` with `stale: true` and exit 3, rather than
reported as running forever.

Teardown is a trap on `EXIT`, `INT`, `TERM` and `HUP`, so the clone goes away
on a normal finish, on a watchdog's SIGTERM, and on Ctrl-C. `wait` forwards
its own interrupt to the supervisor for the same reason: Ctrl-C while waiting
tears the run down instead of orphaning a VM. Every teardown step is bounded —
macOS has no `timeout(1)`, and a hung `tart delete` inside the trap would keep
the exit code out of `report.json` forever. What a SIGKILL or a crash leaves
behind is what `clean` is for.

**Watchdogs** nest, last in first out: per-run (`HARNESS_RUN_TIMEOUT`), per
scenario (`HARNESS_SCENARIO_TIMEOUT`), per step (`HARNESS_STEP_TIMEOUT`, used
by the scenario library). The scenario runs in its own process group and is
group-killed, so its children — ssh, osascript, screencapture — go with it.
The supervisor is never group-killed: that would signal the watchdog and race
the orderly teardown its own trap performs. A watchdog that fires leaves
`watchdog-<label>.fired` in the run directory, which is how the supervisor
tells "the scenario failed" from "the scenario never returned".

**Retries** are infrastructure only, exactly once, always on a fresh clone:
clone, boot and copy-in. A scenario that fails is never retried. The count
lands in `report.json` as `retries`.

**Two guests.** Apple's Virtualization framework allows two concurrent macOS
guests per host, so `start` counts running VMs in `tart list` — whatever their
names, the maintainer's own VMs take the same slots — and refuses with exit 2
before it creates anything. Stopped harness clones take no slot: they are
named, with a pointer to `clean`, and never block a run.

## Writing a scenario

A scenario is a bash script at `harness/scenarios/<app>/<name>.sh`, run by the
supervisor as a separate process. It exits 0 for pass, 1 for fail, 3 for a
harness error, and receives:

| variable | meaning |
|---|---|
| `HARNESS_ROOT`, `HARNESS_DIR` | the repository root and this directory |
| `HARNESS_RUN_ID`, `HARNESS_RUN_DIR` | the run and where its evidence goes |
| `HARNESS_APP`, `HARNESS_TIER`, `HARNESS_SCENARIO` | what is under test |
| `HARNESS_ASSET`, `HARNESS_ASSET_SHA256` | the zip the stranger tier installs |
| `HARNESS_NONCE` | the run nonce the journal's first line must carry |
| `HARNESS_CLONE`, `HARNESS_GUEST_IP` | the guest, on the stranger tier |
| `HARNESS_GUEST_USER`, `HARNESS_GUEST_HOME`, `HARNESS_GUEST_TRANSPORT` | how to reach it |
| `HARNESS_SHOT_DIR`, `HARNESS_JOURNAL`, `HARNESS_EVIDENCE` | where evidence goes |
| `HARNESS_STEPS`, `HARNESS_FINDINGS` | the two append-only files below |
| `HARNESS_STEP_TIMEOUT` | the per-step bound |

Steps are appended to `$HARNESS_STEPS` as they happen, one JSON object per
line, and the report compiler slurps them into `steps[]` at the end:

```json
{"step":"setup card","status":"ok","screenshot":"…/002-setup.png","at":"2026-09-18T12:00:00Z"}
```

`status` reads the last line of that file to answer "what is it doing now", so
a step is written when it starts as well as when it ends. Findings are one
code per line in `$HARNESS_FINDINGS`, from the checked-in list — never free
text, because the redacted public report is built from them.

The guest side is reached through `guest_run`, `guest_copy_in` and
`guest_copy_out` from `lib/vm.sh`. They are indirectable: on the stranger tier
they are ssh and scp against the clone, on the app-fresh tier
`HARNESS_GUEST_TRANSPORT=local` turns them into a local shell and a local
copy, and the scenario does not change. The harness tree is copied into the
guest at `~/.harness/`, so guest scripts live at `~/.harness/guest/<name>` and
never have to know the user name; they take paths as arguments and each prints
exactly one JSON object on stdout.

The stranger tier reaches the guest as `HARNESS_GUEST_USER` (default `admin`)
over ssh with `BatchMode=yes`, so the golden image must accept the host's key;
`HARNESS_SSH_OPTS` replaces the option list if it has to.

## Only the stranger tier drives the screen

The app-fresh tier isolates files, not the display. It runs inside the
maintainer's own graphical session, so a run that opens a popover or clicks a
control is visible to them and competes for their input. That is not
hypothetical: an app-fresh probe once launched isolated instances and pressed
the status item while the maintainer was away, and they came back to two
menu-bar icons clicking by themselves.

So anything that clicks, captures the screen or waits on a window is
stranger-tier only, and the harness enforces it rather than documenting it.
`selfcheck` refuses `--tier app-fresh` outright, because proving the screen
grants is screen work by definition. In a scenario, `shot`, `click`,
`dialog`, `open_status_item`, `wait_for_status_item` and `ax_window_count`
all refuse on that tier. `expect_event` keeps working and simply stops asking
`wait.sh` for a diagnostic screenshot on timeout.

A refusal stops the scenario; it is never a silent no-op. That distinction
cost a real bug: a helper called through command substitution, as
`if [ "$(ax_window_count …)" -gt 0 ]`, only ends its own subshell, so the
scenario took the other branch and ran on to report a pass. The refusal now
signals the scenario's own process, which the supervisor records as a harness
error. The consequence is worth knowing: a bare call exits 2, while a call
reached through command substitution dies by signal and is reported as 3.
Bash 3.2, which is what macOS ships, offers no way to make a subshell's exit
code visible to a caller that has suppressed errexit, and stopping loudly
beats continuing quietly.

## What the app-fresh tier proves, and the one thing it cannot

The app-fresh tier runs against the maintainer's own logged-in Mac, so it has
to prove it left their state alone. `lib/snapshot.sh` hashes the config and
manifests under `~/.config/agentmenu/`, every `~/.claude*` entry, the app's
own Application Support directory and the real `dev.facens.agentmenu` defaults
domain, before the app launches and again after it quits. Any difference fails
the run, and the diff names the paths.

One case is not the app's fault. Claude Code drives these runs and writes into
its own directory under a `~/.claude*` root while it does, so a run can see
that tree change inside its own before-and-after window with the app never
having touched it. `HARNESS_SNAPSHOT_EXCLUDE` is the way out: a
colon-separated list of glob patterns, empty by default, matched against each
absolute path.

Nothing is dropped quietly. Every pattern is written into the snapshot as an
`excluded` line, so the manifest records which part of the check was skipped
and anyone reading the report can see it. Exclude the narrowest path that
covers the churn and never a whole root: `~/.claude-personal` is a profile
directory the app may legitimately write to, and excluding it would hide
exactly the escape this check exists to catch. With an exclusion active, a
write anywhere else still fails the run.

## Shared files

`harness/run.sh`, `harness/guest/` and `harness/lib/` — except `appfresh.sh`
and `snapshot.sh`, which carry an app-specific launch block — are byte
identical in both repositories. `harness/SHARED.sha256` is the checked-in
statement of that, and each repository's `make test` verifies its own copies
against it, so an edit that was not regenerated fails where it was made.

Regenerate it from the repository root, in both checkouts:

```bash
{ echo harness/run.sh
  find harness/guest -type f ! -name '.DS_Store'
  find harness/lib -type f ! -name appfresh.sh ! -name snapshot.sh ! -name '.DS_Store'
} | LC_ALL=C sort | xargs shasum -a 256 > harness/SHARED.sha256
```

That is `shasum -a 256` output — `<hash>␠␠<path>`, paths relative to the
repository root, sorted — so `shasum -a 256 -c harness/SHARED.sha256` from the
repository root is the quick manual check.

A manifest cannot see the other checkout: a file edited and regenerated in
both places, differently, satisfies both manifests and still drifts. That is
what `harness/sync-check.sh` compares, and why the release runbook runs it
with `--require`.

## What lives where

| path | what |
|---|---|
| `run.sh` | the orchestrator: start, wait, status, selfcheck, clean |
| `lib/common.sh` | refusals, logging, JSON escaping, run ids, bounded waits, the report file |
| `lib/vm.sh` | tart, and the indirectable guest shell |
| `lib/watchdog.sh` | the nesting watchdogs |
| `sync-check.sh` | the two checkouts compared |
| `SHARED.sha256` | what "shared" means, as hashes |
| `guest/` | the in-guest driver: install, click by identifier, answer dialogs, wait on the journal, capture screenshots |
| `scenarios/<app>/` | one file per scenario |
| `image/` | the golden image recipe (AgentMenu's repository only) |
| `findings.txt` | the finding codes a report may carry |

`__supervise <run-dir>` is internal: `start` forks it and nothing else calls
it.

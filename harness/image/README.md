# The first-run-golden image

`first-run-golden` is a Tart VM that a stranger's Mac would plausibly look
like: a vanilla macOS desktop, Gatekeeper on, one admin account, Claude Code
installed the way its official installer leaves it and never logged in,
Terminal.app as the only terminal (nothing else was ever installed). It
exists so the harness's stranger tier (other units under `harness/`) can
clone it per run, exercise a release the way a stranger would, and discard
the clone — see the plan this implements,
`docs/plans/2026-09-18-1115-feat-first-run-sandbox-harness-plan.md`, Unit U1
and KTD1.

This file is the whole recipe. A second person should be able to follow it
without asking questions. If something here turns out to be wrong once you
actually run it, fix this file in the same change that fixes the script —
a recipe that drifts from what it produces is worse than no recipe.

## Why this is a fork, not the stock Cirrus image

Cirrus Labs publishes a ready-made vanilla Tahoe image
(`ghcr.io/cirruslabs/macos-tahoe-vanilla`) that would otherwise save a lot of
this work. It doesn't work for this purpose: its build template
(`templates/vanilla-tahoe.pkr.hcl`) runs `sudo spctl --global-disable` during
Setup Assistant and asserts Gatekeeper stayed disabled at the end, because
the image targets CI runners that need to execute unsigned test binaries.
`spctl --global-enable` no longer works on Sequoia or Tahoe to undo this: on
the host this recipe was written against (macOS 26.6.2), `sudo spctl
--global-enable` prints "This operation is no longer supported. Please see
the man page for more information." (see the source comment in
`vanilla-tahoe.pkr.hcl` for the full citation) — once Gatekeeper is globally
disabled this way, nothing puts it back. A stranger tier built on that image
could never show a real Gatekeeper dialog, which is exactly one of the things
a stranger run needs to prove still works.

So `vanilla-tahoe.pkr.hcl` in this directory is a fork of Cirrus's template
with the Gatekeeper-disabling boot steps and the final "assert disabled"
check removed, and nothing else changed. `disable-sip.pkr.hcl` is Cirrus's
own SIP-disabling template, unmodified. Each file's own header comment says
exactly what was forked from where, at which commit, and what changed.

Cirrus's stock vanilla image already has SIP on and no TCC rows seeded; it
never touches either. Those aren't things the fork undoes: they're things
this recipe adds on top, in `disable-sip.pkr.hcl` and `provision.sh` below,
regardless of which template stage 1 clones from.

## Prerequisites

Apple Silicon Mac, host macOS 13 or later (this recipe was written against
macOS 26.6.2; see "When to rebuild" below).

```
brew install openai/tools/tart        # not cirruslabs/cli/tart -- that tap is stale
brew install hashicorp/tap/packer
```

`curl`, `shasum`, `jq`, `expect`, `ssh`, `scp`, `sqlite3`, `dscl`, `file`,
`route`, `ipconfig` and `tmutil` all ship with macOS; `build.sh` and
`verify.sh` check for everything on this list before doing anything and name
whichever one is missing.

The first build needs the host's login keychain unlocked (Tart hits a
keychain-backed API while creating a VM from an IPSW; a locked keychain makes
the first boot fail with `SecKeyCreateRandomKey_ios failed`, per Tart's own
FAQ). That creation happens in stage 0 now, not stage 1 -- if `build.sh`
fails there with something like that, unlock your keychain (log in normally,
don't just wake from sleep) and re-run.

Budget disk space generously: the IPSW download is tens of gigabytes, and a
successful build leaves three VMs on disk -- `first-run-base` (kept across
builds), the per-build VM it was cloned into, and `first-run-golden` (a clone
of that) -- because `tart clone` is copy-on-write, so this costs much less
than 3x on APFS, but it isn't free either. The IPSW itself is cached under
`~/.tart/harness-image-cache/` (or `$TART_HOME/harness-image-cache/` if
you've relocated Tart's home), and `first-run-base` there means most rebuilds
skip the download, the hashing, and the install entirely.

## Running it

```
harness/image/build.sh
```

Runs four stages in order against one working VM
(`first-run-golden-<build-id>`), clones the result to `first-run-golden`,
and finishes by running `verify.sh` against a throwaway clone of that.
Refuses if `first-run-golden` already exists — pass `--force` to replace it.

0. **Base install** (`first-run-base`). `tart create --from-ipsw`, done once
   and kept. Its sidecar JSON at
   `~/.tart/harness-image-cache/first-run-base.json` records the IPSW's
   SHA-256, the IPSW path, the Tart version, and when it was created, so
   later builds neither re-download nor re-hash it. `--base <vm>` skips this
   stage entirely; `--rebuild-base` forces a fresh one.
1. **Setup Assistant** (`vanilla-tahoe.pkr.hcl`). Clones the base (via
   `vm_base_name`) into `first-run-golden-<build-id>` and drives Setup
   Assistant screen by screen with the plugin's OCR waits and clicks (see
   "How Setup Assistant is driven" below).
2. **SIP off** (`disable-sip.pkr.hcl`). Recovery-mode `csrutil disable`.
3. **Provisioning** (`provision.sh`). TCC seeding, Automation Mode, locale,
   Software Update off, Claude Code install, writes
   `/etc/first-run-golden.json`.

Flags:

- `--force`: replace an existing `first-run-golden` once the new build
  succeeds; the per-build VM it was cloned from is never touched by this.
- `--ipsw <url-or-local-path>`: build `first-run-base` from this IPSW
  instead of the URL recorded in `vanilla-tahoe.pkr.hcl`'s `ipsw_path`
  variable.
- `--base <vm>`: clone stage 1 from this local VM instead of
  `first-run-base`, skipping stage 0 entirely. For iterating on the template
  only: no IPSW hash is recorded for the resulting image
  (`/etc/first-run-golden.json`'s `ipsw_sha256` reads `unrecorded`), so don't
  use it for the image you keep as `first-run-golden`.
- `--rebuild-base`: delete and re-create `first-run-base` from the IPSW.
- `--terms click|voiceover|manual`: how Terms and Conditions is passed; see
  "Terms and Conditions" below.
- `--skip-verify`: skip the automatic `verify.sh` pass at the end, if you'd
  rather run it yourself.

This is a long-running, interactive command — plan to watch it, not
background it blindly the first time. Expected durations:

| Step | What's happening | Roughly |
|---|---|---|
| Stage 0: base install | first build only: IPSW download, hashing, `tart create --from-ipsw` into `first-run-base` | 10-40 min download + 1-2 min hashing + 5-15 min install, once; instant on every later build |
| Stage 1: `vanilla-tahoe.pkr.hcl` | Setup Assistant, driven screen by screen by OCR waits and clicks, cloned from `first-run-base` | a few minutes; target under five |
| Stage 2: `disable-sip.pkr.hcl` | recovery boot, `csrutil disable`, halt | 3-5 min |
| Stage 3: `provision.sh` | TCC seeding, Automation Mode, locale, Software Update off, Claude Code install | 5-10 min |
| `verify.sh` | clone, boot, the checks it lists, discard the clone | 2-5 min |

### The IPSW

`vanilla-tahoe.pkr.hcl`'s `ipsw_path` variable defaults to:

```
https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-75212/A2A24B94-1FC1-45A3-93F7-C51B02AF1F4D/UniversalMac_26.6.2_25G83_Restore.ipsw
```

taken from Cirrus's own template at the commit this fork is pinned to (see
`vanilla-tahoe.pkr.hcl`'s header). Its SHA-256 is never hardcoded anywhere in
this recipe: `build.sh` downloads it once, in stage 0, hashes the bytes it
actually got with `shasum -a 256`, and writes the hash into
`first-run-base`'s sidecar JSON; every build that clones from `first-run-base`
then copies that hash into `/etc/first-run-golden.json` on the built image.
A build run with `--base <vm>` instead of `first-run-base` records
`ipsw_sha256` as `unrecorded` there, since no IPSW was involved in producing
that VM. If this exact URL ever 404s (Apple does rotate these),
get a current one for the same macOS version either from Cirrus's live
template (`https://github.com/cirruslabs/macos-image-templates/blob/main/templates/vanilla-tahoe.pkr.hcl`)
or from Apple's own IPSW catalogs, and pass it with `--ipsw`. Update the
default in `vanilla-tahoe.pkr.hcl` too if it's going to be the one you build
from going forward.

### How Setup Assistant is driven

Two primitives from `packer-plugin-tart` drive every screen, and neither
times out on its own. `<wait 'text'>` polls the guest's framebuffer, runs
Vision's text recognizer over it, and returns as soon as some observation's
top candidate matches `text` as a case-insensitive, unanchored regular
expression: whichever observation is found first is the one that counts.
`<click 'text'>` does the same wait, then clicks the centre of the *whole
matched observation*, not of the matched substring. The plugin logs
`Looking for '...'` while it waits and `Clicking at '...'s center (x, y)`
when it presses, so packer's log always names the screen a build is on, or
stuck on.

Three rules govern the `boot_command` in `vanilla-tahoe.pkr.hcl` (its own
header comment has the full version; the lint in
`Tests/AgentMenuKitTests/ImageRecipeTests.swift` enforces the ones it can
check mechanically):

1. Every screen is entered with `<wait 'label'>` on text unique to that
   screen (not present on the one before it), then left with `<click
   'label'>` or the keystroke a sheet needs. The click's own wait keeps the
   whole sequence event-driven, end to end.
2. A fixed `<waitNs>` longer than ten seconds is allowed only where a loader
   precedes a control that's already visible (so a click would otherwise
   land on a disabled button), and the comment line directly above it names
   the screen: `# loader: <screen>`.
3. A `<click>` whose label also appears elsewhere on the same screen is
   anchored (`^...$`) and carries `# repeats: <label>` on the line above.
   Neither a `<wait>` nor a `<click>` string can contain an apostrophe,
   because the plugin's parser stops at the first one. So "Don't Use" and
   its kind are matched with the regex dot in the apostrophe's place
   (`<click 'Don.t Use'>`).

### Terms and Conditions

Terms and Conditions has three drivers, selected with
`build.sh --terms click|voiceover|manual` (default `click`). Move to the next
one only when the current one actually fails. Don't pre-emptively skip to
manual:

- **click.** `<click '^Agree$'>` on the card, then the same anchored click
  on the confirmation sheet (Enter does nothing there, unlike on the Apple
  Account sheet; Vision lists the sheet's buttons before the card's, so the
  first exact match is the sheet's Agree). Works when Vision returns the
  Agree button as its own observation, separate from Disagree and from the
  licence text. Verified on the first real build on 2026-09-19: packer's log
  showed `Looking for '^Agree$'` then
  `Clicking at '^Agree$'s center (1656, 1296)`, the same coordinates as every
  other screen's primary button, and the confirmation sheet followed, so
  this mode works on macOS 26.6.2.
- **voiceover.** Upstream's own driver: VoiceOver on, Shift-Tab, Space, then
  Tab, Space on the sheet, VoiceOver off again after Welcome to Mac. Move to
  this mode if the packer log shows it looking for `^Agree$` forever: that
  means Vision merged the Agree and Disagree buttons, or the licence line,
  into one observation, so the anchored regex never matches anything on its
  own.
- **manual.** The one manual step R5 allows. packer waits for the Terms
  screen, then for whatever screen comes after it, while you click Agree,
  then Agree again in the confirmation sheet, in the packer window. Move to
  this mode if voiceover also fails. This only works because the packer
  window stays visible during the build (`vanilla-tahoe.pkr.hcl` must never
  set `headless = true`), and `build.sh` records that the click happened in
  `/etc/first-run-golden.json`'s `manual_steps` field.

### Remote Login

The template's last boot step turns SSH on from inside the guest, from a
Terminal window it opens itself via Spotlight, rather than through System
Settings: one line, `sudo launchctl load -w
/System/Library/LaunchDaemons/ssh.plist`, with the `admin` password piped to
`sudo` so nothing has to be recognized on screen. That form starts sshd on
macOS 26.6.2 (verified in the guest on 2026-09-19); `systemsetup
-setremotelogin on` does not, it wants Full Disk Access. The guest shell is
zsh, which does not word-split an unquoted variable, so the line is one
explicit command, not a loop. `provision.sh` takes over the moment SSH
answers. Screen Sharing is not enabled on this image: to look at a guest,
use `tart run <name>` (no `--no-graphics`), which opens a window directly;
`tart run <name> --vnc` needs Screen Sharing to be reachable and so isn't
available here. To look without a window, `tart run <name> --no-graphics
--vnc-experimental` prints a `vnc://` URL with a one-time password that any
VNC client can take a screenshot from (vncdotool's `capture` in a throwaway
virtualenv works; its `type` does not send shifted characters correctly, so
use it for looking and clicking, not for typing commands).

### The harness ssh key

The harness reaches a clone with `ssh -o BatchMode=yes` (`harness/lib/vm.sh`),
which never types a password, so the image has to carry a public key whose
private half the host holds. `build.sh` generates a dedicated,
passphrase-less key once, `~/.tart/harness-image-cache/harness_ed25519`
(under `$TART_HOME` if you relocated it), and passes its `.pub` to
`provision.sh`, which appends it to the guest's `authorized_keys` and then
proves a BatchMode login with the private key works before the image is
called done; `verify.sh` repeats that proof as its seventh check. `vm.sh`
offers the key by default whenever the file exists, so a fresh checkout on
the same host needs nothing more; a host with its own arrangement sets
`HARNESS_SSH_OPTS` and the default steps aside. The key opens only Tart
guests on this host's NAT, which is the same trust the `admin`/`admin`
password already grants; keep it out of backups with the rest of `~/.tart`.

### The stage cap

The plugin's OCR waits have no timeout of their own, so both packer stages
run under two bounds. `HARNESS_IMAGE_STALL_CAP` (default `300`, or `1800`
when `--terms manual` is used, since that mode waits on a person) is how
long packer may keep looking for the same label while the guest is still
producing screen updates: the guest is alive and the screen is not the one
expected. It is counted in five-second ticks during which packer's log grew,
so a host that falls asleep mid-build does not count its nap as a stall (the
first real build lost sixteen minutes that way, and `build.sh` now runs
packer under `caffeinate` as well). `HARNESS_IMAGE_STAGE_CAP` (default
`3600`) is the wall clock for the whole stage, sleep included, as the last
resort. On expiry, `build.sh` stops the guest itself (`tart stop`), which
makes packer's boot step fail rather than get cancelled; `packer build
-on-error=abort` then keeps the plugin's own cleanup (which deletes the VM
on a cancelled or halted build) from running. The reason and the last
`Looking for '...'` label are printed, and the per-build VM is left stopped
so you can look at the exact screen it stalled on: `tart run
first-run-golden-<build-id>` (no `--no-graphics`) boots it and opens a
window. Logs for the run live under
`~/.tart/harness-image-cache/logs/<build-id>/`: `stage1-packer.out` and
`.log`, `stage2-packer.out` and `.log`, `stage3-tart-run.log`.

### When a stage fails

- **Stage 0** rarely fails once the IPSW itself is good: if `tart create
  --from-ipsw` fails, nothing is left half-written (the sidecar JSON is only
  written after `tart create` succeeds), so there's nothing to clean up by
  hand. If `first-run-base` exists but its sidecar doesn't, `build.sh` refuses
  and tells you to pass `--rebuild-base` (or `--base first-run-base`, if
  you're fine with `ipsw_sha256` reading `unrecorded`).
- **Stage 1** is still the most likely thing to break, since Apple changes
  Setup Assistant's layout between releases, but because it's driven by OCR
  waits rather than fixed keystroke timing, most delays resolve themselves.
  A real failure means either a screen's label genuinely never appeared, the
  stage hit its wall-clock cap (see "The stage cap" above), or Terms and
  Conditions needs the next mode (see "Terms and Conditions" above). Either
  way, `build.sh` prints the last `Looking for '...'` label from packer's
  log, so you know which screen it was on before opening anything, and the
  build VM is always kept, never deleted, on failure. To diagnose: compare
  that label against `vanilla-tahoe.pkr.hcl`'s `boot_command` to find the
  matching `<wait 'label'>` or `<click 'label'>`, then watch it happen.
  `tart run first-run-golden-<build-id>` (no `--no-graphics`) opens a window
  on the stuck VM, so you can compare what's actually on screen against what
  that step expected. If what's on screen is a loader (a spinner, a disabled
  button) rather than the label itself, that step may need a
  `# loader: <screen>` annotation and a fixed wait instead of an
  event-driven one.
- **Stage 2** cannot fail loudly on its own: packer reports the Recovery
  session as successful whatever `csrutil` did, which is how upstream's
  sequence shipped for a year answering only two of `csrutil disable`'s
  three prompts (y/n, "Authorized user:", "Password:") and typing `halt`
  into the third. The template now answers all three and waits for each
  prompt's text; `provision.sh` refuses to go on unless `csrutil status` in
  the booted guest says disabled, and names stage 2 when it does not. The
  stage runs under the same caps and logs as stage 1
  (`stage2-packer.out` and `.log` next to stage 1's); to watch it,
  `tart run first-run-golden-<build-id> --recovery`.
- **Stage 3** (`provision.sh`) fails loudly and names which step it was on
  (TCC seeding, Automation Mode, locale, Software Update, the Claude Code
  install, or reading a value back). `tcc-seed.sh` specifically refuses
  rather than guessing if the guest's TCC database schema doesn't look like
  what it expects — see the next section if that happens. When stage 3 says
  ok but `verify.sh` then finds no Claude Code or no
  `/etc/first-run-golden.json` on the image, the guest was killed before it
  flushed its disk: `tart stop` only waits 30 seconds before terminating a
  VM, which is less than a logged-in macOS shutdown takes, and the first
  full build lost all of provisioning's writes that way. `build.sh`
  therefore shuts the guest down from inside (`sudo shutdown -h now` over
  the harness key) and waits for the VM process to exit; never replace that
  with a plain `tart stop`.
- Once you've fixed whatever it was, re-run `build.sh`. It computes a new
  `<build-id>` (a timestamp) each time, so it never collides with a build VM
  left over from a previous failed attempt; those are yours to `tart delete`
  once you're done inspecting them.

### If the driver's TCC grants don't take

This is a real, expected risk, not a hypothetical: `tcc-seed.sh` inserting
rows into `TCC.db` and `sqlite3` reporting success does not guarantee macOS
honors them. Tahoe revalidates grants, and the SSH-invoked process may end up
attributed differently than either identity `tcc-seed.sh` seeds for
(`/usr/libexec/sshd-keygen-wrapper` or `com.apple.sshd-session` — it seeds
both, since which one applies isn't something this script can determine
ahead of time). `verify.sh` catches this: it tests the grants functionally
(a real screenshot, a real System Events query), not by checking that the
insert didn't error.

This is a diagnostic, run on a throwaway clone, never on the golden image
itself: its only purpose is to tell a seeding bug in `tcc-seed.sh` apart from
a wrong client identity (macOS attributing the SSH-invoked process to
something other than what `tcc-seed.sh` assumed), by hand-granting once and
seeing whether that alone fixes it. Whatever it points to gets fixed in
`tcc-seed.sh`, not carried forward as a manual step. The golden image is
never hand-granted, and R5 doesn't allow a second manual step beyond the one
Terms and Conditions already spends.

If `verify.sh` reports the screenshot or System Events check failing, try
granting by hand through the GUI before re-investigating the schema:

0. `verify.sh` deletes its own throwaway clone when it's done (unless you
   passed `--keep`), so there is no `<clone-name>` left to work on by the
   time you read its failure. Get one first: either re-run
   `verify.sh --keep` (it will still report the failure, but now leaves the
   clone running/stopped for you), or make one yourself with
   `tart clone first-run-golden scratch`. The rest of these steps act on
   that clone, not on `first-run-golden` itself — never grant anything on
   the golden image directly, or every future clone inherits a grant that
   was never actually proven to survive `tcc-seed.sh`.
1. `tart run <clone-name>` (no `--no-graphics`) to get a window on the guest.
   This image doesn't enable Screen Sharing (see "Remote Login" above), so
   `--vnc` isn't an option here.
2. Log in as `admin` / `admin` if auto-login didn't already do it.
3. System Settings → Privacy & Security → Accessibility (and separately,
   Screen Recording). Click the **+** button, press Cmd+Shift+G in the file
   picker (both directories are hidden by default) and add `/usr/bin/osascript`,
   `/usr/bin/screencapture`, and `/usr/libexec/sshd-keygen-wrapper`. Enable
   the checkbox for each.
4. This mechanism only works for a real file on disk. It cannot grant
   `com.apple.sshd-session` (a synthetic identity, not a path) — if that
   turns out to be the one your OpenSSH build attributes SSH sessions to,
   this fallback won't reach it, and the actual fix is in
   `tcc-seed.sh`/`update-tcc-database.sh`-style seeding, not a manual grant.
5. Shut the guest down, then run `verify.sh --image <clone-name>`. This
   clones `<clone-name>` again into a new throwaway VM the same way it
   always does — but a Tart clone copies the whole disk, TCC.db included, so
   the grant you just made by hand carries forward into it. If the checks
   pass now, you've confirmed the grant mechanism works and the problem is
   specifically in how `tcc-seed.sh` seeds it; if they still fail, the
   problem is elsewhere (wrong client identity, wrong service name) before
   you go changing `tcc-seed.sh`.

If none of this works, the next step is Console.app inside the guest,
filtered to `tccd`, while re-running the failing check — it logs why it
denied a request.

## Security constraints

This image is a pre-authorized, SIP-off macOS with a published password
(`admin`/`admin`). That's the whole point (a stranger tier that stopped to
ask for credentials wouldn't be testing a stranger's experience), but it
means the image has to stay contained:

- **Networking is Tart's default NAT, always.** Nothing in this recipe ever
  passes `--net-bridged`, `--net-softnet`, `--net-host`, or any port
  forwarding, to any `tart run`. `verify.sh` checks this on every run: it
  confirms the guest's address is not on the same /24 as the host's own LAN
  interface (i.e. it came from Tart's internal NAT/DHCP, not from the
  network the host itself is on). Don't add bridging to make some other
  workflow more convenient; use a different VM for that.
- **Keep `~/.tart` out of backups.** `build.sh` runs
  `tmutil addexclusion -p ~/.tart` (or `$TART_HOME` if you've relocated it)
  after every successful build, so Time Machine skips it — this is
  idempotent and safe to run repeatedly. `tmutil` can't reach an arbitrary
  cloud-sync folder, so if your home directory (or `$TART_HOME`) lives
  inside Dropbox, iCloud Drive, or similar, move Tart's home out of it:
  `export TART_HOME=~/somewhere-not-synced/.tart` before running `build.sh`
  (Tart itself reads this same variable).
- **Never expose the guest beyond localhost.** Nothing here needs it to: the
  host drives it entirely over Tart's own NAT-internal IP.

## When to rebuild

Rebuild when the **host's macOS point version changes** — a new point
release can change Setup Assistant's exact screens (breaking stage 1's
`boot_command`), the TCC schema (`tcc-seed.sh` will refuse loudly rather
than seed the wrong shape if this happens), or dialog wording. There's no
automatic staleness check; this paragraph is the check. Compare
`/etc/first-run-golden.json`'s `macos_build` (read it with
`tart run --no-graphics <name> &` then `ssh admin@$(tart ip <name>) cat /etc/first-run-golden.json`,
or just check what build the IPSW you're building from reports) against
`sw_vers -buildVersion` on the host.

Also rebuild if you update `TEMPLATE_COMMIT` in `build.sh` (re-forking from
a newer upstream commit), or if `TART_VERSION_PIN` in `build.sh` is set and
you've deliberately moved to a different Tart version and want a build that
reflects it.

If the IPSW itself changes (a new point release, or the URL 404s and you
pass a different one with `--ipsw`), rebuild with `--rebuild-base` too: a
plain `build.sh` reuses the existing `first-run-base` regardless of what
`--ipsw` says, since stage 0 is skipped whenever a base with a valid sidecar
already exists.

## `/etc/first-run-golden.json`

Written by `provision.sh` at the end of stage 3, so every report that reads
it can show exactly what inputs produced the image it ran against:

| Field | What it is |
|---|---|
| `schema_version` | this file's own format version (currently `1`) |
| `image_name` | always `"first-run-golden"` |
| `build_id` | the timestamp-based id of the per-build VM this image was cloned from |
| `macos_product_version` | `sw_vers -productVersion` read from the guest after provisioning |
| `macos_build` | `sw_vers -buildVersion` read from the guest after provisioning |
| `ipsw_sha256` | SHA-256 of the exact IPSW bytes `build.sh` built from (computed, never hardcoded) |
| `tart_version` | `tart --version` on the host, at build time |
| `template_commit` | the cirruslabs/macos-image-templates commit this fork's `.pkr.hcl` files were taken from |
| `claude_code_version` | `claude --version`, read from the guest right after the installer ran |
| `build_date` | UTC timestamp, when stage 3 finished |
| `manual_steps` | a string naming the Terms and Conditions click when `--terms manual` was used, empty otherwise |

## Verifying an image

```
harness/image/verify.sh              # checks first-run-golden
harness/image/verify.sh --image X    # checks some other local VM
harness/image/verify.sh --keep       # leaves the throwaway clone around for debugging
```

Never touches the named image directly — it clones it into a throwaway VM,
boots that, runs the checks it lists over SSH, and deletes the clone (unless
`--keep`). Each check is functional: it does the real thing (a real
screenshot, a real query, a real `TCC.db` read) rather than trusting that an
earlier step reported success. See `verify.sh`'s own header for the full
list of what the the checks it lists are and why each one is checked the way it is.

`verify.sh` cannot exercise the one truly end-to-end proof that Gatekeeper
survived the fork: showing the actual "are you sure you want to open this?"
dialog for a quarantined, notarized app. That needs a real notarized build
to test with, which this unit doesn't have. Do it by hand periodically: copy
a notarized AgentMenu or MeetingHop `.zip` into a fresh clone the way a
download would arrive (quarantine attribute set), unzip it into Downloads,
move the `.app` to `/Applications`, open it, and confirm the dialog appears
before you click through it. If it doesn't appear, Gatekeeper didn't survive
the fork and something upstream changed — start by re-reading
`vanilla-tahoe.pkr.hcl`'s diff against the current upstream template.

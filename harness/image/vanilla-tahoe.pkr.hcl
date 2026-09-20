# Forked from cirruslabs/macos-image-templates at commit
# 106c086ffa78a0701dd3301646d9a9be71fe7baf (2026-08-28, "Update Tahoe images to
# Xcode 27 beta 6 (#374)"), path templates/vanilla-tahoe.pkr.hcl, fetched
# 2026-09-18. https://github.com/cirruslabs/macos-image-templates
#
# Unit U1 / KTD1: the stock template disables Gatekeeper globally
# (sudo spctl --global-disable) and asserts it stayed disabled, because it
# targets CI runners. spctl --global-enable cannot undo that on Sequoia and
# Tahoe (see harness/image/README.md), so a stranger-tier image built from the
# unmodified template can never show a real Gatekeeper prompt. This fork
# removes the two "Disable Gatekeeper" boot_command blocks and the final
# `spctl --status | grep -q 'assessments disabled'` assertion; Gatekeeper being
# on is asserted functionally by harness/image/verify.sh instead.
#
# ===== How Setup Assistant is driven, and why it is not upstream's way =====
#
# Eight builds of the first fork died inside Setup Assistant, the last three
# on Terms and Conditions. The reason is in packer-plugin-tart's source
# (v1.21.0, builder/tart/vnc.go and vnc.mm; the addendum dated 2026-09-19 in
# docs/plans/2026-09-18-first-run-sandbox-harness-research-notes.md has the
# reading):
#
#   <wait 'text'>   polls the guest's framebuffer until Vision's text
#                   recognizer returns an observation matching `text` as a
#                   case-insensitive, UNANCHORED regular expression. No timeout.
#   <click 'text'>  the same wait, then a click at the centre of the WHOLE
#                   matched observation (not of the matched substring). No
#                   timeout either. The plugin logs "Looking for '...'" while
#                   it waits and "Clicking at '...'s center (x, y)" when it
#                   presses, so packer's log always names the screen a build
#                   is stuck on.
#
# So <click 'Agree'> matched the licence line ('OPTION TO "AGREE" OR
# "DISAGREE"') or the Disagree button first and pressed static text; and every
# fixed <waitNs> in the old sequence was a guess about a screen the plugin can
# see for itself. Upstream never clicks on Terms: it turns VoiceOver on before
# the Apple Account screen and drives Terms with Shift-Tab and Space, which
# the first fork dropped while keeping the VoiceOver-off keystroke.
#
# Three rules govern the sequence below (the template lint in
# Tests/AgentMenuKitTests/ImageRecipeTests.swift enforces the ones it can):
#
#   1. Every screen is ENTERED with <wait 'label'> on text unique to that
#      screen and not present on the one before it, then a two-second settle
#      for the transition, then LEFT with <click 'label'> (or the keystroke a
#      sheet needs). The click itself waits for its label, so the sequence is
#      event-driven end to end.
#   2. A fixed <waitNs> above ten seconds is allowed only where a loader
#      precedes a control that is ALREADY VISIBLE (so the click would land on a
#      disabled button), and it carries the annotation `# loader: <screen>` on
#      the comment line directly above it.
#   3. A <click> whose word also occurs elsewhere on the same screen is
#      anchored, `^...$`, so only an observation that is exactly the label
#      matches; it carries `# repeats: <label>` on the line above. A wait or
#      click string can never contain an apostrophe: the plugin's parser stops
#      at the first one (`<click\s*'(.+?)'>`), so "Don't Use" and its kind are
#      matched with the regex dot in the apostrophe's place (<click 'Don.t
#      Use'>).
#
# Terms and Conditions has three drivers, selected by the `terms_mode`
# variable (harness/image/build.sh --terms <mode>; README.md says when to move
# to the next one):
#   click      <click '^Agree$'> on the card and again on the confirmation
#              sheet (Enter does nothing there). The default. Works when
#              Vision returns the Agree button as its own observation, which
#              it did on macOS 26.6.2 on 2026-09-19.
#   voiceover  upstream's driver: VoiceOver on, Shift-Tab, Space, then Tab,
#              Space on the sheet; VoiceOver off again after Welcome to Mac.
#   manual     packer waits for the Terms screen, then for the screen after
#              it, while the maintainer clicks Agree twice in the packer
#              window (the plugin's `headless` defaults to false, and this
#              file must never set it to true). R5 allows exactly this one
#              documented click; build.sh records it in
#              /etc/first-run-golden.json as `manual_steps`.
#
# The two things build.sh needs beyond upstream: vm_name and ipsw_path are
# variables (defaulting to the upstream literals), and vm_base_name lets the
# Setup Assistant stage clone an installed-but-unconfigured base VM instead of
# installing from the IPSW every time, so a retry costs seconds. Passwordless
# sudo, auto-login, the screensaver, sleep and the screen lock stay in the
# shell provisioner at the end exactly as upstream has them; the Safari launch
# and `safaridriver --enable` are gone, thirty seconds a stranger's Mac never
# spent.

packer {
  required_plugins {
    tart = {
      version = ">= 1.16.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "vm_name" {
  type    = string
  default = "tahoe-vanilla"
}

variable "ipsw_path" {
  type    = string
  default = "https://updates.cdn-apple.com/2026SummerFCS/fullrestores/140-75212/A2A24B94-1FC1-45A3-93F7-C51B02AF1F4D/UniversalMac_26.6.2_25G83_Restore.ipsw"
}

# When set, the VM is cloned from this local Tart VM (an installed macOS that
# has never booted past the start of Setup Assistant) instead of being
# installed from ipsw_path. build.sh creates and keeps such a base as
# first-run-base and passes it here.
variable "vm_base_name" {
  type    = string
  default = ""
}

variable "terms_mode" {
  type    = string
  default = "click"
  validation {
    condition     = contains(["click", "voiceover", "manual"], var.terms_mode)
    error_message = "The terms_mode variable must be click, voiceover or manual."
  }
}

locals {
  # The screens before Terms and Conditions, in the order macOS 26.6.2 shows
  # them with United States as the region. Every action here is the one the
  # first fork's builds already proved; only the waits changed.
  before_terms = [
    # The "hello" animation after first boot. A key press skips it; on the
    # language list a stray space is harmless (upstream sends one blind). A
    # base that was once booted past the animation shows the list directly,
    # hence the alternation.
    "<wait '(hello|English)'><wait2s><spacebar>",
    # Language. The list has English selected already, but typing "english"
    # jumps to "English (UK)", so this switches away and back. <esc> does not
    # clear the type-select buffer on this macOS, so the waits do: the buffer
    # clears itself after about a second.
    "<wait 'English'><wait2s>italiano<wait3s><esc><wait3s>english<wait3s><enter>",
    # Select Your Country or Region. The list has keyboard focus; typing
    # selects. The click on the title is upstream's way of making sure.
    "<wait 'Country or Region'><wait2s><click 'Select Your Country or Region'><wait2s>united states<wait3s><click 'Continue'>",
    # Transfer Your Data to This Mac. "Set up as new" is already selected;
    # clicking it is belt and braces.
    "<wait 'Transfer Your Data'><wait2s><click 'Set up as new'><wait2s><click 'Continue'>",
    # Written and Spoken Languages. Also carries Customize Settings, bottom
    # left.
    "<wait 'Written and Spoken'><wait2s><click 'Continue'>",
    # Accessibility. Four category cards, and the button is Not Now.
    "<wait 'Accessibility'><wait2s><click 'Not Now'>",
    # Data & Privacy. Carries a Learn More link beside the button.
    "<wait 'Data & Privacy'><wait2s><click 'Continue'>",
    # Create a Mac Account. The account name fills itself from the full name.
    "<wait 'Create a Mac Account'><wait2s><click 'Full Name'><wait2s>Managed via Tart<tab>admin<tab>admin<tab>admin<wait2s><click 'Continue'>",
    # Sign In to Your Apple Account. The skip is inside Other Sign-In Options,
    # then a sheet asks again. A click reaches a control on the card but not
    # one inside a sheet, so every sheet is answered with <enter> on its
    # default button. Skipping the Apple Account keeps macOS busy for a good
    # while afterwards; the next screen's wait covers it.
    "<wait 'Sign In to Your'><wait2s><click 'Other Sign-In Options'><wait2s><click 'Sign in Later in Settings'>",
    "<wait 'Are you sure'><wait2s><enter>",
  ]

  terms = {
    click = [
      # Terms and Conditions. "Agree" also occurs inside "Disagree" and in the
      # licence text, hence the anchors: only an observation that is exactly
      # the button's label matches.
      # repeats: Agree
      "<wait 'Terms and Conditions'><wait2s><click '^Agree$'>",
      # The sheet: "I have read and agree to the macOS Software License
      # Agreement". <enter> does nothing here (observed 2026-09-19: the sheet
      # stayed open), unlike the Apple Account sheet. Vision lists the
      # sheet's Disagree and Agree before the card's own pair, so the first
      # exact match is the sheet's button.
      # repeats: Agree
      "<wait 'I have read'><wait2s><click '^Agree$'>",
    ]
    voiceover = [
      # Upstream's driver. VoiceOver makes Tab reach buttons, which it does
      # not do before login otherwise; Shift-Tab lands on the last control,
      # which is Agree.
      "<wait 'Terms and Conditions'><wait2s><leftAltOn><f5><leftAltOff><wait5s><leftShiftOn><tab><leftShiftOff><spacebar>",
      "<wait 'I have read'><wait2s><tab><spacebar>",
    ]
    manual = [
      # The maintainer clicks Agree, then Agree in the sheet, in the packer
      # window. The next step waits for the screen after Terms, however long
      # that takes (build.sh raises the stage cap for this mode).
      "<wait 'Terms and Conditions'>",
    ]
  }

  # The screens after Terms and Conditions. The first fork never got here, so
  # the labels below come from its screen-by-screen walk, not from a build.
  after_terms = [
    # Age Range. Rows, no button: choosing one advances. The click waits for
    # the screen itself.
    "<click 'Adult'>",
    # Enable Location Services, then its confirmation. That sheet's button is
    # "Don't Use", whose apostrophe the click syntax cannot carry; the regex
    # dot stands in for it.
    "<wait 'Location Services'><wait2s><click 'Continue'>",
    "<wait 'Are you sure'><wait2s><click 'Don.t Use'>",
    # Select Your Time Zone
    "<wait 'Select Your Time Zone'><wait2s><click 'Continue'>",
    # Analytics
    "<wait 'Analytics'><wait2s><click 'Continue'>",
    # Screen Time
    "<wait 'Screen Time'><wait2s><click 'Set Up Later'>",
    # Siri
    "<wait 'Siri'><wait2s><click 'Continue'>",
    # Select a Siri Voice. Continue is visible but disabled until a voice
    # exists; Choose For Me fetches one, and the click would otherwise land on
    # the disabled button.
    # loader: Select a Siri Voice
    "<wait 'Siri Voice'><wait2s><click 'Choose For Me'><wait10s><click 'Continue'>",
    # Improve Siri & Dictation. Continue stays disabled until one of the two
    # radios is chosen; choosing is instant.
    "<wait 'Dictation'><wait2s><click 'Not Now'><wait2s><click 'Continue'>",
    # Your Mac is Ready for FileVault, then its confirmation sheet.
    "<wait 'FileVault'><wait2s><click 'Not Now'>",
    "<wait 'Are you sure'><wait2s><enter>",
    # Choose Your Look
    "<wait 'Choose Your Look'><wait2s><click 'Continue'>",
    # Update Mac Automatically. Downloading without installing keeps the
    # image from rewriting itself behind a run.
    "<wait 'Update Mac'><wait2s><click 'Only Download Automatically'>",
    # The last screen is an animated, hand-lettered "welcome" that Vision
    # reads a dozen different ways (observed 2026-09-19: welcon, walcome,
    # golcome...); the Get Started button is the only stable text on it, and
    # the click waits for it.
    "<click 'Get Started'>",
    # The desktop. The menu bar's Finder item is the first stable text; the
    # Dock and the first-login housekeeping need a moment more.
    "<wait 'Finder'><wait5s>",
    # Remote Login, from Terminal rather than through System Settings' tab
    # counts: Spotlight, Terminal, one launchctl line. `launchctl load -w`
    # starts sshd on macOS 26.6.2 (verified in the guest on 2026-09-19);
    # `systemsetup -setremotelogin` does not, it wants Full Disk Access. sudo
    # reads the password from stdin so no prompt has to be recognised on
    # screen. The guest shell is zsh, which does not word-split an unquoted
    # variable, so this is one explicit command and not a loop. The shell
    # provisioner below takes over the moment SSH answers.
    "<leftAltOn><spacebar><leftAltOff><wait2s>Terminal<wait5s><enter>",
    "<wait 'zsh'><wait2s>echo admin | sudo -S launchctl load -w /System/Library/LaunchDaemons/ssh.plist; exit<enter>",
  ]

  # What each Terms driver leaves to undo once the desktop is up. Only
  # VoiceOver needs anything: the same toggle turns it off again.
  epilogue = {
    click     = []
    voiceover = ["<wait5s><leftAltOn><f5><leftAltOff>"]
    manual    = []
  }
}

source "tart-cli" "tart" {
  from_ipsw    = var.vm_base_name == "" ? var.ipsw_path : null
  vm_base_name = var.vm_base_name == "" ? null : var.vm_base_name
  vm_name      = var.vm_name
  cpu_count    = 4
  memory_gb    = 8
  disk_size_gb = 50
  ssh_password = "admin"
  ssh_username = "admin"
  ssh_timeout  = "180s"
  # Keys land in the guest at this interval. Upstream's default (100ms) makes
  # the Remote Login one-liner take half a minute to type; 50ms is still slow
  # enough for the list type-select on the language and region screens.
  boot_key_interval = "50ms"

  boot_command = concat(
    local.before_terms,
    local.terms[var.terms_mode],
    local.after_terms,
    local.epilogue[var.terms_mode],
  )

  // A (hopefully) temporary workaround for Virtualization.Framework's
  // installation process not fully finishing in a timely manner
  create_grace_time = "30s"

  // Keep the recovery partition, otherwise it's not possible to "softwareupdate"
  recovery_partition = "keep"
}

build {
  sources = ["source.tart-cli.tart"]

  provisioner "shell" {
    inline = [
      // Enable passwordless sudo
      "echo admin | sudo -S sh -c \"mkdir -p /etc/sudoers.d/; echo 'admin ALL=(ALL) NOPASSWD: ALL' | EDITOR=tee visudo /etc/sudoers.d/admin-nopasswd\"",
      // Enable auto-login
      //
      // See https://github.com/xfreebird/kcpassword for details.
      "echo '00000000: 1ced 3f4a bcbc ba2c caca 4e82' | sudo xxd -r - /etc/kcpassword",
      "sudo defaults write /Library/Preferences/com.apple.loginwindow autoLoginUser admin",
      // Disable screensaver at login screen
      "sudo defaults write /Library/Preferences/com.apple.screensaver loginWindowIdleTime 0",
      // Disable screensaver for admin user
      "defaults -currentHost write com.apple.screensaver idleTime 0",
      // Prevent the VM from sleeping
      "sudo systemsetup -setsleep Off 2>/dev/null",
      // Disable screen lock
      //
      // Note that this only works if the user is logged-in,
      // i.e. not on login screen.
      "sysadminctl -screenLock off -password admin",
    ]
  }

}

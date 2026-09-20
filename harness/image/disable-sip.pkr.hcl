# Forked from cirruslabs/macos-image-templates at commit
# 106c086ffa78a0701dd3301646d9a9be71fe7baf (2026-08-28, "Update Tahoe images to
# Xcode 27 beta 6 (#374)"), path templates/disable-sip.pkr.hcl, fetched
# 2026-09-18. https://github.com/cirruslabs/macos-image-templates
#
# Unit U1 / KTD1, stage 2 of harness/image/build.sh: boots the VM that stage 1
# (vanilla-tahoe.pkr.hcl) produced into macOS Recovery, runs `csrutil disable`
# there, answers its prompts, and halts. SIP has to be off in the *running*
# image before harness/image/provision.sh can seed TCC.db (see README.md).
#
# Two things changed from upstream, both found on 2026-09-19 by watching the
# stage over VNC after it had "succeeded" and left SIP on:
#   - On macOS 26.6.2 `csrutil disable` asks three things in a row: the
#     y/n confirmation, "Authorized user:", and "Password:". Upstream answers
#     the first two and then types `halt` into the password prompt, so the
#     command fails quietly and the VM halts with SIP still enabled; packer
#     reports success because nothing checks. This file answers all three,
#     and harness/image/provision.sh refuses to go on unless `csrutil status`
#     in the booted guest says disabled.
#   - Every step waits for the text it needs on screen (`<wait 'text'>`, the
#     plugin's OCR wait; see vanilla-tahoe.pkr.hcl's header) instead of a
#     fixed number of seconds, so a slower or faster Recovery boot changes
#     nothing. The labels are the ones observed: the boot picker's "Options",
#     the Recovery app's "Utilities" menu, Terminal's "bash" title, and
#     csrutil's own prompts.
#
# SIP being off is what makes this a pre-authorized, security-reduced image;
# harness/image/README.md documents the mitigations (NAT-only networking, no
# port forwarding, no bridging, Tart image store excluded from backups) and
# harness/image/verify.sh checks the ones that are checkable from outside the
# guest.
packer {
  required_plugins {
    tart = {
      version = ">= 1.16.0"
      source  = "github.com/cirruslabs/tart"
    }
  }
}

variable "vm_name" {
  type = string
}

source "tart-cli" "tart" {
  vm_name      = "${var.vm_name}"
  recovery     = true
  cpu_count    = 4
  memory_gb    = 8
  disk_size_gb = 50
  communicator = "none"
  boot_command = [
    # The boot picker: "Macintosh HD" and "Options". Skip over the disk and
    # select Options to boot into macOS Recovery.
    "<wait 'Options'><wait2s><right><right><enter>",
    # The Recovery app is up once its menu bar shows Utilities. Terminal is
    # Shift-Cmd-T on that menu.
    "<wait 'Utilities'><wait2s><leftAltOn>T<leftAltOff>",
    # Terminal's title reads "Terminal - -bash - 120x30".
    "<wait 'bash'><wait2s>csrutil disable<enter>",
    # "Allow booting unsigned operating systems ... [y/n]:"
    "<wait 'y/n'><wait1s>y<enter>",
    # "Authorized user:"
    "<wait 'Authorized user'><wait1s>admin<enter>",
    # "Password        :"
    "<wait 'Password'><wait1s>admin<enter>",
    # "System Integrity Protection is off. Restart the machine for the changes
    # to take effect."
    "<wait 'Protection is off'><wait2s>halt<enter>",
  ]
}

build {
  sources = ["source.tart-cli.tart"]
}

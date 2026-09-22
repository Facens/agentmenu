# Security

AgentMenu is built and maintained by one person, Andrea Giannangelo, alongside
a day job. There is no security team, no on-call rotation, and no SLA — a
report gets read as soon as it's seen, and a fix ships when one is ready.
That's a description of the process, not a promise about how fast it'll go.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting: this repository's **Security**
tab, then **Report a vulnerability**. That opens an advisory only the
maintainer can see. Prefer it over a public issue for anything that isn't
already being exploited — a public issue notifies everyone watching the
repository at the same moment it notifies the one person who can fix it,
which is the wrong order for something unpatched.

## Supported versions

Only the latest release gets fixes. There is no backport branch and no
long-term-support line — a security fix ships as a new version, not a patch
to an old one.

`v0.1.0` cannot update itself. Every release after it carries a Sparkle-based
updater checking a signed feed, so a copy that has one finds and installs a
fixed release on its own. Whether yours does is checkable, not a guess: open
Settings and look for a **Check for Updates** control. If it isn't there, the
remedy is the same as installing it the first time — download the new version
from the Releases page and replace the app.

## What's verified, not just claimed

Every release is signed with a Developer ID Application certificate and
notarized by Apple before it's attached to a release. The release workflow
checks `spctl -a -vvv -t exec` reports `source=Notarized Developer ID` on the
exact bundle that ships, not a separately built one.

The update feed at `https://facens.github.io/agentmenu/appcast.xml` is signed
on top of that, with an EdDSA key that exists only for AgentMenu and is never
committed to this repository. This is tested behaviour, not an assumption: in
a release rehearsal, an item in the feed carrying no signature was ignored by
an installed copy, and a real signature made with the wrong project's key was
rejected too — neither moved the installed version forward. AgentMenu and
MeetingHop each have their own key, so a compromise of one can't be used
against the other.

## Platform

Apple Silicon, macOS 14 or later. There is no Intel build.

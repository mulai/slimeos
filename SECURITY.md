# Security policy

## Reporting a vulnerability

Please report security problems **privately**, not in a public issue:

1. **GitHub (preferred):** open the [Security tab](https://github.com/mulai/slimeos/security)
   and choose **Report a vulnerability**. Only the maintainers see the report.
2. **No GitHub account:** use the [contact form](https://www.slimeos.com/contact) with
   "Security" in the subject. Leave out exploit details there; we'll reply with a private
   channel for them.

Please include what is affected (Membrane, an app, the hub, a Brain, slimeos.com or Slime ID),
the version, steps to reproduce, and what an attacker could do with it.

## What happens next

- We aim to acknowledge a report within a week.
- We fix it, ship the fix (Membranes update over the air), and then publish: the GitHub issue
  or advisory, the changelog entry, and a post on [slimeos.com/news](https://www.slimeos.com/news/category/security).
- We credit you by name or handle, unless you'd rather stay anonymous.

Please give us a reasonable chance to ship a fix before disclosing publicly, and don't access
other people's data or devices while testing.

## What's in scope

- The Membrane (`membrane/`), its installer and its update channel
- The hub and Brain services (`brain/`)
- The Slime OS apps for Windows, Mac, Android and iOS (`desktop/`, `android/`, `ios/`)
- slimeos.com and Slime ID

## Not a vulnerability

- **Remote Support gives the support team root on the device.** That is by design: it is off by
  default, turned on by the person at the device, and switches itself off at every restart. A way
  to turn it on without them, or to keep it on across a restart, *is* a vulnerability.
- Bugs in upstream projects (FreeRDP, WireGuard, Debian packages): please report those upstream.
  If one affects Slime OS, tell us too so we can patch or update.

## Supported versions

Only the latest release of each part gets security fixes: the current Membrane version
(see `membrane/update/manifest.json`), and the current version of each app in its store or on
the [download page](https://www.slimeos.com/download).

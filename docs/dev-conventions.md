# Development conventions

For anyone (human or Claude session) changing this repo. This repo is public,
so nothing here or anywhere in it may hold IPs, passwords, keys or account IDs.

## Commits
- Commit without GPG signing (`git commit --no-gpg-sign`).
- Message style: `fix: …`, `feat: …`, `docs: …`; the body says why.
- Flag a commit or push that feels risky instead of silently going ahead.

## Over-the-air updates (OTA)
Membranes update themselves from `membrane/update/manifest.json` on `main`.
- Any change to a file listed in the manifest ships in the same commit as:
  `SLIMEOS_VERSION` in `membrane/installer/install.sh`, and in the manifest
  the `version`, a new `changelog` entry on top, and fresh `sha256` values.
- A new file on devices needs a manifest entry and a line in
  `membrane/update/dest-map.txt` (destinations are under `/opt/slimeos`).
- Files in `/etc` are not OTA-delivered. Change them from an OTA-delivered
  script that already runs as root (see `remote-support-toggle.sh`'s
  firewall migration) and keep `install.sh` in step for fresh installs.
- Changelog entries are for users: what was wrong or what is new, in plain
  words, with the GitHub issue if there is one.
- GitHub's raw CDN serves a push after about 5 minutes; `?cb=` doesn't help.

## Product rules
- Recovery PIN is shown once at first install. No reveal in Settings, no
  PIN prompt on update, no reminders.
- Remote Support gives root on purpose and must never survive a reboot.
- Website copy: say "Coming Soon" or hide a feature; never "not built yet".
- Restart what you changed: the kiosk UI (`lockscreen/index.html`) needs
  the session restarted; `coordinator.sh` and the scripts it sources need
  `slimeos-bridge` restarted.

## Testing
Hardware, Brain and hub testing happens on the maintainer's machines. A
change that can't be tested without them should end in a PR saying what
still needs checking on a real device.

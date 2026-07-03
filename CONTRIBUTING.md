# Contributing to Slime OS

Thanks for your interest in Slime OS. PRs are welcome.

## Before you start

Read [`docs/architecture.md`](docs/architecture.md) to understand the system
design (Membrane / Brain split) before proposing changes.

## Where to contribute

- **Membrane** (local client: installer, hardware profiles, session/FreeRDP
  scripts) → label PRs and issues `membrane`
- **Brain** (cloud infra: Docker Compose stack, Authelia, WireGuard, xRDP) →
  label `brain`
- **Android** (Phase 2 client) → label `android`

## Adding hardware support

New device support is a single new file in
[`membrane/hardware-profiles/`](membrane/hardware-profiles/), following
[`001-gigabyte-h97.sh`](membrane/hardware-profiles/001-gigabyte-h97.sh) as a
template. No other changes should be needed.

## Pull requests

- Keep PRs scoped to one concern (one hardware profile, one infra fix, etc.)
- Explain the "why" in the PR description, not just the "what"
- Reference any related issue

## License

Slime OS is licensed under the [Apache License 2.0](LICENSE). By submitting
a contribution, you agree that it is licensed under the same terms (Apache
License 2.0, Section 5) and that you have the right to submit it under
that license.

## Reporting issues

Open a GitHub issue with steps to reproduce, expected vs. actual behavior,
and which layer it affects (Membrane, Brain, or Android).

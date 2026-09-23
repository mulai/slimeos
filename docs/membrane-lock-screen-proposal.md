# Proposal: Membrane lock screen (unlock by QR with Slime ID)

Status: **approved 2026-09-23**. Phase 1 built: server live, Membrane side in v0.3.24.

## Problem

Anyone standing at a Membrane can use it. Specifically, they can:

- open the Brain picker and connect to your Brain. For paid Brains the Windows credentials
  are delivered automatically, so this means full access to your desktop.
- open Settings and read the Remote Support password while Remote Support is on (the
  details now persist on screen from v0.3.21).
- change Wi-Fi, pairing, audio or other settings, or sign the device out.

A lock screen puts all of this behind proof that the person is the device's owner.

## What already exists (reuse, don't rebuild)

"Sign in with Slime ID" on the Membrane already uses a QR device-code flow (RFC 8628 style):

| Piece | Where |
|---|---|
| Device requests a code + QR | `POST /api/device/start` (slimeos.com) |
| Human approves on phone, logged in | `/device` page → `POST /api/device/approve` |
| Device polls until approved, gets a 30-day `kiosk` session | `POST /api/device/poll` |
| Membrane side of the flow (QR screen, polling, Back/power still work) | `membrane/session/slime-id.sh` `do_slime_id_login()` |
| Session token on the device | `/etc/slimeos/slime-id-session` (mode 600) |
| Revoke a device remotely | slimeos.com dashboard → Devices (`sessions-revoke`) |

So the lock screen is **a new use of an existing flow**, not new auth.

## Proposed design

### Signed in vs unlocked

- **Signed in** (exists today): the device holds a 30-day Slime ID session. Nothing changes
  here.
- **Unlocked** (new): a short-lived, local-only state meaning "the owner proved presence
  recently". Held in `coordinator.sh`'s memory only, so a reboot or coordinator restart
  always comes back **locked**.

The lock screen is **opt-in**, from a new Settings › Security tab, and **only available while
signed in to Slime ID**. Devices on the open-source path (no account, local Brains only)
behave exactly as today.

### Unlock flow

1. The lock screen shows a QR code and a short code, the same visual as today's sign-in
   screen but titled "Unlock <device name>".
2. The owner scans it, and the phone opens `/device?code=…` → "Unlock this Membrane?" →
   Approve.
3. The Membrane sees the approval and unlocks.

### Alternative unlock: recovery PIN (offline, no phone)

Next to the QR code, the lock screen offers "Use recovery PIN instead". It's the same 8-digit
PIN shown once after installation, and it works with no network and no phone.

- **Show-once stays show-once** (decision from 2026-09-06 unchanged): there's still no reveal,
  reset or reminder in the UI. A lost PIN means QR unlock only, or a reinstall.
- **Checked by the system, not against a stored copy:** the entered PIN is verified as the
  `slime-recovery` account's password (the same check the console login uses). The
  Membrane never keeps its own copy of the PIN.
- **Rate-limited:** 5 wrong tries → 1 min wait, doubling each time up to 1 hr. The counter
  is saved on disk so a reboot doesn't reset it. (It's 8 digits, i.e. 100 million
  combinations, so the lockout makes guessing impractical.)
- **Never logged:** the PIN goes from the entry field to the check and nowhere else. It's
  excluded from `coordinator.log` and crash reports, and the field is masked.
- **Trade-off:** this PIN is also the device's admin (sudo) credential, so typing it where
  others can watch exposes more than just unlocking. That's acceptable for v1, because
  someone who can watch the screen already has physical access, which is out of scope (see
  "Honest limits"). A separate unlock-only PIN is the alternative if you want to keep the
  two apart.
- **Revoked Slime ID:** when `unlock-start` answers `signed_out`, the Membrane clears its
  session file and the lock screen switches to PIN only. A new sign-in can never unlock the
  device, since that would let any Slime ID holder unlock it. Paid-Brain credentials are
  fetched fresh for each session and never cached, so a revoked device has nothing else to
  purge.
- **Deliberate sign-out** (the Sign out button) also turns the lock off, so an owner who
  signs out isn't left PIN-only.

**Prerequisite fix — DONE in v0.3.22 (2026-09-23):** the installer leaves the
PIN in plain text at `/etc/slimeos/recovery-pin`, owned by the `slime` kiosk account, and
nothing deletes it after the one-time display. Remote Support logs in as `slime`, so anyone
with a Remote Support login can read it and get admin (sudo) through `slime-recovery`. Fix:
delete (shred) the file once the one-time display is acknowledged. An OTA step should also
remove it on existing devices where `recovery-pin-shown` is no longer `unset`.

**The key difference from sign-in:** an unlock code must only be approvable by the account
the device is signed in to. Otherwise anyone with any Slime ID could unlock anyone's
Membrane.

### Server changes (slimeos.com)

- **Migration 0011:** add `purpose TEXT DEFAULT 'signin'` and `bound_user_id TEXT` to
  `device_codes`.
- **`POST /api/device/unlock-start {session_token}`:** resolves the token's user, creates a
  code with `purpose='unlock'` and `bound_user_id=<that user>`, returns the same shape as
  `start`.
- **`approve.ts`:** for `purpose='unlock'`, only succeed when the logged-in user equals
  `bound_user_id`. Give the same generic "invalid or expired" error otherwise (don't leak
  why).
- **`poll.ts`:** for `purpose='unlock'`, return `approved` **without minting a new session**
  (the device already has one); still claim the row atomically with `DELETE … RETURNING`.
- **`/device` page:** word it "Unlock" rather than "Sign in" when the code is an unlock
  code, and show the device's label so the owner knows which device they're approving.
  `device/start` and `unlock-start` accept a label; the Membrane sends its hostname. Every
  Membrane is currently named `slimeos`, so a user-given device name is a follow-up.

### Membrane changes

- **`coordinator.sh`:** a `LOCKED` flag; when set, every screen except the lock screen,
  Wi-Fi setup and power is refused and redirected to the lock screen.
- **New `lock.sh`:** `do_unlock()`, largely `do_slime_id_login()` with `unlock-start` and no
  token write.
- **Lock screen UI** in `lockscreen/index.html`: reuse the `slimeIdEntry` QR render; it
  needs "Wi-Fi settings" and power buttons.
- **Settings › Security tab:** a lock on/off toggle plus the auto-lock choice.

## Lock and unlock rules

| Event | Behavior |
|---|---|
| Boot / coordinator restart | Locked |
| Brain session ends (logoff, disconnect, error) | Locked |
| Idle on the Membrane UI for N min (default 5) | Locked (Phase 2) |
| "Lock now" button (picker screen) | Locked |
| Inside a Brain session | Not our job: Windows has its own lock (Win+L, idle) |
| Slime ID session revoked/expired | Stays locked; PIN unlock only (see above) |

**Always reachable while locked:** Wi-Fi setup (otherwise a device with broken Wi-Fi can
never be unlocked), shutdown/restart, and the lock screen itself.

## Decisions (all made 2026-09-23 by Tommy)

1. **No-internet / no-phone fallback:** the recovery PIN unlocks the device. The code and
   URL are shown next to the QR, so any browser can approve.
2. **Recovery PIN vs a separate unlock PIN:** reuse the recovery PIN in v1. Revisit if typing
   the admin credential at the device turns out to be a real concern.
3. **Who can unlock:** only the Slime ID the device is signed in to. Org-admin unlock comes
   later.
4. **Default:** off (opt-in from Settings › Security) in v1. On by default for new sign-ins
   once proven on real devices.
5. **Idle timeout (Phase 2):** 5 min default; choices 1 / 5 / 15 / 30 min / never. "Never"
   still locks at boot and when a Brain session ends.

## Honest limits (say this on the website too)

- It stops **casual access** by someone at the device. It does not stop someone with
  physical access and time: booting a USB stick, or pulling the disk (the token file and
  saved Brain credentials are on it).
- QR unlock depends on slimeos.com being up; the recovery PIN covers that case.

## Rollout

- **Before Phase 1:** the recovery-PIN plaintext-file fix, shipped as v0.3.22.
- **Phase 1:** recovery-PIN unlock with rate limit; migration, `unlock-start`, the approve/poll changes and the `/device`
  wording; a real device label; Membrane lock state, lock screen, Security tab, and the
  boot / session-end / manual triggers. Verified on the AMD box. OTA release + a slimeos.com deploy, with the
  server deployed first so older Membranes are unaffected.
- **Phase 2:** idle timer, org-admin unlock, and a "tap to approve" notification on the
  phone instead of scanning (needs a push channel we don't have yet).

**Effort guess:** the PIN-file fix is under one session; Phase 1 is roughly 3 working sessions, including real-device
verification.

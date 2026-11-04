# Store listing: Microsoft Store

What to enter in Partner Center for the Slime OS desktop app on Windows
(MSIX, `desktop/app/package-msix.ps1`). Update it with the app:
certification compares these answers with what the app does. iOS:
`app-store-listing.md`; Android: `store-listing.md`.

## Shared facts

| | |
|---|---|
| Name | Slime OS (reserved in Partner Center) |
| Package identity | `Mulai.SlimeOS`, publisher `CN=9D7FADFA-197A-4401-948B-1567CD4BD625`, display name Mulai (repository variables `MSIX_*`) |
| Package | `Slime-OS.msix` from the `windows-msix` artifact of the release tag's CI run (unsigned: the Store signs it) |
| Version | the app's version + `.0` (0.2.0 → 0.2.0.0; the Store keeps the fourth part) |
| Devices | Windows 10 version 1809 or later and Windows 11, x64, desktop only |
| Category | Productivity (subcategory none) |
| Price | Free, no in-app purchases, no ads |
| Availability | Tommy's call. iOS leaves out France (Apple's export-compliance question: no ANSSI declaration) and China mainland (VPN licence); neither reason is Microsoft's, but the ANSSI declaration is French law, not a store rule |
| Privacy policy URL | https://www.slimeos.com/privacy |
| Support | https://www.slimeos.com/contact |
| Website | https://www.slimeos.com |
| Copyright | © 2026 Mulai Pte. Ltd. |

## Listing text

**Short description** (shows on Windows 10 tiles and in search):

> Your Brain's desktop in a window on this PC: a Windows computer in the cloud that does the heavy lifting.

**Description** (10,000 max):

> Slime OS opens your Brain on this PC: a Windows computer in the cloud
> that does the heavy lifting, in a window or full screen.
>
> Sign in with your Slime ID, pair this PC once with a code from your
> dashboard, and pick your Brain. Your apps, files and open windows stay on
> the Brain, so you can pick up where you left off, on this PC or on any
> other Slime OS device.
>
> WHAT YOU GET
> • Your Brain's desktop, full screen or in a window that keeps its size
> • Smooth video and sound from your Brain
> • A sleeping Brain wakes up when you connect
> • A private, encrypted connection between this PC and your Brain
>
> WHAT YOU NEED
> • A Slime ID with a Brain (slimeos.com)
> • A good internet connection
>
> PRIVATE CONNECTION
> Slime OS reaches your Brain over its own encrypted WireGuard connection
> that lives inside the app: no driver, no VPN adapter, and nothing else
> on this PC goes through it.
>
> OPEN SOURCE
> Slime OS is open source under the Apache 2.0 licence:
> github.com/mulai/slimeos

Keep claims to what ships on Windows ("Coming Soon or hide"). Not claimed
on purpose: the camera (doesn't reach the Brain from a Windows 10 PC, not
yet tested on Windows 11), the microphone and the clipboard (both on in the
session, not tested on Windows yet).
Add them when they're tested. No prices or plans in the listing.

**Features** (up to 20, short): full-screen Brain desktop · smooth video
and sound · wakes a sleeping Brain · encrypted connection, no driver or
VPN adapter.

**Search terms** (up to 7): remote desktop, cloud pc, windows, virtual
desktop, rdp, cloud computer, remote access.

## Screenshots

Desktop, 1366×768 or larger (1920×1080 is the usual), 1 to 10; the first
shows in search. From BRCTA3T (or any PC): the Brain list, a session full
screen with a clean Windows desktop, a video playing. Nothing personal on
screen. Store logos are optional (the package's own logos show otherwise);
if wanted, scale `desktop/app/src-tauri/icons/icon.png` (512×512).

## Age rating (IARC questionnaire)

Same answers as the other stores: no violence, sexual content, bad
language, drugs, gambling or user-to-user chat. **Unrestricted internet
access: Yes** (a Brain is a full Windows PC with a web browser), which sets
the rating.

## Properties and declarations

- **Restricted capability `runFullTrust`**, the justification Partner
  Center asks for:

> Slime OS is a desktop (Win32) app packaged as MSIX. It needs full trust
> to run its two helper programs: the connection core, which keeps an
> encrypted WireGuard connection inside the app's own process (no driver,
> no VPN adapter, no system network changes), and the remote-desktop
> window, which hosts Windows' own Remote Desktop control (mstscax.dll) to
> show the user's cloud computer. It doesn't install drivers or services,
> change system settings or run anything at sign-in.

- **Camera and microphone** (declared device capabilities): the Remote
  Desktop control shares them with the user's own Brain during a session,
  and Windows asks the user first. Nothing is recorded or kept.
- **Data collection** (privacy policy needed: yes): email address and
  Slime ID account for sign-in, and this PC's tunnel key from pairing.
  Screen, sound and input travel only between the PC and the user's Brain
  and aren't collected.

## Notes for certification

A tester needs a Slime ID with a Brain and this PC paired to it; the app
has no demo mode. Before submitting, decide what to give them: a test Slime
ID (email + password) with a Brain they may use, and a pairing code that is
still valid when they test, or a short video of a real session instead.

> Slime OS connects to the user's own cloud computer ("Brain"). Sign in
> with the Slime ID below; when the app asks to pair this PC, enter the
> pairing code below. Then choose the Brain and its Windows desktop opens.
> Slime ID: <email> / <password>. Pairing code: <code>.
> A video of a real session: <link>.

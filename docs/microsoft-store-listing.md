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
| Store ID | `9MTCL44GP30H` (PFN `Mulai.SlimeOS_06egmm8qhh2e6`); link once live: https://apps.microsoft.com/detail/9MTCL44GP30H |

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

**What's new in this version** (1500 max; Windows changes only, user words):

> First release on the Microsoft Store. Your Brain opens full screen in Windows' own Remote Desktop, with no extra sign-in box or security warnings, and the Store keeps Slime OS up to date.

(0.2.0, 2026-11-04.)

**Features** (up to 20, short): full-screen Brain desktop · smooth video
and sound · wakes a sleeping Brain · encrypted connection, no driver or
VPN adapter.

**Search terms** (up to 7): remote desktop, cloud pc, windows, virtual
desktop, rdp, cloud computer, remote access. Partner Center calls them
Keywords (40 characters each, 21 words in all: these are 12).

**Supplemental fields**: short title and voice title empty (Xbox only;
"Slime OS" is short already). Short description: the one above.
Copyright and trademark info: the Copyright line. Additional license
terms: empty (standard terms). Developed by: Mulai.

## Screenshots

Desktop, 1366×768 or larger (1920×1080 is the usual), 1 to 10; the first
shows in search. From BRCTA3T (or any PC): the Brain list, a session full
screen with a clean Windows desktop, a video playing. Nothing personal on
screen. Store logos are optional (the package's own logos show otherwise);
if wanted, scale `desktop/app/src-tauri/icons/icon.png` (512×512).

Made 11-04 in `~/Downloads/Slime OS Store Assets/microsoft-store/`:
store logos 300/150/71 (from the app icons) and 16:9 super hero art
1920×1080 + 3840×2160 (no title text, as required; `app-store/make_header.py
3840x2160 <out> screenshots/02-windows-desktop.png <slime-mark-color-1024.png>`).
Hero art is optional unless a trailer should play at the top.

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

## Publishing hold

First submission: "Don't publish this submission until I select Publish
now", so slimeos.com/download gets the Store link the same day.

## Notes for certification

A tester needs a Slime ID with a Brain and this PC paired to it; the app
has no demo mode. Before submitting, decide what to give them: a test Slime
ID (email + password) with a Brain they may use, and a pairing code that is
still valid when they test, or a short video of a real session instead.

> Slime OS connects to the user's own cloud computer ("Brain"). Test
> account (Slime ID): <email> / <password>.
> 1. Open Slime OS and sign in with the Slime ID above. "Test Brain" is listed.
> 2. Click it. The app asks for a pairing code for this PC.
> 3. In a browser, sign in at https://www.slimeos.com/login with the same
>    Slime ID, click "Get pairing code" next to Test Brain, and type the
>    code into the app (only the code is needed; it lasts 15 minutes, and a
>    new one can be made every 5 minutes).
> 4. The Brain's Windows desktop opens. If it was asleep, waking it takes
>    about a minute.

Reviewer account (11-04): Slime ID `msstore-review@mulai.com`, Brain row
"Test Brain" on the Azure Brain (`10.10.0.28`), Windows standard user
`storereview` (not admin; your `slimeadmin` profile stays private). Win11
Pro allows one session at a time: stay off the Brain while certification
runs. After certification: revoke the Brain row, disable `storereview`,
remove its hub peer.

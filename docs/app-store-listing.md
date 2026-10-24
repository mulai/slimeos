# Store listing: Apple App Store

What to enter in App Store Connect for the Slime OS iOS app
(`com.slimeos.app`, iPhone and iPad). Update it with the app: App Review
compares these answers with what the app does. Android: `store-listing.md`.

## Shared facts

| | |
|---|---|
| Name | Slime OS |
| Bundle ID / SKU | `com.slimeos.app` / `slimeos-ios` |
| Developer | Mulai Pte. Ltd. |
| Category | Productivity (secondary: Utilities) |
| Price | Free, no in-app purchases, no ads |
| Version | 1.0.0 (build number from `ios/Config/Base.xcconfig`) |
| Devices | iPhone (landscape) and iPad (any orientation), iOS 17+ |
| Availability | All countries except France (export compliance, below) and China mainland (VPN apps need a government licence there, as on AppGallery) |
| Release | Manual, after the Via LA AVC licence (OpenH264 is in the app) |
| Privacy policy URL | https://www.slimeos.com/privacy |
| Support URL | https://www.slimeos.com/contact |
| Marketing URL | https://www.slimeos.com |
| Copyright | 2026 Mulai Pte. Ltd. |

## Listing text

**Subtitle** (30 max):

> Your cloud computer, anywhere

**Promotional text** (170 max, can change without a review):

> Try the Demo Brain in seconds, no account needed. Then connect to your own Brain: a Windows computer in the cloud that does the heavy lifting.

**Keywords** (100 max, commas, no spaces needed):

> remote desktop,cloud pc,windows,virtual desktop,rdp,cloud computer,remote access,workspace,vdi

**Description** (4000 max):

> Slime OS turns your iPhone or iPad into a window to your Brain: a Windows
> computer in the cloud that does the heavy lifting.
>
> Sign in with your Slime ID, pick your Brain, and its desktop fills the
> screen. Your apps, files and open windows stay on the Brain, so you can pick
> up where you left off, on this device or on a Slime OS computer.
>
> WHAT YOU GET
> • Your Windows desktop, full screen, with touch and keyboard
> • Smooth video and sound from your Brain
> • A sleeping Brain wakes up when you connect
> • A dropped connection doesn't end your session: Slime OS reconnects and
>   everything is still open
> • A private, encrypted connection between this device and your Brain
> • An app PIN, so someone else picking up this device can't use your Brains
> • A Demo Brain, to try Slime OS before you add your own
>
> WHAT YOU NEED
> • A Slime ID with a Brain
> • A good internet connection; Wi-Fi works best
>
> ABOUT THE VPN
> Slime OS adds a VPN configuration for one thing: a private, encrypted
> WireGuard connection between this device and your Brain. Only Slime OS's own
> connection to your Brain goes through it. Your web browsing and other apps
> are not routed through it, read or changed. It's only on while you use
> Slime OS.
>
> OPEN SOURCE
> Slime OS is open source under the Apache 2.0 licence:
> github.com/mulai/slimeos

Keep claims to what ships on iOS ("Coming Soon or hide"). Not claimed on
purpose: camera and microphone (Android only so far). No prices, plans or
"buy at slimeos.com" anywhere in the app or the listing (App Review 3.1.1).

## Screenshots

- iPhone 6.5" (1242×2688 or 2688×1242): from the iPhone 11 Pro Max,
  landscape: Brain list, a session with a clean Windows desktop, a video
  playing, the Demo Brain. Nothing personal on screen.
- iPad 13" (2064×2752 or 2752×2064): from the iPad Pro 13-inch (M5)
  simulator, Debug build with `-preview welcome|picker|demo` (ios/README.md).
- 3 to 10 each; the first three show in search results.

## App Privacy (privacy "nutrition label")

Data collected, all **linked to the user, not used for tracking**, purpose
**App Functionality**:

| Category | Type | Why |
|---|---|---|
| Contact Info | Email Address | Slime ID sign-in |
| Identifiers | User ID | Slime ID account |
| Identifiers | Device ID | the device's tunnel key from pairing |

Screen, sound, touches and keys only travel between the device and the
user's Brain and aren't collected by us. Keep it in step with
`ios/SlimeOS/PrivacyInfo.xcprivacy`. If the Demo Brain page loads Google
Analytics, add Usage Data › Product Interaction (Analytics, not linked).

## Age rating

Same answers as Android's questionnaire: no violence, sexual content, bad
language, drugs, gambling, contests or user-to-user chat. **Unrestricted web
access: Yes** (a Brain is a full Windows PC with a web browser), which sets
the rating.

## App Review information

- **Sign-in required**: No (the Demo Brain needs none). Leave the demo
  account empty.
- **Contact**: name, phone and email of whoever answers App Review.
- **Notes**:

> No sign-in is needed to try Slime OS: after choosing an app PIN, tap the
> Demo Brain card ("Try it") on the welcome screen. It opens our demo
> desktop. Connecting to a real Brain needs a Slime ID with a Brain and a
> device paired with that Brain from its dashboard, which a review device
> can't do on its own. This video shows a real session on an iPhone: <link>.
>
> About the VPN: Slime OS is a remote-desktop client. It adds one VPN
> configuration (NEPacketTunnelProvider, WireGuard) from the device to our
> relay, which reaches the user's own cloud computer. Only the app's own
> connection to the user's Brain uses it (it routes two private address
> ranges); other traffic isn't routed, read or collected. It's on only while
> the app is in use. The pairing screen explains this before iOS asks.

(Record the video with the iPhone's screen recording; nothing personal on
screen.)

## Export compliance

The app uses encryption: WireGuard (ChaCha20-Poly1305, Curve25519, BLAKE2s)
in the tunnel and TLS (OpenSSL) for the remote desktop, all standard
algorithms, in addition to Apple's own.

Decided 2026-10-25 (Mulai Pte. Ltd.): "Standard encryption algorithms
instead of, or in addition to, Apple's", **not available in France**, so no
documentation. `ITSAppUsesNonExemptEncryption = false` in `ios/project.yml`
keeps later builds from asking. France needs the ANSSI encryption
declaration first, uploaded as App Encryption Documentation; Apple then
gives a key for Info.plist instead.

# Store listing: Google Play and Huawei AppGallery

What to enter in Play Console and AppGallery Connect for the Slime OS Android
app (`com.slimeos.app`). Update it with the app: store review compares these
answers with what the app does.

## Shared facts

| | |
|---|---|
| App name | Slime OS |
| Package | `com.slimeos.app` |
| Developer | Mulai Pte. Ltd. |
| Category | Productivity (Play), Efficiency or Tools (AppGallery) |
| Price | Free, no in-app purchases, no ads |
| Privacy policy | https://www.slimeos.com/privacy |
| Account deletion | https://www.slimeos.com/delete-account |
| Website | https://www.slimeos.com |
| Support email (public) | hi@slimeos.com |
| Privacy contact | privacy@slimeos.com |
| Devices | arm64 Android 10 (API 29) and later, landscape; phones and tablets |
| Upload | Play: `android/app/build/outputs/bundle/release/app-release.aab`; AppGallery: `.../apk/release/app-release.apk` |
| Signing | One key for both stores (kept outside the repo). Play App Signing: "use my own key"; AppGallery: sign it yourself or upload the same key |

Before the first production release: the Via LA AVC licence must be signed
(OpenH264 is in the APK).

## Listing text

**Short description** (Play, 80 max; AppGallery "brief introduction"):

> Your cloud computer on your phone or tablet: full Windows, video, camera, mic.

**Full description** (Play 4000 max; AppGallery introduction):

> Slime OS turns your phone or tablet into a window to your Brain: a Windows computer in
> the cloud that does the heavy lifting.
>
> Sign in with your Slime ID, pick your Brain, and its desktop fills the screen.
> Your apps, files and open windows stay on the Brain, so you can pick up where
> you left off, on this device or on a Slime OS computer.
>
> WHAT YOU GET
> • Your Windows desktop, full screen, with touch and keyboard
> • Smooth video and sound from your Brain
> • Your device's camera and microphone in apps on your Brain, such as video
>   calls, only after you allow them
> • A dropped connection doesn't end your session: Slime OS reconnects and
>   everything is still open
> • A private, encrypted connection between this device and your Brain
> • An optional app PIN for shared devices
> • A Demo Brain, to try Slime OS before you add your own
>
> WHAT YOU NEED
> • A Slime ID with a Brain. Learn more at slimeos.com.
> • A good internet connection; Wi-Fi works best.
>
> ABOUT THE VPN
> Slime OS uses Android's VPN service for one thing: a private, encrypted
> WireGuard connection between this device and your Brain. Only Slime OS's
> own connection to your Brain goes through it. Your web browsing and other
> apps are not routed through it, read or changed. It's only on while you use
> Slime OS.
>
> OPEN SOURCE
> Slime OS is open source under the Apache 2.0 licence:
> github.com/mulai/slimeos

Keep claims to what ships ("Coming Soon or hide"). Not claimed on purpose:
waking a sleeping Brain from the tablet (untested), iOS.

## Graphics

- Icon 512×512 and feature graphic 1024×500: the brand kit's
  `Android/play-store/` folder.
- Screenshots, landscape, from the MatePad (1920×1200, within Play's 2:1 and
  320–3840 px limits): welcome screen with the Demo Brain, Brain list, a
  session showing a clean Windows desktop, a video playing, Settings. Use a
  desktop with nothing personal on it. Play needs at least 2; give 4–8 for
  7-inch and 10-inch tablets. Phone: portrait 1080×1920 frames (headline + the
  landscape app in a sideways phone), made with `make_frames.py` in the store
  assets folder from Mate 30 Pro screenshots.

## Play Console: App content

**Privacy policy**: https://www.slimeos.com/privacy

**App access**: "All or some functionality is restricted." Instructions:

> No sign-in is needed to try Slime OS: on the welcome screen, tap the
> Demo Brain card ("Try it"). It opens our demo desktop. Connecting to a real
> Brain needs a paid Slime ID plan and a device paired with that Brain from
> its dashboard, which a reviewer device can't do on its own. This video shows
> a real session, including the camera and microphone: <video link>.

(Record the video with `adb shell screenrecord`; nothing personal on screen.)

**Ads**: No.

**Content rating** (IARC questionnaire): category "All other app types". No
violence, sexual content, bad language, drugs, gambling or user-to-user
interaction; no location sharing; no digital purchases. "Unrestricted
internet access": Yes (a Brain is a full Windows PC with a web browser).
Expect a general-audience rating with an "Unrestricted internet" note.

**Target audience**: 13 and over (13–15, 16–17, 18+). Not designed for
children; answer No to "appeals to children".

**News app**: No. **Government app**: No. **Financial features**: None.
**Health**: None.

**Data safety**

Collected: Yes. Shared: Yes (the reports below become public GitHub issues).
Encrypted in transit: Yes. Users can ask for deletion: Yes,
https://www.slimeos.com/delete-account. Independent security review: No.

| Data type | Collected | Shared | Optional | Ephemeral | Purpose |
|---|---|---|---|---|---|
| Personal info › Email address | Yes | No | No (needed to sign in) | No | Account management, App functionality |
| Personal info › User IDs (Slime ID) | Yes | No | No | No | Account management, App functionality |
| Device or other IDs (tunnel key from pairing) | Yes | No | No | No | App functionality |
| Audio › Voice or sound recordings (microphone) | Yes | No | Yes | Yes | App functionality |
| Photos and videos › Videos (camera) | Yes | No | Yes | Yes | App functionality |
| App info and performance › Crash logs | Yes | Yes | Yes | No | Analytics |
| App info and performance › Diagnostics | Yes | Yes | Yes | No | Analytics |
| App activity › Other user-generated content (feedback) | Yes | Yes | Yes | No | Analytics, Developer communications |
| Location › Approximate location (country, with feedback) | Yes | Yes | Yes | No | Analytics |

Camera and microphone only go to the user's own Brain over the encrypted
connection; nothing is recorded or stored, hence "processed ephemerally".
Screen, sound, touches and keys likewise only travel between the device and
the user's Brain and aren't collected by us.

**Sensitive permissions › VpnService** declaration. Use case: network tools
(remote access to the user's own cloud computer). Text:

> Slime OS is a remote-desktop client. Its core function is connecting the
> user's device to the user's own cloud computer (a "Brain"), which only works
> through our relay. VpnService creates one WireGuard tunnel from the device
> to that relay. Only the Slime OS app itself can use the tunnel; no other
> app's traffic enters it. It routes only two private address ranges used by
> Slime OS (10.10.0.0/24 and 10.11.0.0/24), which carry the connection to the
> user's Brain; the device's internet traffic is not routed through it. We
> don't collect, inspect, redirect or monetise traffic through the tunnel, and
> show no ads. All tunnel traffic is encrypted (WireGuard), and Remote Desktop
> traffic inside it is encrypted again (TLS). The tunnel starts when the user
> opens Slime OS on a paired device and closes when they stop using it: a
> minute after they leave the app (unless a remote-desktop session is still
> running), or at once when they close it. The user can also end it at any
> time in Android's VPN settings, or by removing the pairing in Slime OS.

**Countries**: all where Mulai can trade; pricing Free.

## AppGallery Connect

- **App information**: name, brief intro and introduction as above;
  category Efficiency (or Tools); privacy statement URL as above.
- **Distribution**: all countries and regions **except the Chinese mainland**
  (VPN apps and ICP/software-copyright rules make it a separate project).
- **Age rating**: AppGallery's questionnaire, same answers as IARC above.
- **Review notes** (the "Comments to reviewer" box): the App access
  paragraph and the VPN paragraph above.
- **Data security / privacy labels**: same answers as Play's Data safety.
- **Package**: the release APK (or AAB), signed with the same key as Play.

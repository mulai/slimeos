# FreeRDP UDP transport (RDP-UDP2) and opt-in VAAPI decode

`slimeos-udp-transport.patch` adds RDP's UDP transport to FreeRDP 3.15
(deb13u3). Upstream FreeRDP has none: it only parses the server's
Initiate Multitransport Request and always declines it. Maintainers
confirmed this in FreeRDP#10669 and #4978.

`slimeos-drdynvc-lock.patch` fixes a race the UDP transport opened in
drdynvc: its receive thread delivers PDUs while the main thread delivers
TCP data, and both used the shared `drdynvc->data_in` with no lock. That
corrupted the DVC stream pool (SIGSEGV in `StreamPool_Take`, first caught
on the Android build on 2026-10-04). A lock around the receive function
makes the threads take turns; the data path itself is unchanged. The
first attempt, `+slimeos12` (a separate stream for each whole PDU, as on
Android at the time), made video lag in bursts on the AMD box (16% of
packets resent, RTT up to 900 ms, against under 1% and ~40 ms on
`+slimeos11`), so it was dropped.

`slimeos-vaapi-decode-optin.patch` makes the build's VAAPI hardware H.264
decode run only when `SLIMEOS_VAAPI_DECODE=1`. connect.sh sets it for
hardware profiles that opt in (today only 010, the NUC6CAxx, with
`LIBVA_DRIVER_NAME=i965`, because Intel's iHD driver segfaults there:
FreeRDP#8276).

**Status (2026-09-25):** in daily use on the AMD box over Wi-Fi. Shipped
as `+slimeos7` (v0.3.27), `+slimeos8` (v0.3.28, adds opt-in VAAPI),
`+slimeos9` (v0.3.29, fixes a crash on disconnect), then `+slimeos11`
(v0.3.38, adds the send path below; `+slimeos10` was an unreleased trial
build), then `+slimeos13` (v0.3.52, the drdynvc race fix), together with
the camera and keyboard patches. Users switch it
on per device in Settings > Display & Sound > Brain connection >
"Faster (beta)", on by default since v0.3.36.

**Android:** `android/freerdp-patches/udp-transport.patch` is this patch
ported to FreeRDP 3.31.1 (identical code, minus the research fps counter in
rdpgfx_main.c), and `android/freerdp-patches/drdynvc-lock.patch` is
the drdynvc fix. Change both sides together.

## What it does

- When `SLIMEOS_UDP_NATIVE=1` (set by `connect.sh` from `RDP_UDP="on"` in
  display-prefs) and Windows offers reliable UDP, FreeRDP runs the
  MS-RDPEUDP v3 handshake, then TLS 1.2 and an MS-RDPEMT tunnel, and
  answers the request with S_OK. Windows then creates the latency-sensitive
  dynamic channels on the tunnel: graphics, cursor, video and audio
  playback.
- **Receive path:** tunnel data is handed to drdynvc exactly as if it came
  over TCP. Loss handling: ACK vectors, reorder by ChannelSeqNum (which
  wraps 65535 → 1, skipping 0), and AckOfAcks.
- **Send path** (`SLIMEOS_UDP_SEND=1`, alongside `SLIMEOS_UDP_NATIVE=1`):
  DVC replies for channels Windows created on the tunnel (graphics/audio
  acks, channel open/close) go back over it too, instead of TCP. Reliable:
  each packet is queued and retransmitted (RFC 6298-style RTO, min 30 ms;
  fast retransmit once 3 newer packets are ACKed) until Windows
  acknowledges it. A plain ACK is cumulative: it credits every packet up
  to its DataSeqNum, the same way Windows treats our plain ACKs, and so
  also covers Windows' delayed ACKs (most of its ACKs during video carry
  1 or more). `+slimeos10` credited only the exact packet and resent more
  packets than it sent. An ACK vector credits everything below its base
  plus each bitmap bit; run-length elements aren't decoded yet (a few are
  logged raw), so nothing is ever assumed received by mistake. Gives up
  and falls back to TCP if one packet stays unACKed for 10 s.
  Keyboard/mouse input still goes over TCP either way — Windows' UDP
  input channel (`Microsoft::Windows::RDS::CoreInput`) is undocumented.
- **Mid-session fallback.** After 1 s of silence the client sends keepalive
  dummy packets, which Windows ACKs. If nothing at all arrives for 3 s, it
  `shutdown()`s the session's TCP socket, and FreeRDP's auto-reconnect
  resumes the same Windows session. UDP stays declined (E_ABORT) for
  5 minutes, so that reconnect is TCP-only. On the build VM, the session
  was back at 32 fps about 8 s after UDP was blocked.
- **Clean shutdown.** `rdp_client_disconnect()` first stops and joins the
  receive thread (`multitransport_client_stop_udp()`), so it can never
  deliver into channels that are being torn down. Before `+slimeos9` it
  could, and the NUC segfaulted (exit 139) on every disconnect.
- If the handshake fails, the client answers E_ABORT and the session runs
  on plain TCP, exactly like stock FreeRDP.

Tuning (environment, all optional): `SLIMEOS_UDP_DEAD_MS` (3000),
`SLIMEOS_UDP_PROBE_MS` (1000), `SLIMEOS_UDP_PAUSE_MS` (300000),
`SLIMEOS_UDP_TX_GIVEUP_MS` (10000, send path), `SLIMEOS_UDP_VERBOSE`
(1/2, packet logging). Log lines are tagged `SLIMEOS-UDP-NATIVE` under
`com.freerdp.core.multitransport`. connect.sh lets them into
`connect.log` at INFO.

## Measured

- Build VM with netem loss both ways, scrolling console, fps average/min
  (TCP vs UDP): 3% loss 30.7/22.6 vs 35.8/34.9; 8% loss 24.4/15.0 vs
  43.2/38.0.
- 30-minute soak at 3% loss: steady ~32 fps, flat memory, 145 MB over UDP.
- AMD box on real Wi-Fi, full-screen YouTube video: TCP 18–28 fps with
  skipped frames, UDP 34–47 fps. A/V sync was "spot on" on 2026-09-24.
- Send path against the real Azure Brain (build VM, simulated upstream
  loss via `SLIMEOS_UDP_TX_DROP`): 0/5/15% loss all held a steady ~32 fps
  scrolling console with every packet eventually ACKed (43/92/240
  retransmits, 0 stuck); 15% again with cumulative ACKs: 17% retransmits,
  0 stuck, steady 32 fps.
- Send path on the AMD box over real Wi-Fi, YouTube video: "as if I am in
  a local PC" (Tommy). `+slimeos11`: 221 retransmits of 6,202 packets,
  all within one ~40 s stretch, 0 on connect, flat during steady video.
  `+slimeos10` had resent 16,775 for 13,705 sent.

## Known limits

- No Soft-Sync, so channels can't move between transports live. The
  fallback reconnects instead.
- Input (keyboard/mouse) isn't on the send path yet — Windows' UDP input
  channel (`Microsoft::Windows::RDS::CoreInput`) is undocumented and needs
  decoding from a Windows client capture first.
- Research-only paths are still compiled in, inert unless their variables
  are set: `SLIMEOS_UDP_HELPER`, `SLIMEOS_UDP_PROBE`, `SLIMEOS_UDP_ACCEPT`,
  `SLIMEOS_UDP_TX_DROP`. Remove them before upstreaming.
- The UDP-side TLS doesn't verify the server certificate. This matches the
  TCP side (`/cert:ignore`). Both run inside WireGuard.
- If UDP is blackholed *silently* while TCP keeps working (only
  reproducible with an iptables DROP), Windows keeps retransmitting into
  the dead tunnel, and TCP graphics sag until it gives up or ICMP gets
  through. Inside WireGuard that can't happen for real: UDP and TCP fail
  together, and our closed socket triggers ICMP port-unreachable.

## Rebuild recipe

Build machine: GCP `slimeos-freerdp-build` (e2-standard-4, Debian 13,
asia-southeast1-b, OS Login), provisioned by `../build-vm-startup.sh`. It
powers itself off after an idle hour: start it with
`gcloud compute instances start slimeos-freerdp-build --zone=asia-southeast1-b`.
The patched tree is in `~/membrane-build/`. A clean build takes about 3.5 minutes
and reproduces the shipped +slimeos9 debs bit for bit.

1. Get the **exact** deb13u3 source from the `.dsc`
   (`dget`/`dpkg-source -x freerdp3_3.15.0+dfsg-2.1+deb13u3.dsc`). On the
   build VM, `apt-get source freerdp3` picks up the 3.31 backport instead.
2. Add the camera and keyboard patches (see those READMEs), then
   `slimeos-udp-transport.patch`, `slimeos-vaapi-decode-optin.patch` and
   `slimeos-drdynvc-lock.patch`, to `debian/patches/series`, in that
   order. `debian/rules` also needs
   `-DRDPECAM_INPUT_FORMAT_H264=OFF` (camera README) and
   `-DWITH_VAAPI=ON` (it ships OFF). Add `libva-dev` to Build-Depends.
   The runtime dependencies don't change, which matters because the OTA
   installs with plain `dpkg -i`.
3. Add a `debian/changelog` entry that bumps the suffix (`+slimeos14`...).
   Always bump, even for a build that only went to a test device: the OTA
   sync skips a device whose installed version string already matches.
   Write it by hand; `dch` hangs when run non-interactively.
4. `DEB_BUILD_OPTIONS="parallel=4 nocheck noddebs" dpkg-buildpackage -b -us -uc`
   (install the tree's own build deps first:
   `sudo mk-build-deps -i -r debian/control`).
5. Copy `freerdp3-x11`, `libfreerdp-client3-3`, `libfreerdp3-3` and
   `libwinpr3-3` to `membrane/hardware-profiles/freerdp/<package>.deb`.
   Update the sums in `install.sh` section 1b, and let the release's
   manifest.json checksum pass pick them up.

Devices pick up a new build through the normal OTA path: detect.sh's
FreeRDP sync step installs it as root during the update. Research notes
and the test harness (`fallbacktest.sh`, `losstest.sh`) are in the
development notes, not the repo.

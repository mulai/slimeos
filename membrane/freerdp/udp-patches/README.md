# FreeRDP UDP transport (RDP-UDP2) and opt-in VAAPI decode

`slimeos-udp-transport.patch` adds RDP's UDP transport to FreeRDP 3.15
(deb13u3). Upstream FreeRDP has none: it only parses the server's
Initiate Multitransport Request and always declines it. Maintainers
confirmed this in FreeRDP#10669 and #4978.

`slimeos-vaapi-decode-optin.patch` makes the build's VAAPI hardware H.264
decode run only when `SLIMEOS_VAAPI_DECODE=1`. connect.sh sets it for
hardware profiles that opt in (today only 010, the NUC6CAxx, with
`LIBVA_DRIVER_NAME=i965`, because Intel's iHD driver segfaults there:
FreeRDP#8276).

**Status (2026-09-24):** in daily use on the AMD box over Wi-Fi. Shipped
as `+slimeos7` (v0.3.27), then `+slimeos8` (v0.3.28, adds opt-in VAAPI),
together with the camera and keyboard patches. Users
switch it on per device in Settings > Display & Sound > Brain connection
> "Faster (beta)". It is off by default.

## What it does

- When `SLIMEOS_UDP_NATIVE=1` (set by `connect.sh` from `RDP_UDP="on"` in
  display-prefs) and Windows offers reliable UDP, FreeRDP runs the
  MS-RDPEUDP v3 handshake, then TLS 1.2 and an MS-RDPEMT tunnel, and
  answers the request with S_OK. Windows then creates the latency-sensitive
  dynamic channels on the tunnel: graphics, cursor, video and audio
  playback.
- **Only the receive path goes over UDP.** Tunnel data is handed to drdynvc
  exactly as if it came over TCP. Channel replies and keyboard/mouse input
  still go over TCP, which Windows accepts.
- Loss handling: ACK vectors, reorder by ChannelSeqNum (which wraps
  65535 → 1, skipping 0), and AckOfAcks.
- **Mid-session fallback.** After 1 s of silence the client sends keepalive
  dummy packets, which Windows ACKs. If nothing at all arrives for 3 s, it
  `shutdown()`s the session's TCP socket, and FreeRDP's auto-reconnect
  resumes the same Windows session. UDP stays declined (E_ABORT) for
  5 minutes, so that reconnect is TCP-only. On the build VM, the session
  was back at 32 fps about 8 s after UDP was blocked.
- If the handshake fails, the client answers E_ABORT and the session runs
  on plain TCP, exactly like stock FreeRDP.

Tuning (environment, all optional): `SLIMEOS_UDP_DEAD_MS` (3000),
`SLIMEOS_UDP_PROBE_MS` (1000), `SLIMEOS_UDP_PAUSE_MS` (300000),
`SLIMEOS_UDP_VERBOSE` (1/2, packet logging). Log lines are tagged
`SLIMEOS-UDP-NATIVE` under `com.freerdp.core.multitransport`. connect.sh
lets them into `connect.log` at INFO.

## Measured

- Build VM with netem loss both ways, scrolling console, fps average/min
  (TCP vs UDP): 3% loss 30.7/22.6 vs 35.8/34.9; 8% loss 24.4/15.0 vs
  43.2/38.0.
- 30-minute soak at 3% loss: steady ~32 fps, flat memory, 145 MB over UDP.
- AMD box on real Wi-Fi, full-screen YouTube video: TCP 18–28 fps with
  skipped frames, UDP 34–47 fps. A/V sync was "spot on" on 2026-09-24.

## Known limits

- No Soft-Sync, so channels can't move between transports live. The
  fallback reconnects instead.
- Research-only paths are still compiled in, inert unless their variables
  are set: `SLIMEOS_UDP_HELPER`, `SLIMEOS_UDP_PROBE`, `SLIMEOS_UDP_ACCEPT`.
  Remove them before upstreaming.
- The UDP-side TLS doesn't verify the server certificate. This matches the
  TCP side (`/cert:ignore`). Both run inside WireGuard.
- If UDP is blackholed *silently* while TCP keeps working (only
  reproducible with an iptables DROP), Windows keeps retransmitting into
  the dead tunnel, and TCP graphics sag until it gives up or ICMP gets
  through. Inside WireGuard that can't happen for real: UDP and TCP fail
  together, and our closed socket triggers ICMP port-unreachable.

## Rebuild recipe

1. Get the **exact** deb13u3 source from the `.dsc`
   (`dget`/`dpkg-source -x freerdp3_3.15.0+dfsg-2.1+deb13u3.dsc`). On the
   build VM, `apt-get source freerdp3` picks up the 3.31 backport instead.
2. Add the camera and keyboard patches (see those READMEs), then
   `slimeos-udp-transport.patch` and `slimeos-vaapi-decode-optin.patch`, to
   `debian/patches/series`, in that order. `debian/rules` also needs
   `-DRDPECAM_INPUT_FORMAT_H264=OFF` (camera README) and
   `-DWITH_VAAPI=ON` (it ships OFF). Add `libva-dev` to Build-Depends.
   The runtime dependencies don't change, which matters because the OTA
   installs with plain `dpkg -i`.
3. Add a `debian/changelog` entry that bumps the suffix (`+slimeos9`...).
   Write it by hand; `dch` hangs when run non-interactively.
4. `DEB_BUILD_OPTIONS="parallel=8 nocheck noddebs" dpkg-buildpackage -b -us -uc`
   takes about 1–2 minutes on 8 cores.
5. Copy `freerdp3-x11`, `libfreerdp-client3-3`, `libfreerdp3-3` and
   `libwinpr3-3` to `membrane/hardware-profiles/freerdp/<package>.deb`.
   Update the sums in `install.sh` section 1b, and let the release's
   manifest.json checksum pass pick them up.

Devices pick up a new build through the normal OTA path: detect.sh's
FreeRDP sync step installs it as root during the update. Research notes
and the test harness (`fallbacktest.sh`, `losstest.sh`) are in the
development notes, not the repo.

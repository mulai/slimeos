# FreeRDP camera (rdpecam) patches

Webcam redirection into a Brain uses FreeRDP's MS-RDPECAM channel
(`/dvc:rdpecam`, on by default when a `/dev/video*` device exists;
`SLIMEOS_ENABLE_CAMERA=0` in `/etc/slimeos/config` opts out).

**Status as of 2026-07-17: WORKING end-to-end** — Logitech C920 on the
GA-78LMT-S2P dev box → Azure Windows 11 Brain, live picture in the
Camera app. Requires the patched `+slimeos5` FreeRDP rebuild that
`install.sh` section 1b installs (checksum-pinned, amd64 only). Frames
are MJPG-decoded and H264-re-encoded in software on the Membrane, so
expect CPU load and some lag on weak hardware while an app captures.

## Why a rebuild at all: Debian ships FreeRDP without the camera channel
Debian trixie's `freerdp3` **archive** binaries contain no rdpecam code
even though `debian/rules` enables `CHANNEL_RDPECAM_CLIENT` and the
build-dep `libv4l-dev` is present — the compiled plugin never lands in
any binary package (a Debian packaging bug worth filing). Our rebuild
compiles from the exact `deb13u3` source, where the channel builds fine.

⚠ The Debian source diverges heavily from the upstream 3.15.0 tag in
rdpecam — it carries the pendingSample refactor and several CVE
backports as quilt patches. Audit the *patched* source
(`apt-get source freerdp3` + `quilt push -a`), never the GitHub tag;
this mistake cost real time once already.

## The three camera bugs fixed in `+slimeos5`, in discovery order

1. **Sample response buffer overflow on large raw frames** —
   `slimeos-rdpecam-sample-buffer-grow.patch` (in this dir).
   `ecam_dev_send_sample_response` wrote a whole frame into the fixed
   ~4 MB `sampleRespBuffer` without a capacity check; a 1080p YUY2 frame
   (~4.15 MB) overflowed it and `Stream_SealLength` aborted the entire
   client — any Membrane with such a camera crash-looped every
   connection. Fixed with `Stream_EnsureRemainingCapacity`.

2. **Native-H264 cameras negotiate a passthrough Windows never renders**
   — build-flag fix, no source patch: the rebuild sets
   `-DRDPECAM_INPUT_FORMAT_H264=OFF` in `debian/rules`. FreeRDP's format
   preference table tries the camera's native H264 stream first and the
   V4L layer stops at the first supported format; Windows accepts the
   stream but renders nothing (black preview, then Camera-app error
   `0xA00F4271 (0x80070102)` = WAIT_TIMEOUT). Known upstream as
   [#11198](https://github.com/FreeRDP/FreeRDP/issues/11198) (C922,
   Feb 2025, still open). With the flag off, MJPG wins and is re-encoded
   — the path that worked before FreeRDP 3.12.0.

3. **First-frame libswscale deadlock — EVERY frame silently dropped** —
   `slimeos-rdpecam-sws-firstframe-deadlock.patch` (in this dir).
   Debian's backport of the CVE-2026-24677 fix (upstream d2d4f449) added
   `if (!ecam_sws_valid(stream)) return FALSE;` at the top of
   `ecam_encoder_compress_h264()`, but the sws context is created lazily
   *further down in that same function* — so the first frame always bails
   before the context can ever be created, and the camera streams zero
   frames forever ("Frame drop or error in ecam_encoder_compress" per
   frame at debug level; enumeration and StartStreams all look healthy).
   Upstream only escaped this by rewriting the encoder into
   `freerdp_video_context` (far too large to backport). Our patch removes
   the premature guard; the CVE's real protection — sws must match the
   current media-type dimensions — is still enforced by
   `ecam_init_sws_context()`, called immediately before `sws_scale()`,
   which recreates the context on any dimension change.

   Diagnosis method worth remembering: each pipeline stage (MJPEG decode
   with `AV_EF_EXPLODE`, sws_scale, x264 encode) was proven working in
   isolation on the target hardware with small C harnesses fed real
   captured camera frames — which pinned the failure to the glue code,
   where reading the patched source found the dead guard.

## Rebuild recipe
On any Docker host (the GCP hub was used):
```
docker run -d --name freerdp-rebuild -v /tmp/freerdp-out:/out debian:trixie sleep 14400
# inside the container:
sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
apt-get update && apt-get install -y devscripts quilt dpkg-dev fakeroot
cd /build && apt-get source freerdp3 && apt-get build-dep -y freerdp3
cd freerdp3-3.15.0+dfsg
# add the two patches to debian/patches/ + series,
# add -DRDPECAM_INPUT_FORMAT_H264=OFF next to -DCHANNEL_RDPECAM_CLIENT=ON in debian/rules,
# dch -v <version>+slimeosN, then:
dpkg-buildpackage -b -uc -us
```
Ship 4 debs — `freerdp3-x11`, `libfreerdp-client3-3`, `libfreerdp3-3`,
**and `libwinpr3-3`** (the full rebuild emits an exact-version dep on
winpr). dbgsym debs are produced automatically; keep them — a symbolized
backtrace is the difference between minutes and days on this channel.
Release as a GitHub release tag `freerdp3-camera-slimeosN`, then repoint
URL + sha256 pins in `install.sh` section 1b.

## Historical note: the unexplained 2026-07-16 SIGABRT
The first live test (different, YUYV-only webcam) SIGABRTed at
`Stream_SealLength` even with patch #1 installed; the crash log shows a
teardown-order signature (send on an already-corrupted stream while the
DVC channel was closing, then `Stream_Free` aborting on the same
stream). It never reproduced on `+slimeos3`+ with the C920, and bug #3
plausibly changed the timing that exposed it. If it ever returns:
dbgsym debs are in the release, core dumps + gdb are the tool
(`LimitCORE=infinity` drop-in for `slimeos-bridge.service`, core pattern
to `/var/tmp`).

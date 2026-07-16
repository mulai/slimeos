# FreeRDP camera (rdpecam) patches — experimental, parked

Webcam redirection into a Brain uses FreeRDP's MS-RDPECAM channel
(`/dvc:rdpecam`, gated behind `SLIMEOS_ENABLE_CAMERA=1` in
`/etc/slimeos/config`, **off by default**). Status as of 2026-07-16:
**not working end-to-end** — the channel loads and Windows sees the
camera, but the client SIGABRTs a few seconds into streaming. rdpecam is
a young upstream feature (landed 2025, still getting monthly fixes) with
several independent overflow bugs.

## Background: Debian ships FreeRDP without the camera channel at all
Debian trixie's `freerdp3` **archive** binaries contain no rdpecam code
even though `debian/rules` enables `CHANNEL_RDPECAM_CLIENT` and the
build-dep `libv4l-dev` is present — the compiled plugin never lands in
any binary package (a Debian packaging bug worth filing). Our fix: an
unmodified rebuild from the exact `deb13u3` source, where the channel
compiles fine, version-bumped `+slimeosN`. Released as
`freerdp3-camera-slimeos1` and installed (checksum-pinned) by
`install.sh`.

## Bugs found live (2026-07-16), in order
1. **Fixed buffer overflow on large frames** —
   `slimeos-rdpecam-sample-buffer-grow.patch` (in this dir).
   `ecam_dev_send_sample_response` wrote a whole frame into the fixed
   ~4 MB `sampleRespBuffer` without a capacity check; a 1080p YUY2 frame
   (~4.15 MB) overflowed it and `ecam_channel_write`'s `Stream_SealLength`
   aborted. Patch grows the buffer to fit. Built as `+slimeos2` (not
   released — see below).
2. **Second overflow in the encoder path (UNFIXED)** — the test webcam
   offers only raw YUYV (no MJPG/H264), so FreeRDP must H264-encode each
   frame before sending. With bug #1 patched, a YUYV-only camera
   (frames well under 4 MB) STILL SIGABRTs at `Stream_SealLength` — a
   distinct overflow on the encode/convert path (`encoding.c` /
   `uvc_h264.c`), not yet root-caused. Needs a symbolized backtrace
   (dbgsym debs were built alongside) to pin.

## Version state (deliberate, documented to avoid "drift" confusion)
- **Released / what `install.sh` fetches:** `+slimeos1` (3 debs, camera
  channel present but dormant; camera off by default). Self-consistent
  on a fresh trixie.
- **`+slimeos2`:** adds patch #1. Built in the on-hub build container,
  installed on the GA-78LMT-S2P dev box only (normal RDP verified fine).
  Not released because it doesn't make any camera actually work yet and
  needs a 4th deb (libwinpr3-3, exact-version dep). Fold patch #1 into a
  release only when resuming camera work and shipping a build that also
  clears bug #2.

## To resume
Rebuild container recipe is in project memory. Get a symbolized crash
(install the `*-dbgsym` debs already built, or run xfreerdp3 under gdb
with `/dvc:rdpecam`) to locate bug #2, then either patch it or wait for
an upstream FreeRDP that fixes the encoder path and re-test by flipping
`SLIMEOS_ENABLE_CAMERA=1` — no rebuild needed if a fixed FreeRDP ships in
Debian.

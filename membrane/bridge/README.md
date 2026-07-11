# slimeos-bridge

A thin local relay between the kiosk lock screen (`membrane/lockscreen/index.html`,
running inside cog/WPE WebKit) and `membrane/session/coordinator.sh`. It speaks
WebSocket on `127.0.0.1` to the browser and newline-delimited JSON on stdin/stdout
to the coordinator subprocess. It contains no product logic — see
`coordinator.sh`'s header comment for the actual protocol/state machine.

## Why a committed binary, not a build step

This is the first non-bash tooling in the Slime OS repo, and the Membrane device
has no Go toolchain and no internet access to one at install time. `install.sh`
downloads a prebuilt static binary from `bin/` the same way it already curls every
other script. There is deliberately no Makefile or CI here yet — one artifact,
two target triples, solo maintainer — revisit once a second Go binary exists or
the arm64 (Raspberry Pi) target actually ships.

## Rebuilding

```
./build.sh
```

Requires a local Go toolchain (`brew install go`). Produces
`bin/slimeos-bridge-linux-amd64` and `bin/slimeos-bridge-linux-arm64`, both fully
static (`CGO_ENABLED=0`) so they carry no glibc-version dependency on the target
— the same reliability bar the rest of the install already assumes of bash.
Commit the resulting binaries alongside any source change.

## Flags

```
slimeos-bridge --listen=127.0.0.1:7770 --coordinator=/opt/slimeos/coordinator.sh --log=/var/log/slimeos/coordinator.log
```

`--listen` must be a loopback address (enforced at startup) — this relay is not
meant to be reachable off-device.

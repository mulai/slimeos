# Slime OS — Self-service pairing-code generator
# Multi-stage build, same shape as brain/power/Dockerfile.
#
# No EXPOSE: this container runs with network_mode: service:wireguard (see
# docker-compose.yml), so it has no network namespace of its own -- the
# binary's own bind address (:8090, reachable via Caddy as wireguard:8090)
# is the only exposure that exists.

FROM golang:1.21-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /slimeos-pairgen .

FROM alpine:3.20
# provision-peer.sh/pair-peer.sh were only ever run before inside
# lscr.io/linuxserver/wireguard (a feature-rich Alpine image with GNU
# coreutils/grep already present) -- a bare alpine base needs these
# explicitly, or the scripts fail on BusyBox's grep lacking -P/PCRE
# (`grep -oP '10\.10\.0\.\K\d+'` in provision-peer.sh) and other
# GNU-vs-BusyBox behavior gaps:
#   bash       — both scripts are #!/usr/bin/env bash, not POSIX sh
#   grep       — Alpine's `grep` package is GNU grep (PCRE-enabled),
#                shadowing BusyBox's applet
#   coreutils  — GNU date/sort/mktemp/tr, matching what these scripts
#                were actually written and tested against
#   wireguard-tools — `wg genkey`/`pubkey`/`genpsk`/`addconf`/`syncconf`
#   redis      — provides redis-cli, which pair-peer.sh shells out to
#                directly (same package brain/wireguard/custom-init/
#                10-redis-cli.sh installs into the wireguard container)
RUN apk add --no-cache ca-certificates bash grep coreutils wireguard-tools redis
COPY --from=build /slimeos-pairgen /usr/local/bin/slimeos-pairgen
ENTRYPOINT ["/usr/local/bin/slimeos-pairgen"]

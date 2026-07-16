# Slime OS — Brain power management (auto-deallocate / wake-on-connect)
# Multi-stage build: unlike membrane/bridge (which ships prebuilt static
# binaries curled by install.sh, since a Membrane device has no Go
# toolchain), the Brain host already runs `docker compose build`, so this
# builds from source on every deploy instead of committing a binary.
#
# ca-certificates is genuinely required here (not cargo-culted from enroll):
# this service speaks TLS to login.microsoftonline.com and
# management.azure.com.
#
# No EXPOSE: this container runs with network_mode: service:wireguard (see
# docker-compose.yml), so it has no network namespace of its own — the
# binary's own bind address (10.10.0.1:7677, on wg0 inside the WireGuard
# container's netns) is the only exposure that exists.

FROM golang:1.21-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /slimeos-power .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /slimeos-power /usr/local/bin/slimeos-power
ENTRYPOINT ["/usr/local/bin/slimeos-power"]

# Slime OS — Brain enrollment endpoint
# Multi-stage build: unlike membrane/bridge (which ships prebuilt static
# binaries curled by install.sh, since a Membrane device has no Go
# toolchain), the Brain host already runs `docker compose build`, so this
# builds from source on every deploy instead of committing a binary.

FROM golang:1.21-alpine AS build
WORKDIR /src
COPY go.mod main.go ./
RUN CGO_ENABLED=0 go build -o /slimeos-enroll .

FROM alpine:3.20
RUN apk add --no-cache ca-certificates
COPY --from=build /slimeos-enroll /usr/local/bin/slimeos-enroll
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/slimeos-enroll", "--listen=:8080"]

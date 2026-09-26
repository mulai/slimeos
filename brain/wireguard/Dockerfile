# Slime OS — WireGuard hub image
# linuxserver/wireguard (pinned, #46) plus what the hub scripts use:
#   redis           — redis-cli for pair-peer.sh
#   openssh-client, sshpass — reaching a Membrane's Remote Support SSH from
#                     the hub (the only route to devices)
# flock is already in the base image (provision-peer.sh's lock).
FROM lscr.io/linuxserver/wireguard:1.0.20250521-r1-ls114@sha256:1bf21d1c8933f7376da97bb14a459ae18e716e49d2e3456dbfd71414f60a319a
RUN apk add --no-cache redis openssh-client sshpass

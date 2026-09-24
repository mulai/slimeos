#!/bin/bash
# Slime OS — startup script for the FreeRDP build VM (GCP `slimeos-freerdp-build`,
# e2-standard-4, Debian 13, asia-southeast1-b). Set as the instance's startup-script
# metadata. Installs the build tooling once, and an idle watchdog that powers the VM off
# after 60 min with no SSH session and low load, so a forgotten VM only costs its disk.
# Start it with `gcloud compute instances start slimeos-freerdp-build
# --zone=asia-southeast1-b`. Rebuild recipe: membrane/freerdp/udp-patches/README.md.
set -u

if [[ ! -f /var/lib/slimeos-build-provisioned ]]; then
    export DEBIAN_FRONTEND=noninteractive
    sed -i 's/^Components: main$/Components: main contrib non-free non-free-firmware/' \
        /etc/apt/sources.list.d/debian.sources 2>/dev/null || true
    # deb-src so `apt-get source freerdp3` / `apt-get build-dep freerdp3` work
    if ! grep -q deb-src /etc/apt/sources.list.d/debian.sources 2>/dev/null; then
        sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/debian.sources
    fi
    apt-get update
    apt-get install -y build-essential devscripts equivs ccache git tmux htop \
        dpkg-dev fakeroot quilt xvfb imagemagick xdotool wireguard-tools libva-dev
    apt-get build-dep -y freerdp3 || true
    touch /var/lib/slimeos-build-provisioned
fi

cat > /usr/local/sbin/idle-poweroff.sh <<'EOF'
#!/bin/bash
# Called every 5 min by cron. Counts consecutive idle checks in a state file.
STATE=/run/idle-count
active_ssh=$(who | wc -l)
load=$(awk '{print $1}' /proc/loadavg)
busy=$(awk -v l="$load" 'BEGIN{print (l>0.5)?1:0}')
# A detached build (tmux, no SSH) keeps load high, so it still counts as busy.
if [[ "$active_ssh" -gt 0 || "$busy" -eq 1 ]]; then
    echo 0 > "$STATE"; exit 0
fi
n=$(( $(cat "$STATE" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$STATE"
# 12 checks x 5 min = 60 min idle
if (( n >= 12 )); then
    logger -t idle-poweroff "idle 60 min, powering off"
    systemctl poweroff
fi
EOF
chmod 755 /usr/local/sbin/idle-poweroff.sh
echo '*/5 * * * * root /usr/local/sbin/idle-poweroff.sh' > /etc/cron.d/idle-poweroff
echo 0 > /run/idle-count

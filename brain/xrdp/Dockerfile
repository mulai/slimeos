# Slime OS — Linux Cloud Desktop Image
# Ubuntu 22.04 LTS + XFCE + xRDP
# This is the "free path" desktop: provisioned when the user has no transferable Windows license.
# The image is also used as the development/testing environment.
#
# Design goals:
#   - Lightweight: XFCE, not GNOME/KDE
#   - Fast session start: pre-configured xRDP, no first-run setup
#   - Reproducible: user is created and configured at build time via env vars at runtime
#   - Secure: no SSH, no root login, xRDP only via WireGuard

FROM ubuntu:22.04

ENV DEBIAN_FRONTEND=noninteractive
ENV TZ=UTC

# ── Base system + XFCE + xRDP ─────────────────────────────────────────────────
RUN apt-get update -qq && apt-get install -y --no-install-recommends \
    # Core
    ca-certificates curl wget gnupg \
    sudo locales tzdata \
    # Desktop environment (XFCE — lightweight)
    xfce4 xfce4-terminal xfce4-goodies \
    # xRDP
    xrdp \
    xorgxrdp \
    # Fonts
    fonts-liberation fonts-noto-core \
    # Common apps (firefox installed separately below -- see note)
    mousepad \
    thunar \
    # Utilities
    nano vim-tiny \
    net-tools \
    dbus-x11 \
    pulseaudio pulseaudio-utils \
    # Theming
    adwaita-icon-theme \
    && rm -rf /var/lib/apt/lists/*

# ── Firefox (Mozilla's real .deb, NOT Ubuntu's apt package) ───────────────────
# Ubuntu's `firefox` apt package (since 20.04) is a thin transitional wrapper
# that pulls in the Snap build on first run. Snap-packaged apps are unreliable
# inside a Docker container (snapd/squashfuse don't run properly without extra
# setup), causing exactly the random crashes reported on this desktop -- this
# is the actual fix, not just an Ubuntu-version bump (24.04's `firefox` apt
# package has the identical snap-wrapper trap). Official Mozilla apt repo,
# pinned above Ubuntu's own package so `apt-get install firefox` always
# resolves to the real Mozilla-built .deb, never the snap redirector.
RUN install -d -m 0755 /etc/apt/keyrings && \
    wget -q https://packages.mozilla.org/apt/repo-signing-key.gpg -O /etc/apt/keyrings/packages.mozilla.org.asc && \
    echo "deb [signed-by=/etc/apt/keyrings/packages.mozilla.org.asc] https://packages.mozilla.org/apt mozilla main" \
        > /etc/apt/sources.list.d/mozilla.list && \
    printf 'Package: *\nPin: origin packages.mozilla.org\nPin-Priority: 1000\n' \
        > /etc/apt/preferences.d/mozilla && \
    apt-get update -qq && apt-get install -y --no-install-recommends firefox && \
    rm -rf /var/lib/apt/lists/*

# ── Locale ────────────────────────────────────────────────────────────────────
RUN locale-gen en_US.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# ── xRDP configuration ────────────────────────────────────────────────────────
# Use Xorg (xorgxrdp) backend for best compatibility with FreeRDP GFX pipeline
RUN sed -i '0,/^\[Xorg\]/s/^#\?port=.*/port=3389/' /etc/xrdp/xrdp.ini && \
    sed -i 's/^#\?max_bpp=.*/max_bpp=32/' /etc/xrdp/xrdp.ini && \
    sed -i 's/^#\?xserverbpp=.*/xserverbpp=32/' /etc/xrdp/xrdp.ini && \
    sed -i 's/^#\?address=.*/address=0.0.0.0/' /etc/xrdp/xrdp.ini && \
    sed -i 's/^#\?security_layer=.*/security_layer=tls/' /etc/xrdp/xrdp.ini && \
    sed -i 's/^#\?crypt_level=.*/crypt_level=high/' /etc/xrdp/xrdp.ini

# Use XFCE as the session
RUN echo "startxfce4" > /etc/skel/.xsession && \
    echo "startxfce4" > /root/.xsession

# ── Slime OS desktop branding ─────────────────────────────────────────────────
# Background colour and basic XFCE defaults
RUN mkdir -p /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml
COPY config/xfce4-desktop.xml /etc/skel/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-desktop.xml

# ── Entrypoint ────────────────────────────────────────────────────────────────
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 3389

ENTRYPOINT ["/entrypoint.sh"]

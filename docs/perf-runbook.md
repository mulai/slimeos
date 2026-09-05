# Slime OS — Membrane Performance Runbook

Diagnostic + tuning guide for a Membrane that feels laggy, drops frames, or
shows high latency on a live Brain (FreeRDP over WireGuard) session.

All commands are lightweight — `/proc`, `/sys`, `iproute2`, `ethtool`,
`wireguard-tools`, `iw`. `sysstat` (`mpstat`/`pidstat`) and `iw` are a ~1 MB
install with no GUI and are worth having on a test unit.

Running remotely: hub → `docker exec slimeos-wireguard sshpass -p '<Remote
Support pw>' ssh slime@<device-ip>`; privileged steps via
`su -s /bin/bash slime-recovery -c "echo <PIN> | sudo -S -p '' …"` (see
`slimeos-infra` memory / the security-hardening doc).

---

## 0. Read this first

- **WireGuard uses ChaCha20‑Poly1305, not AES.** AES‑NI is irrelevant.
  What matters is the SSSE3/AVX ChaCha path — check `/proc/crypto` shows
  `chacha20-simd` / `poly1305-simd`, not `-generic`.
- On any half‑modern x86, symmetric crypto is **not** the bottleneck for an
  RDP stream. `openssl speed -evp chacha20-poly1305` gives the per‑core
  ceiling (hundreds of MB/s to >1 GB/s); an RDP session is 3–50 Mbps.
- The usual real limiters, in order of likelihood: **the network link
  (especially Wi‑Fi)**, then **single‑core softirq / IRQ pinning**, then
  **FreeRDP software H.264 decode**, then cpufreq governor / C‑state jitter.
- WPE WebKit on Debian trixie is built **without MediaStream** — irrelevant
  to RDP perf, but it's why the camera test tab uses `fswebcam`, not
  `<video>`.

---

## 1. WireGuard packet loss & MTU

```bash
wg show wg0 ; wg show wg0 transfer
ip -s link show wg0                       # errors/dropped on the tunnel = crypto/queue stall
PHY=$(ip route get 1.1.1.1 | awk '{print $5; exit}')
ip -s -s link show "$PHY"
ethtool -S "$PHY" 2>/dev/null | grep -iE 'err|drop|discard|fifo|miss|over|no_?buf' | grep -vE ': 0$'

# per-CPU receive-backlog drops
awk '{printf "cpu%d dropped=%d squeezed=%d\n",NR-1,("0x"$2)+0,("0x"$3)+0}' /proc/net/softnet_stat  # gawk; mawk lacks strtonum

# UDP errors + IP fragmentation (WG is UDP)
nstat -az | grep -iE 'UdpInErrors|UdpRcvbufErrors|IpReasm|IpFrag'

# RDP TCP stream health — the single best signal
ss -tin dst 10.10.0.0/24     # watch: retrans, bytes_retrans, rtt/mdev, minrtt, mss, pmtu, rcv_ooopack
```

**MTU probe** — path MTU to the WG *endpoint* (its public IP, not the tunnel IP):

```bash
EP=$(wg show wg0 endpoints | awk '{print $2}' | cut -d: -f1)
for s in 1372 1400 1414 1432 1452 1464 1472; do
  ping -M do -s $s -c2 -W1 "$EP" >/dev/null 2>&1 && echo "path $((s+28)) OK" || echo "path $((s+28)) FAIL"
done
```

Largest `OK` = path MTU. **Ideal `wg0` MTU = pathMTU − 60** (IPv4 outer:
20 IP + 8 UDP + 16 WG hdr + 16 Poly1305). Common results: 1500 clean →
1440; **1492 (PPPoE — typical Indonesian fibre/DSL) → 1432**.

> Don't raise `wg0` MTU from an SSH session that runs *through* wg0 — a
> too‑large value black‑holes the tunnel. Do it from console, or arm
> `( sleep 60; ip link set wg0 mtu 1420 ) &` first.
> If you're already within ~1% of optimal with slack (e.g. 1420 on a 1492
> path) and see 0 frag / 0 drop — **leave it**. The gain isn't worth the risk.

---

## 2. CPU crypto / softirq

```bash
grep -E 'name|driver|priority' /proc/crypto | grep -iA2 -E 'chacha|poly1305'
openssl speed -elapsed -evp chacha20-poly1305 -seconds 2 | tail -2   # per-core ceiling

# where WG crypto actually runs (spread across kworkers = healthy)
pidstat -t 1 3 | grep -E 'wg-crypt|ksoftirqd'
# per-core, during a live session
mpstat -P ALL 1 5

# NIC IRQ: is it MSI-X + spread, or one legacy line pinned to one core?
grep -iE "$PHY|ath9k|CPU0" /proc/interrupts
# software steering (the fix for a single-queue / legacy-IRQ NIC)
cat /sys/class/net/$PHY/queues/rx-0/rps_cpus     # 00 = off

# governor + live freq (schedutil can lag on bursty frames; performance removes it)
cat /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor
grep '' /sys/devices/system/cpu/cpu*/cpufreq/scaling_cur_freq   # run DURING load

# Bulldozer/older AMD: core pairs share one FPU — map them for pinning
grep '' /sys/devices/system/cpu/cpu*/cache/index2/shared_cpu_list | sort -u
```

If one core sits at ~100% `%soft` during RDP while `openssl speed` shows
10×+ your bitrate → it's **packet‑rate / IRQ steering**, not the cipher.
Fix with RPS + governor, not a faster CPU.

---

## 3. FreeRDP / Cage local draw

```bash
ps -eo pid,psr,pcpu,pmem,nlwp,comm | grep -E 'cage|Xwayland|xfreerdp'
FRDP=$(pgrep -nf xfreerdp); ps -L -o tid,psr,pcpu,comm -p "$FRDP" | sort -k3 -rn | head
```

- `freerdp3-x11` runs on **Xwayland** under Cage (extra hop).
- `SLIMEOS_FREERDP_EXTRA_FLAGS` default is `/gfx:AVC444 /bpp:32 +video` —
  AVC444 is software H.264 4:4:4, the heaviest decode. If `xfreerdp3`
  totals ≳ 2 cores and frames drop with the network idle, A/B test
  `/gfx:AVC420` (half the chroma work) or `/gfx:RFX` (much lighter). If
  drops vanish → local decode‑bound; drop resolution or fps, not a flag.
- GPU / KMS: `lspci -nnk | grep -iA3 VGA` ; `dmesg | grep -iE 'radeon|amdgpu|drm|flip_done|GPU fault'`.
  `journalctl -b | grep -iE 'wlroots|renderer|GLES|pixman|llvmpipe'` —
  `pixman`/`llvmpipe` = compositing fell back to the CPU.

---

## 4. One‑liner live overview (per‑core CPU + iface drops + ctxt switches)

```bash
PHY=$(ip route get 1.1.1.1 | awk '{print $5; exit}'); \
while :; do clear; date; \
 mapfile -t A < <(grep '^cpu[0-9]' /proc/stat); C1=$(awk '/^ctxt/{print $2}' /proc/stat); sleep 1; \
 mapfile -t B < <(grep '^cpu[0-9]' /proc/stat); C2=$(awk '/^ctxt/{print $2}' /proc/stat); \
 for i in "${!A[@]}"; do set -- ${A[$i]}; c=$1;i1=$((${5}+${6}));t1=$(($2+$3+$4+$5+$6+$7+$8+$9)); \
   set -- ${B[$i]}; i2=$((${5}+${6}));t2=$(($2+$3+$4+$5+$6+$7+$8+$9)); \
   awk -v c=$c -v b=$(((t2-t1)-(i2-i1))) -v T=$((t2-t1)) 'BEGIN{printf "%-6s %5.1f%% busy\n",c,T?100*b/T:0}'; done; \
 echo "ctxt/s: $((C2-C1))"; \
 grep -E "$PHY|wg0" /proc/net/dev | awk -F'[: ]+' '{o=($1=="");print $(1+o)" RXdrop="$(5+o)" TXdrop="$(13+o)" RXerr="$(4+o)}'; \
done
```

With `sysstat`: `mpstat -P ALL 1`, `pidstat -t -w 1`, `sar -n EDEV 1` do
this properly.

---

## Worked example — AMD FX‑6100 test box (2026‑09‑06)

Gigabyte GA‑78LMT‑S2P, FX‑6100 (Bulldozer, 6c), 8 GB, discrete Radeon HD
5570 (Turks), Debian 13 / kernel 6.12. Reported: "35 ms latency, MTU
locked at 1280, suspect CPU crypto / small‑packet overhead."

**Findings — three of four suspects were wrong:**

| Suspect | Reality |
|---|---|
| MTU 1280 | Actually **1420**. Measured path MTU **1492** (PPPoE). 1420 is <1 % off optimal, 0 frag, 0 drop → left as‑is. |
| Crypto overhead | `chacha20-simd`/`poly1305-simd` active; `openssl speed` = **~1030 MB/s/core**. Session was ~4 Mbps. `wg0`: 0 err / 0 drop. Under live load `wg-crypt` kworkers were ~2 % total. |
| Weak GPU / SW render | Discrete **Radeon HD 5570** (UVD3, r600g), HW GL compositing, no DRM errors, clean 1080p scanout. |
| **The uplink** | **Wi‑Fi** (`ath9k`), and this *is* the limiter. |

**Under a live Brain session (mpstat, 5 s):** every core **59–76 % idle**
(busiest CPU4 at ~41 %); `xfreerdp3` (51 threads) ~**0.65 core** total;
governor already at 3.2–3.3 GHz. Nothing on the box is saturated.

**The Wi‑Fi link:**
```
2.4 GHz, channel 2, 40 MHz width        <- 40 MHz on 2.4 GHz straddles half the band
1x1 stream, MCS 7 (150 Mbit/s ceiling)
signal -60..-62 dBm
L2 tx-retry rate ~5.2%  (2540 TCP out-of-order pkts as a result)
path RTT: minrtt 31.6 ms, avg 40.7, mdev 4.6   <- the "35 ms" + the jitter
ath9k IRQ ~540/s, 100% on CPU4 (legacy IO-APIC, no MSI)
```
RDP TCP stream itself: **zero retransmits** — the transport is clean; the
cost is Wi‑Fi jitter + retries + the double WAN hop (ID → GCP Singapore hub
→ Azure ID).

**Applied (runtime, this box):** `performance` governor; RPS on `wlp3s6`
(`rps_cpus=2f`, off IRQ core CPU4); `tcp_congestion_control=bbr`;
`tcp_notsent_lowat=131072`; `rmem/wmem_max=8 MB`. `wg0` MTU left at 1420.
**Not touched:** anything crypto / decode / C‑state — the CPU isn't the
constraint.

---

## Wi‑Fi Membrane tuning (fleet — laptops without a cable)

Wired is always better, but many Membranes are notebooks. To get the most
out of Wi‑Fi, in rough order of impact:

**AP side (document for the operator — not settable on the Membrane):**
1. **5 GHz.** If the AP has a 5 GHz radio, put the Membrane on it — far
   less congestion, 80 MHz width, no 11b clients dragging airtime.
2. **2.4 GHz → 20 MHz width**, channel 1/6/11 only. 40 MHz on 2.4 GHz
   causes and collects interference; it usually *lowers* real throughput.
3. Signal **≥ −55 dBm** at the Membrane. Below that the link drops to
   single‑stream / low MCS and the retry rate climbs.
4. Enable **WMM / airtime fairness** on the AP.

**Membrane side (should be baked into `install.sh` — currently applied only
at runtime on the test box):**
```bash
# Wi-Fi power save OFF  (already default in Slime OS — verify: `iw dev <wl> get power_save`)
nmcli connection modify <wifi-con> 802-11-wireless.powersave 2   # 2 = disable

# cpufreq: performance (thin client, mains-powered)
#   -> systemd drop-in or tmpfiles: echo performance > /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor

# RPS: steer rx softirq off the (often legacy, single) Wi-Fi IRQ core
#   udev/oneshot per wifi iface:
#     echo <mask-excluding-irq-core> > /sys/class/net/<wl>/queues/rx-0/rps_cpus
#     echo 4096 > /sys/class/net/<wl>/queues/rx-0/rps_flow_cnt
#   sysctl: net.core.rps_sock_flow_entries = 32768

# TCP for a jittery wireless + double-WAN-hop path  (/etc/sysctl.d/):
net.ipv4.tcp_congestion_control = bbr        # + `tcp_bbr` in /etc/modules-load.d
net.core.default_qdisc          = fq_codel   # already the Debian default
net.ipv4.tcp_notsent_lowat      = 131072     # lower local queuing latency
net.core.rmem_max               = 8388608
net.core.wmem_max               = 8388608
net.ipv4.tcp_rmem               = 4096 131072 8388608

# WireGuard: MTU in the config template the hub hands out
[Interface]
MTU = 1432        # pathMTU(1492 PPPoE) - 60 ; use 1420 if the path is unknown
```
> The **video** direction's congestion control runs on the **Brain**
> (xrdp host), not the Membrane — BBR + `fq` there is the bigger win for a
> lossy client link. BBR on the Membrane only helps Membrane‑originated
> streams (input, clipboard, redirected files).

**FreeRDP** on a weak client or a constrained link: fall back
`/gfx:AVC444` → `/gfx:AVC420` → `/gfx:RFX`, and/or cap fps / resolution via
a hardware profile.

---

## Don't chase

AES‑NI, `sha_ni`, crypto‑offload engines, `mitigations=off`, deep‑C‑state
disables, jumbo frames — none of these move the needle on a Membrane whose
CPU sits >50 % idle under load. Fix the link first.

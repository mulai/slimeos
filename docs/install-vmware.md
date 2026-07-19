# Installing Slime OS in VMware (Membrane guest)

This guide walks through installing the Slime OS Membrane as a guest VM in
**VMware Workstation Pro** or **VMware Fusion**. It's useful for testing,
demos, or running Slime OS as a virtual thin client on a machine that's
already running something else.

> Validated end-to-end on VMware Workstation Pro 26H1 (Windows host):
> fresh install → auto-detected hardware profile → kiosk lock screen →
> WireGuard pairing → RDP to a cloud Brain with working audio.

---

## 1. Prerequisites

- VMware Workstation Pro or VMware Fusion
- [Debian 13 ("trixie") netinst ISO](https://www.debian.org/CD/netinst/)
- A Slime OS Brain already running and reachable (see the main
  [README](../README.md#2-deploy-the-cloud-brain) or
  [`brain-hosting.md`](brain-hosting.md))

---

## 2. Create the VM

| Setting | Value |
|---|---|
| Guest OS | Debian 12.x/13.x (64-bit) |
| Firmware | **Legacy BIOS** (not UEFI) |
| Disk | 8 GB+, SCSI (LSI Logic) |
| Network adapter | NAT or Bridged — either works |
| Memory | 2 GB+ |

Before first boot, open the VM's settings and:

1. Under **Display**, enable **"Accelerate 3D graphics"** and give it some
   graphics memory. This is required — without it, the compositor fails to
   initialize (`EGL_NOT_INITIALIZED`) and the VM never reaches the kiosk
   screen.
2. Attach the Debian netinst ISO as the CD/DVD drive.

Boot the VM.

---

## 3. Run the automated install

At the Debian installer's boot menu, go to **Advanced options → Automated
install**, then edit the boot command line and append:

```
auto=true url=https://raw.githubusercontent.com/mulai/slimeos/main/membrane/preseed/slimeos-bios.preseed.cfg
```

> Use the `-bios` preseed — VMware guests boot Legacy BIOS by default, and
> this variant matches that (no EFI System Partition, `grub-pc` instead of
> `grub-efi-amd64`). If you deliberately configured the VM for UEFI instead,
> use `slimeos.preseed.cfg` in that URL instead.

The installer partitions the disk, installs a minimal Debian base, and hands
off to the Slime OS installer automatically. This takes 10–20 minutes
depending on your connection — the VM reboots on its own when done.

---

## 4. First boot

On first boot, Slime OS detects that it's running on VMware's virtual
hardware and automatically applies the matching profile — no manual
configuration needed. You should land on the **Connect screen**.

If you instead see a black screen with no error, double-check that
**"Accelerate 3D graphics"** is enabled in the VM's Display settings (step 2)
and reboot the VM.

---

## 5. Fix audio (host-side, one-time)

VMware Workstation's default virtual sound card doesn't reliably reach the
host mixer on Windows hosts — guest-side audio looks fine, but nothing plays
on the host. This is fixed in the VM's `.vmx` file, not inside the guest.

Shut the VM down, then edit its `.vmx` file (find it via VM settings → the
file path is shown, or right-click the VM → **Show in Finder/Explorer**) and
set:

```
sound.virtualDev = "hdaudio"
sound.autodetect = "TRUE"
sound.fileName = "-1"
```

Save, boot the VM back up, and audio redirected from the cloud Brain will
play correctly.

---

## 6. Connect to your Brain

On the Connect screen, choose **"+ Add new Brain"**, enter its WireGuard
address (e.g. `10.10.0.1`), and follow the on-screen pairing flow. Once
paired, the VM behaves exactly like a physical Slime OS device — it will
reconnect automatically on every future boot.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Black screen, compositor alive | 3D acceleration off | Enable "Accelerate 3D graphics" in VM Display settings |
| No audio on host despite guest playing fine | Stale/default virtual sound device | Set `sound.virtualDev`/`sound.autodetect`/`sound.fileName` in the `.vmx` (step 5) |
| Installer hangs "awaiting response" fetching packages | Occasional MTU issue on some host networks | At a shell (installer → Advanced → rescue, or F2 on some builds), try `ip link set dev ens33 mtu 1280`, then retry |
| `piix4_smbus` message during boot | Harmless VMware ACPI noise | Ignore |

---

## See also

- [`architecture.md`](architecture.md) — how the Membrane, Brain, and hardware profiles fit together
- [`brain-hosting.md`](brain-hosting.md) — deploying the cloud Brain
- [`windows-cloud-desktop.md`](windows-cloud-desktop.md) — setting up a Windows Brain on Azure
- [`membrane/hardware-profiles/009-vmware-guest.sh`](../membrane/hardware-profiles/009-vmware-guest.sh) — the profile applied automatically in step 4

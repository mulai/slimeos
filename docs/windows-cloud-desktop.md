# Windows Cloud Desktop on Azure

This guide sets up a **Windows 11 Pro cloud desktop** on Azure, reachable from any Slime OS client via WireGuard. No RDP port is ever exposed to the public internet.

> **Production Azure Brain (as of 2026-08-15)**: `Standard_NV6ads_A10_v5` (GPU-accelerated) in `indonesiacentral`, rg `slimeos-gpu-test`, VM name `slimeos-gputest`, WireGuard peer `10.10.0.6`. Replaces the earlier `D4s_v3` VM in `eastasia` (rg `slimeos-windows`, fully deleted). See "GPU acceleration" below — hardware NVIDIA H.264 RDP encode is confirmed working via Windows' own event log, ~2x the hourly cost of the D4s_v3 setup.

## How it works

```
Membrane (Debian) ──┐
                     ├── WireGuard tunnel ──► Azure Windows 11 VM (RDP :3389)
Windows App (any OS)─┘
```

The Windows VM sits on the Slime OS WireGuard network (`10.10.0.0/24`) as a peer. Clients connect to its internal IP — the VM has no public inbound ports.

## Prerequisites

- Azure account (new accounts get $200 free credit)
- Azure CLI installed (`brew install azure-cli` on Mac)
- Slime OS Brain already running (GCP or any Linux host)

---

## 1. Create the VM

```bash
# Login
az login

# Resource group
az group create --name slimeos-windows --location southeastasia

# Windows 11 Pro VM — no public inbound ports
az vm create \
  --resource-group slimeos-windows \
  --name slimeos-windows \
  --image MicrosoftWindowsDesktop:windows-11:win11-24h2-pro:latest \
  --size Standard_D2s_v3 \
  --admin-username slimeadmin \
  --admin-password "YourStrongPassword!Az" \
  --public-ip-sku Standard \
  --nsg-rule None
```

> **Licensing note:** Azure activates Windows automatically via KMS — the VM hourly rate includes the Windows license. No retail key required.

> **`--nsg-rule None`, not `RDP`.** Using `--nsg-rule RDP` opens port 3389 to the entire public internet, not just the WireGuard tunnel — defeats the whole "no public RDP" design. Hit this for real on 2026-08-15 (a test VM created with `--nsg-rule RDP` sat with 3389 open to `*` until caught and fixed with `az network nsg rule delete`) — always verify with `az network nsg rule list` after creation, don't just trust the flag you meant to pass.

### GPU acceleration (optional)

For hardware-accelerated RDP video (NVIDIA H.264 encode instead of software), use a GPU SKU from the `NVadsA10_v5` family instead of a plain `D`-series size — e.g. `Standard_NV6ads_A10_v5` (6 vCPU, 1/6 A10 GPU, 4 GiB vRAM). Everything else in this guide (WireGuard setup, RDP enablement) is identical; FreeRDP clients don't need any changes, since `/gfx:AVC444 +video` is already the default flag set in every Membrane hardware profile.

**Extra steps beyond a plain VM:**
1. **GPU driver extension** (needs a reboot to actually bind — `Status: Error` in `Get-PnpDevice` right after install is normal, reboot fixes it):
   ```bash
   az vm extension set --resource-group <rg> --vm-name <vm> \
     --name NvidiaGpuDriverWindows --publisher Microsoft.HpcCompute --version 1.6
   az vm restart --resource-group <rg> --name <vm>
   ```
2. **Two registry keys** (no domain/GPO infrastructure needed — run via `az vm run-command invoke --command-id RunPowerShellScript`):
   ```powershell
   $path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services"
   New-ItemProperty -Path $path -Name "AVCHardwareEncodePreferred" -Value 1 -PropertyType DWord -Force
   New-ItemProperty -Path $path -Name "AVC444ModePreferred" -Value 1 -PropertyType DWord -Force
   New-ItemProperty -Path $path -Name "bEnumerateHWBeforeSW" -Value 1 -PropertyType DWord -Force
   Restart-Service -Name TermService -Force
   ```
3. **Verify it's actually working** — don't trust `nvidia-smi`'s encoder/decoder utilization counters (they read 0% on this GRID vGPU profile even under real sustained RDP traffic, a telemetry gap not a real signal). Instead check the Windows event log during a live session:
   ```powershell
   Get-WinEvent -LogName Microsoft-Windows-RemoteDesktopServices-RdpCoreTS/Operational -MaxEvents 30 |
     Where-Object Id -eq 170
   ```
   Look for `AVC hardware encoder enabled: 1, encoder name is NVIDIA H.264 Encoder MFT` — this is the real, authoritative confirmation.

**Cost**: roughly 2x the equivalent D-series SKU (`NV6ads_A10_v5` Windows on-demand was $0.832/hr vs. `D4s_v3`'s $0.409/hr in `indonesiacentral`, per Azure's retail pricing API, 2026-08-15). GPU family quota defaults to 0 on subscriptions that have never run a GPU VM — request an increase via the Azure Portal (Quotas → My Quotas → Compute); the CLI/API self-service path (`az quota update`) fails instantly with `ContactSupport` for a first-ever GPU request, don't bother trying it. Quota approval may land in a different region than requested if your preferred region has no capacity for the SKU family at all (confirmed: Singapore/`southeastasia` has zero capacity for the entire `NVadsA10v5` family, regardless of quota).

---

## 2. Install WireGuard and join the Brain network

Get the peer config from your Brain (peer slot 2 = `10.10.0.3`):

```bash
# On the GCP/Linux Brain host
docker exec slimeos-wireguard cat /config/peer2/peer2.conf
```

Then push the WireGuard config to the Azure VM via Run Command:

```bash
az vm run-command invoke \
  --resource-group slimeos-windows \
  --name slimeos-windows \
  --command-id RunPowerShellScript \
  --scripts '
    $installer = "$env:TEMP\wireguard-installer.exe"
    Invoke-WebRequest -Uri "https://download.wireguard.com/windows-client/wireguard-installer.exe" -OutFile $installer
    Start-Process -FilePath $installer -ArgumentList "/S" -Wait
    Start-Sleep -Seconds 5

    $conf = "C:\Program Files\WireGuard\Data\Configurations\slimeos-brain.conf"
    New-Item -ItemType Directory -Path (Split-Path $conf) -Force | Out-Null

    # IMPORTANT: write without BOM — WireGuard rejects UTF-8 BOM
    $config = "[Interface]`r`nAddress = 10.10.0.3/24`r`nPrivateKey = <PEER2_PRIVATE_KEY>`r`nListenPort = 51820`r`n`r`n[Peer]`r`nPublicKey = <BRAIN_PUBLIC_KEY>`r`nPresharedKey = <PEER2_PRESHARED_KEY>`r`nEndpoint = vpn.slimeos.com:51820`r`nAllowedIPs = 10.10.0.0/24,10.11.0.0/24`r`nPersistentKeepalive = 25"
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($conf, $config, $utf8NoBom)

    & "C:\Program Files\WireGuard\wireguard.exe" /installtunnelservice $conf
    Start-Sleep -Seconds 3
    Start-Service "WireGuardTunnel`$slimeos-brain"

    # Enable RDP
    Set-ItemProperty -Path "HKLM:\System\CurrentControlSet\Control\Terminal Server" -Name "fDenyTSConnections" -Value 0
    Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
  '
```

Replace `<PEER2_PRIVATE_KEY>`, `<BRAIN_PUBLIC_KEY>`, and `<PEER2_PRESHARED_KEY>` with values from the peer config.

> **Common gotcha:** PowerShell's `Out-File -Encoding utf8` adds a BOM that WireGuard rejects. Always use `[System.Text.UTF8Encoding]::new($false)` to write config files.

---

## 3. Verify the tunnel

```bash
# On the Brain host — should show a recent handshake for peer 10.10.0.3
docker exec slimeos-wireguard wg show
```

---

## 4. Connect

**From Membrane (Debian thin client):**
```
RDP host: 10.10.0.3
Port:     3389
```

**From any OS with WireGuard + Windows App:**
1. Connect WireGuard to the Brain
2. Open Windows App → add PC → host `10.10.0.3`
3. Login with `slimeadmin` / your password

---

## Cost reference

| Setup | Hourly (on-demand) |
|---|---|
| Standard_D4s_v3, Windows | $0.409/hr (`indonesiacentral`, 2026-08-15) |
| Standard_NV6ads_A10_v5, Windows (GPU) | $0.832/hr (`indonesiacentral`, 2026-08-15) |

The `slimeos-power` service (see `brain/power/`) auto-deallocates the VM after 20 minutes idle and wakes it on connect, so real-world cost is well below the 24/7 figures above for either SKU — the ~2x ratio between GPU and non-GPU holds regardless.

Stop the VM when not in use to save cost:
```bash
az vm deallocate --resource-group slimeos-windows --name slimeos-windows
az vm start     --resource-group slimeos-windows --name slimeos-windows
```

---

## Architecture notes

- **No public RDP:** NSG has zero inbound rules. RDP is only reachable via the WireGuard tunnel.
- **Windows activation:** Handled by Azure KMS automatically — no retail key needed on Azure.
- **Retail key use case:** Needed for non-Azure providers (bare metal, Vultr custom ISO, etc.) that don't include a Windows license.
- **Linux desktop alternative:** The Brain's Docker stack already includes an Ubuntu/XFCE desktop via xRDP at `10.11.0.10` — no Azure VM needed for the Linux path.

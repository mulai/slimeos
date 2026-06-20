# Windows Cloud Desktop on Azure

This guide sets up a **Windows 11 Pro cloud desktop** on Azure, reachable from any Slime OS client via WireGuard. No RDP port is ever exposed to the public internet.

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

# Resource group (Southeast Asia — adjust region as needed)
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

## Cost reference (Southeast Asia, June 2026)

| Setup | Cost |
|---|---|
| Standard_D2s_v3, Windows, pay-as-you-go 24/7 | ~$140/month |
| Standard_D2s_v3, Windows, 1-year reserved | ~$85/month |
| Auto stop/start (8 hrs/day only) | ~$45/month |

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

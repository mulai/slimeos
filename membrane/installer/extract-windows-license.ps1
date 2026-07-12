# Slime OS - Windows License Extractor
# Run this on the machine BEFORE installing Slime OS (before the disk is wiped).
# Saves key info to C:\slimeos-license.json
# Run as Administrator in PowerShell:
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
#   .\extract-windows-license.ps1

#Requires -RunAsAdministrator

$outFile = "C:\slimeos-license.json"

Write-Host ""
Write-Host "  Slime OS - Windows License Extractor" -ForegroundColor Cyan
Write-Host "  ======================================" -ForegroundColor Cyan
Write-Host ""

# --- Retrieve product key from firmware / registry ---
function Get-OEMKey {
    try {
        $key = (Get-WmiObject -query 'select * from SoftwareLicensingService').OA3xOriginalProductKey
        return $key
    } catch { return $null }
}

function Get-SoftwareKey {
    try {
        $map = "BCDFGHJKMPQRTVWXY2346789"
        $raw = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion").DigitalProductId
        if (-not $raw) { return $null }
        $keyOffset = 52
        $keyOutput = ""
        $isWin8Plus = [math]::Floor(($raw[66] / 6)) -band 1
        $raw[66] = ($raw[66] -band 0xF7) -bor (($isWin8Plus -band 2) * 4)
        for ($i = 24; $i -ge 0; $i--) {
            $current = 0
            for ($j = 14; $j -ge 0; $j--) {
                $current = $current * 256 -bxor $raw[$j + $keyOffset]
                $raw[$j + $keyOffset] = [math]::Floor($current / 24)
                $current = $current % 24
            }
            $keyOutput = $map[$current] + $keyOutput
            if ($i % 5 -eq 0 -and $i -ne 0) { $keyOutput = "-" + $keyOutput }
        }
        return $keyOutput
    } catch { return $null }
}

# --- License type detection ---
function Get-LicenseType {
    try {
        $sl = Get-WmiObject -Class SoftwareLicensingProduct |
              Where-Object { $_.PartialProductKey -and $_.Name -like "*Windows*" } |
              Select-Object -First 1
        switch ($sl.LicenseStatus) {
            1 { $status = "Licensed" }
            2 { $status = "OOBGrace" }
            3 { $status = "OOTGrace" }
            4 { $status = "NonGenuineGrace" }
            5 { $status = "Notification" }
            6 { $status = "ExtendedGrace" }
            default { $status = "Unknown($($sl.LicenseStatus))" }
        }
        $channel = if ($sl.Description -match "OEM") { "OEM" }
                   elseif ($sl.Description -match "VOLUME|MAK|KMS") { "Volume" }
                   elseif ($sl.Description -match "Retail") { "Retail" }
                   else { "Unknown" }
        return @{ Status = $status; Channel = $channel; Description = $sl.Description; PartialKey = $sl.PartialProductKey }
    } catch { return @{ Status = "Error"; Channel = "Unknown" } }
}

# --- Hardware fingerprint for BYOL mapping ---
function Get-HardwareId {
    $cpu  = (Get-WmiObject Win32_Processor | Select-Object -First 1).ProcessorId.Trim()
    $mb   = (Get-WmiObject Win32_BaseBoard).SerialNumber.Trim()
    $disk = (Get-WmiObject Win32_DiskDrive | Select-Object -First 1).SerialNumber.Trim()
    $raw  = "$cpu|$mb|$disk"
    $sha  = [System.Security.Cryptography.SHA256]::Create()
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    return ([System.BitConverter]::ToString($sha.ComputeHash($bytes)) -replace '-','').Substring(0,16).ToLower()
}

# --- Collect ---
Write-Host "  Detecting license..." -ForegroundColor Yellow
$oemKey  = Get-OEMKey
$swKey   = Get-SoftwareKey
$licInfo = Get-LicenseType
$hwId    = Get-HardwareId

$productKey = if ($oemKey -and $oemKey.Length -eq 29) { $oemKey }
              elseif ($swKey -and $swKey.Length -eq 29) { $swKey }
              else { $null }

$sys = Get-WmiObject Win32_ComputerSystem
$os  = Get-WmiObject Win32_OperatingSystem

$payload = @{
    slimeos_version   = "1.0"
    extracted_at      = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    hardware_id       = $hwId
    machine           = @{
        manufacturer  = $sys.Manufacturer
        model         = $sys.Model
        total_ram_mb  = [math]::Round($sys.TotalPhysicalMemory / 1MB)
        cpu           = (Get-WmiObject Win32_Processor | Select-Object -First 1).Name.Trim()
    }
    windows           = @{
        edition       = $os.Caption
        version       = $os.Version
        build         = $os.BuildNumber
        architecture  = $os.OSArchitecture
        license_channel = $licInfo.Channel
        license_status  = $licInfo.Status
        partial_key   = $licInfo.PartialKey
    }
    product_key       = $productKey
    key_source        = if ($oemKey) { "firmware_oa3" } elseif ($swKey) { "registry" } else { "not_found" }
    transferable      = ($licInfo.Channel -eq "Retail" -or $licInfo.Channel -eq "Volume")
    cloud_path        = if ($licInfo.Channel -eq "Retail" -or $licInfo.Channel -eq "Volume") {
                            "windows_cloud_vm"
                        } else {
                            "linux_cloud_vm_free"
                        }
}

# --- Output ---
$json = $payload | ConvertTo-Json -Depth 5
$json | Out-File -FilePath $outFile -Encoding utf8

Write-Host ""
Write-Host "  Results:" -ForegroundColor Green
Write-Host "  --------"
Write-Host "  Machine:      $($payload.machine.manufacturer) $($payload.machine.model)"
Write-Host "  CPU:          $($payload.machine.cpu)"
Write-Host "  RAM:          $($payload.machine.total_ram_mb) MB"
Write-Host "  Windows:      $($payload.windows.edition) ($($payload.windows.architecture))"
Write-Host "  License:      $($payload.windows.license_channel) - $($payload.windows.license_status)"
Write-Host "  Key found:    $(if ($productKey) { 'YES (' + $payload.key_source + ')' } else { 'NO' })"
Write-Host "  Transferable: $(if ($payload.transferable) { 'YES - Cloud Windows VM will be provisioned' } else { 'NO - Free Linux cloud VM will be provisioned' })"
Write-Host "  Hardware ID:  $($payload.hardware_id)"
Write-Host ""

if ($productKey) {
    Write-Host "  Product Key:  $productKey" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  *** IMPORTANT: Photograph or write down this key! ***" -ForegroundColor Yellow
    Write-Host "  *** The disk will be wiped during Slime OS install. ***" -ForegroundColor Yellow
} else {
    Write-Host "  No transferable key found." -ForegroundColor Yellow
    Write-Host "  A free Linux cloud desktop will be provisioned." -ForegroundColor Yellow
}

Write-Host ""
Write-Host "  Saved to: $outFile" -ForegroundColor Green
Write-Host "  Copy this file to a USB drive before proceeding with installation." -ForegroundColor Green
Write-Host ""

# --- Pause so the window stays open ---
Write-Host "  Press any key to exit..." -ForegroundColor DarkGray
$null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")

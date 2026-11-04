# The Windows app as an MSIX package for the Microsoft Store, from a finished
# `tauri build` (the app and its two helpers in src-tauri/target/release).
#
#   ./package-msix.ps1 -Version 0.2.0 -Out dist [-TestSign]
#
# The Store signs what it publishes, so Slime-OS.msix goes up unsigned.
# -TestSign also makes Slime-OS-test.msix, signed with a throwaway
# certificate (Slime-OS-test.cer) to install on a test PC: import the .cer
# into Local Machine > Trusted People first, then open the .msix.
#
# Identity comes from Partner Center (Product identity), through the
# MSIX_NAME, MSIX_PUBLISHER and MSIX_PUBLISHER_DISPLAY environment
# variables; without them, a test identity. Needs makeappx and signtool
# (the Windows SDK, on PATH in a Developer PowerShell).
param(
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Out,
    [switch]$TestSign
)
$ErrorActionPreference = 'Stop'
$app = $PSScriptRoot
$release = Join-Path $app 'src-tauri\target\release'

$name = if ($env:MSIX_NAME) { $env:MSIX_NAME } else { 'SlimeOS.Test' }
$publisher = if ($env:MSIX_PUBLISHER) { $env:MSIX_PUBLISHER } else { 'CN=Slime OS Test' }
$publisherDisplay = if ($env:MSIX_PUBLISHER_DISPLAY) { $env:MSIX_PUBLISHER_DISPLAY } else { 'Mulai' }
# The Store wants four parts, the last one 0 (it keeps that one for itself).
$v = ($Version -split '\.') + @('0', '0', '0') | Select-Object -First 3
$msixVersion = ($v -join '.') + '.0'

$layout = Join-Path ([IO.Path]::GetTempPath()) 'slimeos-msix-layout'
Remove-Item -Recurse -Force $layout -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force (Join-Path $layout 'Assets') | Out-Null
foreach ($exe in 'slimeos-desktop.exe', 'slimeos-desktop-core.exe', 'slimeos-rdp.exe') {
    Copy-Item (Join-Path $release $exe) $layout
}
foreach ($logo in 'Square150x150Logo', 'Square44x44Logo', 'StoreLogo') {
    Copy-Item (Join-Path $app "src-tauri\icons\$logo.png") (Join-Path $layout 'Assets')
}
(Get-Content -Raw (Join-Path $app 'msix\AppxManifest.xml')).
    Replace('{{NAME}}', $name).
    Replace('{{PUBLISHER}}', [Security.SecurityElement]::Escape($publisher)).
    Replace('{{PUBLISHER_DISPLAY}}', [Security.SecurityElement]::Escape($publisherDisplay)).
    Replace('{{VERSION}}', $msixVersion) |
    Set-Content -Encoding utf8 (Join-Path $layout 'AppxManifest.xml')

New-Item -ItemType Directory -Force $Out | Out-Null
$msix = Join-Path $Out 'Slime-OS.msix'
makeappx pack /o /d $layout /p $msix
if ($LASTEXITCODE) { throw "makeappx failed ($LASTEXITCODE)" }
Write-Host "built $msix ($name $msixVersion, $publisher)"

if ($TestSign) {
    $cert = New-SelfSignedCertificate -Type CodeSigningCert -Subject $publisher `
        -CertStoreLocation Cert:\CurrentUser\My -NotAfter (Get-Date).AddYears(1) `
        -TextExtension @('2.5.29.19={text}')
    $test = Join-Path $Out 'Slime-OS-test.msix'
    Copy-Item $msix $test
    signtool sign /fd SHA256 /sha1 $cert.Thumbprint $test
    if ($LASTEXITCODE) { throw "signtool failed ($LASTEXITCODE)" }
    Export-Certificate -Cert $cert -FilePath (Join-Path $Out 'Slime-OS-test.cer') | Out-Null
    Remove-Item $cert.PSPath
    Write-Host "built $test, signed with a test certificate"
}

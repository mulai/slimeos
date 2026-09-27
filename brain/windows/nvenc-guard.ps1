# Slime OS NVENC guard for Windows GPU Brains.
#
# NVIDIA's H.264 encoder (nvEncMFTH264x.dll, driver 574.24 on Azure NVadsA10_v5)
# crashes the Remote Desktop service (use-after-free, ntdll+0xfa7d) and can hang a
# session. Hardware encoding stays the default: a crash switches to software, the
# next start-up (or 4 am check) tries hardware again; after MaxStrikes crashes on one driver it
# stays on software until Azure installs a different driver.
#
#   -Trigger Crash  (task: Remote Desktop service crashed) hardware encoding on ->
#                   turn it off, one strike for this driver
#   -Trigger Hang   (hub, just before it restarts a Brain whose session froze) same
#                   as Crash, and the start-up that follows keeps software encoding
#   -Trigger Check  (task: at startup and daily) guard turned it off and the driver
#                   hasn't used up its strikes -> turn it back on
#   no -Trigger     install: copy to C:\ProgramData\SlimeOS, register both tasks and
#                   apply the GPU Brain baseline (idempotent; rerun after a rebuild)
#
# Install from the maintainer's Mac:
#   az vm run-command invoke -g <rg> -n <vm> --command-id RunPowerShellScript \
#     --scripts @brain/windows/nvenc-guard.ps1
#
# Override (HKLM\SOFTWARE\SlimeOS\NvencGuard, Mode): Auto (default), On or Off.
# State lives next to it: BadDrivers (strikes used up), StrikeDriver and Strikes
# (count for the current driver), OffByGuard. Log: C:\ProgramData\SlimeOS\
# nvenc-guard.log and the Application event log (source SlimeOS-NvencGuard).

param([ValidateSet('Install', 'Crash', 'Hang', 'Check')][string]$Trigger = 'Install')

$ErrorActionPreference = 'Stop'
$Dir = 'C:\ProgramData\SlimeOS'
$Self = Join-Path $Dir 'nvenc-guard.ps1'
$LogFile = Join-Path $Dir 'nvenc-guard.log'
$StateKey = 'HKLM:\SOFTWARE\SlimeOS\NvencGuard'
$TsKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\Terminal Services'
$Source = 'SlimeOS-NvencGuard'
$MaxStrikes = 3

function Log([string]$msg, [int]$id = 1, [string]$type = 'Information') {
    New-Item -ItemType Directory -Force -Path $Dir | Out-Null
    Add-Content -Path $LogFile -Value ('{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Trigger, $msg)
    try { Write-EventLog -LogName Application -Source $Source -EventId $id -EntryType $type -Message $msg } catch { }
    Write-Output $msg
}

function Get-DriverVersion {
    $smi = Join-Path $env:SystemRoot 'System32\nvidia-smi.exe'
    if (Test-Path $smi) {
        $v = (& $smi --query-gpu=driver_version --format=csv,noheader 2>$null | Select-Object -First 1)
        if ($v) { return $v.Trim() }
    }
    $gpu = Get-CimInstance Win32_VideoController | Where-Object { $_.Name -match 'NVIDIA' } | Select-Object -First 1
    if ($gpu) { return $gpu.DriverVersion }
    return $null
}

function Get-State {
    if (-not (Test-Path $StateKey)) { New-Item -Path $StateKey -Force | Out-Null }
    $p = Get-ItemProperty $StateKey
    [pscustomobject]@{
        Mode       = if ($p.Mode) { $p.Mode } else { 'Auto' }
        BadDrivers = @($p.BadDrivers | Where-Object { $_ })
        OffByGuard = [bool]$p.OffByGuard
        StrikeDriver = $p.StrikeDriver
        Strikes    = [int]$p.Strikes
        SkipNextCheck = [bool]$p.SkipNextCheck
    }
}

function Get-HwEncode { [int](Get-ItemProperty $TsKey -ErrorAction SilentlyContinue).AVCHardwareEncodePreferred }

function Set-HwEncode([int]$on) {
    if (-not (Test-Path $TsKey)) { New-Item -Path $TsKey -Force | Out-Null }
    Set-ItemProperty $TsKey -Name AVCHardwareEncodePreferred -Value $on -Type DWord
}

# The encoder is chosen when a connection starts; a restart of the service makes sure
# the new value is used. Only when nobody is connected: restarting drops every session.
function Restart-RdpIfIdle {
    if ((qwinsta 2>$null) -match '\sActive\s') {
        return 'someone is connected, so it applies from the next connection or restart'
    }
    Restart-Service TermService -Force
    return 'Remote Desktop service restarted (nobody was connected)'
}

switch ($Trigger) {
    'Install' {
        New-Item -ItemType Directory -Force -Path $Dir | Out-Null
        $src = if ($PSCommandPath) { Get-Content -Raw $PSCommandPath } else { $MyInvocation.MyCommand.ScriptBlock.ToString() }
        Set-Content -Path $Self -Value $src -Encoding UTF8
        if (-not [System.Diagnostics.EventLog]::SourceExists($Source)) {
            New-EventLog -LogName Application -Source $Source
        }

        # GPU Brain baseline (each of these was lost once in a rebuild).
        if (-not (Test-Path $TsKey)) { New-Item -Path $TsKey -Force | Out-Null }
        Set-ItemProperty $TsKey -Name AVC444ModePreferred -Value 1 -Type DWord
        Set-ItemProperty $TsKey -Name bEnumerateHWBeforeSW -Value 1 -Type DWord
        if ($null -eq (Get-ItemProperty $TsKey).AVCHardwareEncodePreferred) { Set-HwEncode 1 }
        & sc.exe failure TermService reset= 86400 actions= restart/1000/restart/1000/restart/1000 | Out-Null
        $wer = 'HKLM:\SOFTWARE\Microsoft\Windows\Windows Error Reporting\LocalDumps\svchost.exe'
        New-Item -Path $wer -Force | Out-Null
        Set-ItemProperty $wer -Name DumpFolder -Value 'C:\CrashDumps' -Type ExpandString
        Set-ItemProperty $wer -Name DumpType -Value 1 -Type DWord   # minidump: a full one froze sessions for up to 36 s
        Set-ItemProperty $wer -Name DumpCount -Value 3 -Type DWord

        # Hardware encoding already off on a known-bad driver (the 2026-09-28 manual
        # switch-off): adopt it, so a new driver turns it back on.
        $state = Get-State
        $drv = Get-DriverVersion
        if ((Get-HwEncode) -eq 0 -and $drv -and -not $state.OffByGuard) {
            Set-ItemProperty $StateKey -Name BadDrivers -Value ([string[]]($state.BadDrivers + $drv | Select-Object -Unique)) -Type MultiString
            Set-ItemProperty $StateKey -Name OffByGuard -Value 1 -Type DWord
            Set-ItemProperty $StateKey -Name StrikeDriver -Value "$drv"
            Set-ItemProperty $StateKey -Name Strikes -Value $MaxStrikes -Type DWord
        }

        $run = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Trigger ' -f $Self
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

        $class = Get-CimClass -ClassName MSFT_TaskEventTrigger -Namespace Root/Microsoft/Windows/TaskScheduler
        $crash = New-CimInstance -CimClass $class -ClientOnly
        $crash.Enabled = $true
        $crash.Subscription = '<QueryList><Query Id="0" Path="Application"><Select Path="Application">' +
            "*[System[Provider[@Name='Application Error'] and EventID=1000]] and *[EventData[Data='svchost.exe_TermService']]" +
            '</Select></Query></QueryList>'
        Register-ScheduledTask -TaskName 'SlimeOS NVENC guard (crash)' -Force -Principal $principal -Settings $settings `
            -Trigger $crash -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($run + 'Crash')) | Out-Null

        $check = @((New-ScheduledTaskTrigger -AtStartup), (New-ScheduledTaskTrigger -Daily -At 4am))
        Register-ScheduledTask -TaskName 'SlimeOS NVENC guard (check)' -Force -Principal $principal -Settings $settings `
            -Trigger $check -Action (New-ScheduledTaskAction -Execute 'powershell.exe' -Argument ($run + 'Check')) | Out-Null

        $state = Get-State
        Log ("Installed. Driver {0}, hardware encoding {1}, mode {2}, bad drivers [{3}]." -f `
            $drv, @('off', 'on')[(Get-HwEncode)], $state.Mode, ($state.BadDrivers -join ', '))
    }

    { $_ -in 'Crash', 'Hang' } {
        $state = Get-State
        $drv = Get-DriverVersion
        $hw = Get-HwEncode
        $what = @{ Crash = 'Remote Desktop service crashed'; Hang = 'Session froze (Brain restart requested)' }[$Trigger]
        if ($Trigger -eq 'Hang') {
            # The restart is to clear the hung session, not to retry hardware encoding.
            Set-ItemProperty $StateKey -Name SkipNextCheck -Value 1 -Type DWord
        }
        if ($state.Mode -ne 'Auto') { Log "$what; mode is $($state.Mode), leaving hardware encoding as is." 2 Warning; break }
        if ($hw -ne 1) { Log "$what with hardware encoding already off (driver $drv): not the NVENC bug." 3 Warning; break }
        Set-HwEncode 0
        Set-ItemProperty $StateKey -Name OffByGuard -Value 1 -Type DWord
        $strikes = if ($state.StrikeDriver -eq $drv) { $state.Strikes + 1 } else { 1 }
        Set-ItemProperty $StateKey -Name StrikeDriver -Value "$drv"
        Set-ItemProperty $StateKey -Name Strikes -Value $strikes -Type DWord
        $until = 'the next start-up or 4 am check'
        if ($strikes -ge $MaxStrikes) {
            Set-ItemProperty $StateKey -Name BadDrivers -Value ([string[]]($state.BadDrivers + $drv | Select-Object -Unique)) -Type MultiString
            $until = 'Azure installs a different driver'
        }
        if ($Trigger -eq 'Hang') {
            Log ("$what with hardware encoding on (driver {0}, strike {1} of {2}): software until {3}, after the restart." -f `
                $drv, $strikes, $MaxStrikes, $until) 12 Warning
            break
        }
        Start-Sleep -Seconds 5   # let the service's own 1 s restart finish first
        Log ("$what with hardware encoding on (driver {0}, strike {1} of {2}): software until {3}; {4}." -f `
            $drv, $strikes, $MaxStrikes, $until, (Restart-RdpIfIdle)) 10 Warning
    }

    'Check' {
        $state = Get-State
        $drv = Get-DriverVersion
        $hw = Get-HwEncode
        if ($state.SkipNextCheck) {
            Set-ItemProperty $StateKey -Name SkipNextCheck -Value 0 -Type DWord
            Log "Start-up after a frozen-session restart: keeping hardware encoding $(@('off', 'on')[$hw]) until the next check."
            break
        }
        switch ($state.Mode) {
            'On' { if ($hw -ne 1) { Set-HwEncode 1; Log "Mode On: hardware encoding on; $(Restart-RdpIfIdle)." 20 } }
            'Off' { if ($hw -ne 0) { Set-HwEncode 0; Log "Mode Off: hardware encoding off; $(Restart-RdpIfIdle)." 21 } }
            default {
                if ($hw -eq 0 -and $state.OffByGuard -and $drv -and ($state.BadDrivers -notcontains $drv)) {
                    Set-HwEncode 1
                    Set-ItemProperty $StateKey -Name OffByGuard -Value 0 -Type DWord
                    $strikes = if ($state.StrikeDriver -eq $drv) { $state.Strikes } else { 0 }
                    Log ("Driver {0} ({1} of {2} strikes used): hardware encoding back on; {3}." -f `
                        $drv, $strikes, $MaxStrikes, (Restart-RdpIfIdle)) 11
                }
            }
        }
    }
}

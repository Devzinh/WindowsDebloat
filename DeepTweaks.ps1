# Deep (aggressive) tweaks - dot-sourced by Invoke-WindowsDebloat.ps1
# Relies on: Invoke-TweakStep, Set-RegistryDwordWithBackup, Set-RegistryPropertyWithBackup,
# Set-ServiceStartWithBackup, Set-HighPerformancePowerPlanWithBackup, Set-HibernateOffWithBackup,
# Set-OptionalWindowsFeatureStateWithBackup

function Invoke-DeepServiceToMode {
    param(
        [Parameter(Mandatory)][string]$ServiceName,
        [Parameter(Mandatory)][ValidateSet('Disabled', 'Manual', 'Automatic')][string]$StartupType,
        [Parameter(Mandatory)][string]$ChangeId,
        [Parameter(Mandatory)][string]$Label
    )
    Invoke-TweakStep -Label $Label -Action {
        if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) { return }
        Set-ServiceStartWithBackup -ServiceName $ServiceName -NewStartMode $StartupType -ChangeId $ChangeId
    } | Out-Null
}

function Set-DeepPerformanceTweaks {
    Write-Host '--- Deep: performance / visual / power ---' -ForegroundColor Magenta

    Invoke-TweakStep -Label 'Visual effects: Adjust for best performance (user)' -Action {
        Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VisualEffects' -Name 'VisualFXSetting' -Value 2 -ChangeId 'deep-visualeffects-user'
    } | Out-Null

    Invoke-TweakStep -Label 'Desktop: MenuShowDelay low' -Action {
        Set-RegistryPropertyWithBackup -Path 'HKCU:\Control Panel\Desktop' -Name 'MenuShowDelay' -Value '0' -PropertyType String -ChangeId 'deep-menushowdelay'
    } | Out-Null

    Invoke-TweakStep -Label 'Explorer: disable minimize/restore animations' -Action {
        Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Animations' -Value 0 -ChangeId 'deep-explorer-animations'
    } | Out-Null

    Invoke-TweakStep -Label 'Themes: disable transparency' -Action {
        Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name 'EnableTransparency' -Value 0 -ChangeId 'deep-transparency-off'
    } | Out-Null

    Invoke-TweakStep -Label 'Power: Fast Startup off (HiberbootEnabled)' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power' -Name 'HiberbootEnabled' -Value 0 -ChangeId 'deep-faststartup-off'
    } | Out-Null

    Invoke-TweakStep -Label 'Power plan: High performance' -Action {
        Set-HighPerformancePowerPlanWithBackup -ChangeId 'deep-powerplan-highperf'
    } | Out-Null

    Invoke-TweakStep -Label 'Power: hibernate off' -Action {
        Set-HibernateOffWithBackup -ChangeId 'deep-hibernate-off'
    } | Out-Null

    Invoke-DeepServiceToMode -ServiceName 'SysMain' -StartupType Disabled -ChangeId 'deep-svc-sysmain' -Label 'Service SysMain (Superfetch) -> Disabled'
    Invoke-DeepServiceToMode -ServiceName 'WSearch' -StartupType Disabled -ChangeId 'deep-svc-wsearch' -Label 'Service WSearch (Windows Search) -> Disabled'
    Invoke-DeepServiceToMode -ServiceName 'Fax' -StartupType Disabled -ChangeId 'deep-svc-fax' -Label 'Service Fax -> Disabled'
    Invoke-DeepServiceToMode -ServiceName 'RemoteRegistry' -StartupType Disabled -ChangeId 'deep-svc-remoteregistry' -Label 'Service RemoteRegistry -> Disabled'

    Write-Host 'Deep performance tweaks pass finished (see warnings for any skipped steps).' -ForegroundColor Green
}

function Set-DeepGamingTweaks {
    Write-Host '--- Deep: gaming ---' -ForegroundColor Magenta

    Invoke-TweakStep -Label 'Game DVR: AppCaptureEnabled off (user)' -Action {
        Set-RegistryDwordWithBackup -Path 'HKCU:\System\GameConfigStore' -Name 'AppCaptureEnabled' -Value 0 -ChangeId 'deep-game-appcapture'
    } | Out-Null

    Invoke-TweakStep -Label 'Game DVR: allow GameDVR policy off' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\GameDVR' -Name 'AllowGameDVR' -Value 0 -ChangeId 'deep-game-allowgamedvr-pol'
    } | Out-Null

    Invoke-TweakStep -Label 'Game Bar: AutoGameMode / AllowAutoGameMode' -Action {
        Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AutoGameModeEnabled' -Value 1 -ChangeId 'deep-game-autogamemode'
        Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'AllowAutoGameMode' -Value 1 -ChangeId 'deep-game-allowautogamemode'
    } | Out-Null

    Invoke-TweakStep -Label 'Game Bar: show startup panel off' -Action {
        Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\GameBar' -Name 'ShowStartupPanel' -Value 0 -ChangeId 'deep-game-showstartup-off'
    } | Out-Null

    Invoke-TweakStep -Label 'Mouse: disable pointer precision (rough default)' -Action {
        Set-RegistryPropertyWithBackup -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseSpeed' -Value '0' -PropertyType String -ChangeId 'deep-mouse-speed'
        Set-RegistryPropertyWithBackup -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold1' -Value '0' -PropertyType String -ChangeId 'deep-mouse-thresh1'
        Set-RegistryPropertyWithBackup -Path 'HKCU:\Control Panel\Mouse' -Name 'MouseThreshold2' -Value '0' -PropertyType String -ChangeId 'deep-mouse-thresh2'
    } | Out-Null

    $build = [System.Environment]::OSVersion.Version.Build
    if ($build -ge 19041) {
        Invoke-TweakStep -Label 'GPU: Hardware-accelerated GPU scheduling (HwSchMode)' -Action {
            Set-RegistryDwordWithBackup -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\GraphicsDrivers' -Name 'HwSchMode' -Value 2 -ChangeId 'deep-gpu-hwschmode'
        } | Out-Null
    }

    Write-Host 'Deep gaming tweaks pass finished (reboot may be required for GPU scheduling).' -ForegroundColor Green
}

function Set-DeepNetworkTweaks {
    Write-Host '--- Deep: network / latency ---' -ForegroundColor Magenta

    Invoke-TweakStep -Label 'Multimedia: NetworkThrottlingIndex off' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'NetworkThrottlingIndex' -Value -1 -ChangeId 'deep-net-throttleidx'
    } | Out-Null

    Invoke-TweakStep -Label 'Multimedia: SystemResponsiveness (foreground bias)' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Multimedia\SystemProfile' -Name 'SystemResponsiveness' -Value 10 -ChangeId 'deep-net-sysresp'
    } | Out-Null

    Invoke-TweakStep -Label 'DNS: disable LLMNR / multicast (policy)' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows NT\DNSClient' -Name 'EnableMulticast' -Value 0 -ChangeId 'deep-net-llmnr-pol'
        Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DNSClient' -Name 'EnableMulticast' -Value 0 -ChangeId 'deep-net-llmnr-pol2'
    } | Out-Null

    Invoke-TweakStep -Label 'DNS Client: EnableMulticast off' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Dnscache\Parameters' -Name 'EnableMulticast' -Value 0 -ChangeId 'deep-net-multicast-dns'
    } | Out-Null

    Invoke-TweakStep -Label 'Delivery Optimization: LAN-only (limit P2P Internet)' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization' -Name 'DODownloadMode' -Value 1 -ChangeId 'deep-net-domode'
    } | Out-Null

    Invoke-TweakStep -Label 'TCP/IP interfaces: TcpAckFrequency / TCPNoDelay / TcpDelAckTicks' -Action {
        $ifaceRoot = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters\Interfaces'
        if (-not (Test-Path -LiteralPath $ifaceRoot)) { return }
        Get-ChildItem -LiteralPath $ifaceRoot -ErrorAction SilentlyContinue | ForEach-Object {
            $p = $_.PSPath
            $g = $_.PSChildName
            try {
                Set-RegistryDwordWithBackup -Path $p -Name 'TcpAckFrequency' -Value 1 -ChangeId ('deep-net-tcpack-{0}' -f $g)
            } catch { }
            try {
                Set-RegistryDwordWithBackup -Path $p -Name 'TCPNoDelay' -Value 1 -ChangeId ('deep-net-nodelay-{0}' -f $g)
            } catch { }
            try {
                Set-RegistryDwordWithBackup -Path $p -Name 'TcpDelAckTicks' -Value 0 -ChangeId ('deep-net-delack-{0}' -f $g)
            } catch { }
        }
    } | Out-Null

    Write-Host 'Deep network tweaks pass finished (reboot recommended).' -ForegroundColor Green
}

function Set-DeepPrivacyExtraTweaks {
    Write-Host '--- Deep: privacy (extra) ---' -ForegroundColor Magenta

    Invoke-TweakStep -Label 'Cortana / Search: disallow Cortana (policy)' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'AllowCortana' -Value 0 -ChangeId 'deep-priv-cortana-pol'
    } | Out-Null

    Invoke-TweakStep -Label 'Search: disable web search suggestions (policy)' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Search' -Name 'ConnectedSearchUseWeb' -Value 0 -ChangeId 'deep-priv-searchweb-pol'
    } | Out-Null

    Invoke-TweakStep -Label 'Widgets / Taskbar feeds: TaskbarDa off' -Action {
        Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarDa' -Value 0 -ChangeId 'deep-priv-taskbarda'
    } | Out-Null

    Invoke-TweakStep -Label 'CEIP / SQM: opt out' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Microsoft\SQMClient\Windows' -Name 'CEIPEnable' -Value 0 -ChangeId 'deep-priv-ceip'
    } | Out-Null

    Invoke-TweakStep -Label 'Windows Error Reporting: disabled (policy)' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Windows Error Reporting' -Name 'Disabled' -Value 1 -ChangeId 'deep-priv-wer-pol'
    } | Out-Null

    Invoke-TweakStep -Label 'Feedback notifications silenced (policy)' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'DoNotShowFeedbackNotifications' -Value 1 -ChangeId 'deep-priv-feedbacknotif'
    } | Out-Null

    Write-Host 'Deep privacy (extra) pass finished.' -ForegroundColor Green
}

function Set-DeepSecurityHardening {
    Write-Host '--- Deep: security hardening ---' -ForegroundColor Magenta
    Write-Host 'WARNING: disables SMBv1 (if present), hardens AutoRun/WSH, Remote Assistance, and INCOMING Remote Desktop.' -ForegroundColor Yellow

    Invoke-TweakStep -Label 'SMBv1: disable optional feature' -Action {
        Set-OptionalWindowsFeatureStateWithBackup -FeatureName 'SMB1Protocol' -DesiredState Disabled -ChangeId 'deep-sec-smb1-off'
    } | Out-Null

    Invoke-TweakStep -Label 'Explorer policy: NoDriveTypeAutoRun (255)' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name 'NoDriveTypeAutoRun' -Value 255 -ChangeId 'deep-sec-autorun'
    } | Out-Null

    Invoke-TweakStep -Label 'Windows Script Host: disable (HKLM)' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Microsoft\Windows Script Host\Settings' -Name 'Enabled' -Value 0 -ChangeId 'deep-sec-wsh'
    } | Out-Null

    Invoke-TweakStep -Label 'Remote Assistance: deny' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Remote Assistance' -Name 'fAllowToGetHelp' -Value 0 -ChangeId 'deep-sec-remoteassist'
    } | Out-Null

    Invoke-TweakStep -Label 'Remote Desktop: deny incoming connections (fDenyTSConnections)' -Action {
        Set-RegistryDwordWithBackup -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' -Name 'fDenyTSConnections' -Value 1 -ChangeId 'deep-sec-rdp-deny'
    } | Out-Null

    Write-Host 'Deep security hardening pass finished.' -ForegroundColor Green
}

function Invoke-AllDeepTweaks {
    Write-Host 'This runs ALL deep tweak passes (DP, DG, DN, DV, DS). Some changes require a reboot.' -ForegroundColor Yellow
    $c = (Read-Host 'Continue? (y/N)').Trim()
    if ($c -ne 'y') { return }
    Set-DeepPerformanceTweaks
    Set-DeepGamingTweaks
    Set-DeepNetworkTweaks
    Set-DeepPrivacyExtraTweaks
    Set-DeepSecurityHardening
    Write-Host 'All deep tweak passes invoked. Review session backup JSON to revert.' -ForegroundColor Green
}

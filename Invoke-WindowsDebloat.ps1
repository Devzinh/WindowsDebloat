Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Continue'

function Test-IsAdministrator {
    $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Ensure-ElevatedSession {
    if (Test-IsAdministrator) { return }

    $scriptPath = if ($PSCommandPath) { $PSCommandPath } else { $MyInvocation.MyCommand.Path }
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        throw "Unable to determine script path for elevation. Run this script using -File."
    }

    $hostExe = (Get-Process -Id $PID).Path
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`""

    Write-Host "Administrator rights are required. Requesting UAC elevation..." -ForegroundColor Yellow
    try {
        Start-Process -FilePath $hostExe -ArgumentList $args -Verb RunAs -ErrorAction Stop | Out-Null
        Write-Host "A new elevated PowerShell window was opened. Continue there." -ForegroundColor Green
        exit
    } catch {
        Write-Error "Elevation was canceled or failed. Please run PowerShell as Administrator and try again."
        exit 1
    }
}

Ensure-ElevatedSession

$Script:RootDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Script:BackupDir = Join-Path $Script:RootDir 'backups'
$Script:SessionBackup = $null
$Script:SessionChanges = [System.Collections.Generic.List[object]]::new()

function Get-ChangeProperty {
    param(
        [Parameter(Mandatory)]
        $Change,
        [Parameter(Mandatory)]
        [string]$PascalName
    )
    $names = @($Change.PSObject.Properties.Name)
    if ($names -contains $PascalName) {
        return $Change.$PascalName
    }
    $camelName = $PascalName.Substring(0, 1).ToLowerInvariant() + $PascalName.Substring(1)
    if ($names -contains $camelName) {
        return $Change.$camelName
    }
    return $null
}

function Initialize-BackupDir {
    if (-not (Test-Path -LiteralPath $Script:BackupDir)) {
        New-Item -ItemType Directory -Path $Script:BackupDir -Force | Out-Null
    }
}

function Initialize-SessionBackup {
    Initialize-BackupDir
    if ($null -ne $Script:SessionBackup) { return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Script:SessionBackup = Join-Path $Script:BackupDir "session-$stamp.json"
    Write-Host "Reversible changes this run are logged to: $Script:SessionBackup" -ForegroundColor DarkGray
}

function Save-SessionBackup {
    if (-not $Script:SessionBackup) { return }
    $payload = @{
        CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Computer   = $env:COMPUTERNAME
        User       = $env:USERNAME
        Changes    = @($Script:SessionChanges)
    }
    $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Script:SessionBackup -Encoding UTF8
}

function Add-ChangeRecord {
    param([hashtable]$Record)
    Initialize-SessionBackup
    $Script:SessionChanges.Add($Record)
    Save-SessionBackup
}

function Read-RegistryValueSafe {
    param(
        [string]$Path,
        [string]$Name
    )
    try {
        $v = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop
        return $v.$Name
    } catch {
        return $null
    }
}

function Set-RegistryDwordWithBackup {
    param(
        [string]$Path,
        [string]$Name,
        [int]$Value,
        [string]$ChangeId
    )
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
    }
    $prev = Read-RegistryValueSafe -Path $Path -Name $Name
    Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type DWord -Force -ErrorAction Stop
    Add-ChangeRecord @{
        Kind     = 'RegistryDWord'
        Id       = $ChangeId
        Path     = $Path
        Name     = $Name
        Previous = $prev
        New      = $Value
    }
}

function Set-ServiceStartWithBackup {
    param(
        [string]$ServiceName,
        [string]$NewStartMode,
        [string]$ChangeId
    )
    $svc = Get-Service -Name $ServiceName -ErrorAction Stop
    $prev = $svc.StartType.ToString()
    if ($svc.Status -eq 'Running' -and $NewStartMode -in @('Disabled', 'Manual')) {
        Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
    }
    Set-Service -Name $ServiceName -StartupType $NewStartMode -ErrorAction Stop
    Add-ChangeRecord @{
        Kind         = 'ServiceStartType'
        Id           = $ChangeId
        ServiceName  = $ServiceName
        Previous     = $prev
        New          = $NewStartMode
    }
}

function Invoke-TweakStep {
    param(
        [Parameter(Mandatory)]
        [string]$Label,
        [Parameter(Mandatory)]
        [scriptblock]$Action
    )
    try {
        & $Action
        return $true
    } catch {
        $msg = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($msg)) {
            $msg = $_.ToString()
        }
        Write-Warning "$Label failed: $msg"
        return $false
    }
}

function Invoke-ClassicContextMenuEnable {
    # Windows 11: restore legacy right-click menu
    $clsid = 'HKCU:\Software\Classes\clsid\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
    $base = Join-Path $clsid 'InprocServer32'
    $parentExisted = Test-Path -LiteralPath $clsid
    $inprocExisted = Test-Path -LiteralPath $base
    $prevDefault = $null
    if ($inprocExisted) {
        $prevDefault = (Get-ItemProperty -LiteralPath $base -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
    }
    if (-not $inprocExisted) {
        New-Item -Path $base -Force | Out-Null
    }
    Set-ItemProperty -LiteralPath $base -Name '(default)' -Value '' -Force
    Add-ChangeRecord @{
        Kind            = 'ClassicContextMenu'
        Id              = 'ui-classic-context-menu'
        ClsidPath       = $clsid
        InprocPath      = $base
        ParentExisted   = $parentExisted
        InprocExisted   = $inprocExisted
        PreviousDefault = $prevDefault
    }
}

function Get-BloatPackageNames {
    # Edit this list if you want to keep or remove specific apps. Intentionally excludes
    # Microsoft Teams, Outlook, Photos, Camera, Clock/Alarms, and Sticky Notes (many people rely on them).
    @(
        'Microsoft.BingNews',
        'Microsoft.BingWeather',
        'Microsoft.GetHelp',
        'Microsoft.Getstarted',
        'Microsoft.Microsoft3DViewer',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MixedReality.Portal',
        'Microsoft.People',
        'Microsoft.PowerAutomateDesktop',
        'Microsoft.SkypeApp',
        'Microsoft.WindowsFeedbackHub',
        'Microsoft.XboxApp',
        'Microsoft.XboxGameOverlay',
        'Microsoft.XboxGamingOverlay',
        'Microsoft.XboxIdentityProvider',
        'Microsoft.XboxSpeechToTextOverlay',
        'Microsoft.YourPhone',
        'Microsoft.ZuneMusic',
        'Microsoft.ZuneVideo',
        'Microsoft.WindowsMaps',
        'Microsoft.OneConnect',
        'Microsoft.Messaging',
        'Microsoft.BingFinance',
        'Microsoft.BingSports',
        'Microsoft.BingTravel',
        'Microsoft.Office.OneNote',
        'Microsoft.Todos',
        'Clipchamp.Clipchamp',
        'Microsoft.549981C3F5F10',
        'LinkedInforWindows'
    ) | Select-Object -Unique
}

function Remove-BloatwareForCurrentUser {
    $names = Get-BloatPackageNames
    $removed = [System.Collections.Generic.List[string]]::new()
    foreach ($n in $names) {
        $pkgs = Get-AppxPackage -Name $n -ErrorAction SilentlyContinue
        foreach ($p in $pkgs) {
            try {
                Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
                $removed.Add($p.PackageFullName)
            } catch {
                Write-Warning "Could not remove $($p.PackageFullName): $_"
            }
        }
    }
    if ($removed.Count -gt 0) {
        Add-ChangeRecord @{
            Kind            = 'RemovedAppxPackages'
            Id              = 'apps-removed-user'
            PackageFullNames = @($removed)
        }
    }
    Write-Host "Removed $($removed.Count) app package(s) for current user." -ForegroundColor Green
    Write-Host "Tip: To bring an app back, reinstall it from the Microsoft Store (or use winget)." -ForegroundColor DarkYellow
}

function Remove-BloatwareProvisioned {
    $names = Get-BloatPackageNames
    $removed = [System.Collections.Generic.List[string]]::new()
    $allProvisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
    foreach ($n in $names) {
        $prov = $allProvisioned | Where-Object { $_.DisplayName -eq $n }
        foreach ($p in $prov) {
            try {
                $null = Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop
                $removed.Add($p.PackageName)
            } catch {
                Write-Warning "Could not de-provision $($p.PackageName): $_"
            }
        }
    }
    if ($removed.Count -gt 0) {
        Add-ChangeRecord @{
            Kind         = 'RemovedProvisionedPackages'
            Id           = 'apps-removed-provisioned'
            PackageNames = @($removed)
        }
    }
    Write-Host "Removed $($removed.Count) provisioned package(s) (future user profiles)." -ForegroundColor Green
}

function Set-PrivacyTweaks {
    $ok = 0
    $failed = 0

    # Telemetry / data collection (policies)
    if (Invoke-TweakStep -Label 'Telemetry policy (HKLM Policy)' -Action {
            Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Value 0 -ChangeId 'privacy-telemetry-policy'
        }) { $ok++ } else { $failed++ }
    if (Invoke-TweakStep -Label 'Telemetry policy (HKLM CurrentVersion)' -Action {
            Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\DataCollection' -Name 'AllowTelemetry' -Value 0 -ChangeId 'privacy-telemetry-policy2'
        }) { $ok++ } else { $failed++ }

    # Advertising ID
    if (Invoke-TweakStep -Label 'Advertising ID' -Action {
            Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -Value 0 -ChangeId 'privacy-advertising-id'
        }) { $ok++ } else { $failed++ }

    # Tailored experiences
    if (Invoke-TweakStep -Label 'Tailored experiences' -Action {
            Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy' -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -Value 0 -ChangeId 'privacy-tailored-exp'
        }) { $ok++ } else { $failed++ }

    # Activity feed / sync (optional privacy)
    if (Invoke-TweakStep -Label 'Activity feed' -Action {
            Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'EnableActivityFeed' -Value 0 -ChangeId 'privacy-activity-feed'
        }) { $ok++ } else { $failed++ }
    if (Invoke-TweakStep -Label 'Publish user activities' -Action {
            Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'PublishUserActivities' -Value 0 -ChangeId 'privacy-publish-activities'
        }) { $ok++ } else { $failed++ }
    if (Invoke-TweakStep -Label 'Upload user activities' -Action {
            Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\System' -Name 'UploadUserActivities' -Value 0 -ChangeId 'privacy-upload-activities'
        }) { $ok++ } else { $failed++ }

    # Disable consumer features (optional)
    if (Invoke-TweakStep -Label 'Windows consumer features' -Action {
            Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Value 1 -ChangeId 'privacy-consumer-features'
        }) { $ok++ } else { $failed++ }

    # Services commonly associated with telemetry / push
    if (Invoke-TweakStep -Label 'Service DiagTrack' -Action {
            Set-ServiceStartWithBackup -ServiceName 'DiagTrack' -NewStartMode 'Disabled' -ChangeId 'svc-diagtrack'
        }) { $ok++ } else { $failed++ }
    if (Invoke-TweakStep -Label 'Service dmwappushservice' -Action {
            Set-ServiceStartWithBackup -ServiceName 'dmwappushservice' -NewStartMode 'Disabled' -ChangeId 'svc-dmwappush'
        }) { $ok++ } else { $failed++ }

    # Location: disable Windows Geolocation Service
    if (Invoke-TweakStep -Label 'Service lfsvc (Geolocation)' -Action {
            Set-ServiceStartWithBackup -ServiceName 'lfsvc' -NewStartMode 'Disabled' -ChangeId 'svc-lfsvc'
        }) { $ok++ } else { $failed++ }

    if ($failed -eq 0) {
        Write-Host "Privacy-related tweaks applied (with backups)." -ForegroundColor Green
    } else {
        Write-Host "Privacy tweaks completed with warnings. Success: $ok, Failed: $failed." -ForegroundColor Yellow
    }
}

function Set-UiTweaks {
    $build = [System.Environment]::OSVersion.Version.Build

    # Classic context menu (Windows 11 builds 22000+)
    if ($build -ge 22000) {
        Invoke-ClassicContextMenuEnable
    }

    # Hide "Recommended" in Start (Explorer policy - works on many Win11 builds)
    Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Policies\Microsoft\Windows\Explorer' -Name 'HideRecommendedSection' -Value 1 -ChangeId 'ui-hide-recommended'

    # Also try user Advanced key used on some builds
    Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'Start_IrisRecommendations' -Value 0 -ChangeId 'ui-start-iris-off'

    # Disable Copilot (Windows 11)
    if ($build -ge 22000) {
        Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1 -ChangeId 'ui-copilot-off-user'
        Set-RegistryDwordWithBackup -Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Value 1 -ChangeId 'ui-copilot-off-machine'
    }

    Write-Host "User interface tweaks applied. Sign out or restart Explorer for full effect." -ForegroundColor Green
    Write-Host "  (Task Manager -> Windows Explorer -> Restart)" -ForegroundColor DarkGray
}

function Set-TaskbarLeft {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-RegistryDwordWithBackup -Path $path -Name 'TaskbarAl' -Value 0 -ChangeId 'ui-taskbar-left'
    Write-Host "Taskbar alignment set to LEFT (Win11). Restart Explorer to refresh." -ForegroundColor Green
}

function Set-DarkMode {
    $path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
    Set-RegistryDwordWithBackup -Path $path -Name 'AppsUseLightTheme' -Value 0 -ChangeId 'theme-apps-dark'
    Set-RegistryDwordWithBackup -Path $path -Name 'SystemUsesLightTheme' -Value 0 -ChangeId 'theme-system-dark'
    Write-Host "Dark mode enabled for apps and Windows (current user)." -ForegroundColor Green
}

function Set-MiscTweaks {
    # Show file extensions
    Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt' -Value 0 -ChangeId 'misc-show-ext'
    # Disable lock screen tips / suggestions
    Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338387Enabled' -Value 0 -ChangeId 'misc-lock-tips'
    Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'RotatingLockScreenEnabled' -Value 0 -ChangeId 'misc-lock-rotate-off'
    Write-Host "Misc tweaks applied." -ForegroundColor Green
}

function Restore-FromBackupFile {
    param([string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Warning "Backup not found: $FilePath"
        return
    }
    $json = Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $list = @()
    $topChanges = Get-ChangeProperty -Change $json -PascalName 'Changes'
    if ($null -ne $topChanges) { $list = @($topChanges) }

    # Apply in reverse order
    for ($i = $list.Count - 1; $i -ge 0; $i--) {
        $c = $list[$i]
        $kind = Get-ChangeProperty -Change $c -PascalName 'Kind'

        switch ($kind) {
            'RegistryDWord' {
                $path = Get-ChangeProperty -Change $c -PascalName 'Path'
                $name = Get-ChangeProperty -Change $c -PascalName 'Name'
                $prev = Get-ChangeProperty -Change $c -PascalName 'Previous'
                if ($null -eq $prev) {
                    Remove-ItemProperty -LiteralPath $path -Name $name -Force -ErrorAction SilentlyContinue
                } else {
                    if (-not (Test-Path -LiteralPath $path)) { New-Item -Path $path -Force | Out-Null }
                    Set-ItemProperty -LiteralPath $path -Name $name -Value $prev -Type DWord -Force
                }
            }
            'ServiceStartType' {
                $svcName = Get-ChangeProperty -Change $c -PascalName 'ServiceName'
                $prev = Get-ChangeProperty -Change $c -PascalName 'Previous'
                if ($null -eq $prev) { Write-Warning "No previous start type recorded for service $svcName - skipping restore."; continue }
                try {
                    Set-Service -Name $svcName -StartupType $prev -ErrorAction Stop
                } catch {
                    Write-Warning "Could not restore service $svcName : $_"
                }
            }
            'ClassicContextMenu' {
                $clsid = Get-ChangeProperty -Change $c -PascalName 'ClsidPath'
                $inproc = Get-ChangeProperty -Change $c -PascalName 'InprocPath'
                $parentExisted = Get-ChangeProperty -Change $c -PascalName 'ParentExisted'
                $inprocExisted = Get-ChangeProperty -Change $c -PascalName 'InprocExisted'
                $prevData = Get-ChangeProperty -Change $c -PascalName 'PreviousDefault'
                if (-not $parentExisted) {
                    if ($clsid -and (Test-Path -LiteralPath $clsid)) {
                        Remove-Item -LiteralPath $clsid -Recurse -Force
                    }
                } elseif (-not $inprocExisted) {
                    if ($inproc -and (Test-Path -LiteralPath $inproc)) {
                        Remove-Item -LiteralPath $inproc -Recurse -Force -ErrorAction SilentlyContinue
                    }
                } elseif ($inproc -and (Test-Path -LiteralPath $inproc)) {
                    $val = ''
                    if ($null -ne $prevData) { $val = $prevData }
                    Set-ItemProperty -LiteralPath $inproc -Name '(default)' -Value $val -Force
                }
            }
            'RemovedAppxPackages' {
                Write-Host "Skipping automatic reinstall of removed apps (use Microsoft Store / winget)." -ForegroundColor DarkYellow
            }
            'RemovedProvisionedPackages' {
                Write-Host "Skipping automatic restore of provisioned packages (use Add-AppxPackage / image tools)." -ForegroundColor DarkYellow
            }
            default {
                Write-Warning "Unknown backup entry kind: $kind"
            }
        }
    }
    Write-Host "Restore finished for: $FilePath" -ForegroundColor Green
    Write-Host "Sign out or reboot if Explorer, Start, or shell still look wrong." -ForegroundColor DarkYellow
}

function Show-MainMenu {
    Clear-Host
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Windows 10/11 Cleanup (interactive)" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host " 1) Remove optional pre-installed apps (current user)"
    Write-Host " 2) Remove optional apps for NEW profiles (provisioned)  [extra thorough]"
    Write-Host " 3) Privacy: telemetry, ads ID, activity feed, location service"
    Write-Host " 4) UI: classic right-click (Win11), hide Start recommendations, disable Copilot"
    Write-Host " 5) Taskbar: align icons to the LEFT (Win11)"
    Write-Host " 6) Appearance: enable dark mode (current user)"
    Write-Host " 7) Extras: show file extensions, reduce lock screen tips"
    Write-Host " 8) Run ALL safe tweaks above (1,3,4,5,6,7) - skips provisioned removal"
    Write-Host ""
    Write-Host "--- Restore ---" -ForegroundColor Yellow
    Write-Host " R) Restore from a backup file (revert registry & services from that session)"
    Write-Host " L) List backup files"
    Write-Host ""
    Write-Host " Q) Quit"
    Write-Host ""
}

function Get-Backups {
    Initialize-BackupDir
    Get-ChildItem -LiteralPath $Script:BackupDir -Filter 'session-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { "{0}  ({1})" -f $_.Name, $_.LastWriteTime }
}

# --- Main loop ---
Initialize-BackupDir
Write-Host "Administrator rights detected. Backups folder: $Script:BackupDir" -ForegroundColor DarkGray
Start-Sleep -Milliseconds 400

while ($true) {
    Show-MainMenu
    $choice = (Read-Host 'Choose an option').Trim().ToUpperInvariant()

    switch ($choice) {
        '1' {
            Initialize-SessionBackup
            Remove-BloatwareForCurrentUser
            Pause
        }
        '2' {
            Write-Host "This removes packages from the system image for future accounts. Continue? (y/N)" -ForegroundColor Yellow
            $c = (Read-Host).Trim()
            # PowerShell uses case-insensitive default string comparison; 'Y' matches -eq 'y'.
            if ($c -eq 'y') {
                Initialize-SessionBackup
                Remove-BloatwareProvisioned
            }
            Pause
        }
        '3' {
            Initialize-SessionBackup
            Set-PrivacyTweaks
            Pause
        }
        '4' {
            Initialize-SessionBackup
            Set-UiTweaks
            Pause
        }
        '5' {
            Initialize-SessionBackup
            Set-TaskbarLeft
            Pause
        }
        '6' {
            Initialize-SessionBackup
            Set-DarkMode
            Pause
        }
        '7' {
            Initialize-SessionBackup
            Set-MiscTweaks
            Pause
        }
        '8' {
            Write-Host "This runs options 1,3,4,5,6,7 in one go. Continue? (y/N)" -ForegroundColor Yellow
            $c = (Read-Host).Trim()
            # PowerShell uses case-insensitive default string comparison; 'Y' matches -eq 'y'.
            if ($c -eq 'y') {
                Initialize-SessionBackup
                Remove-BloatwareForCurrentUser
                Set-PrivacyTweaks
                Set-UiTweaks
                Set-TaskbarLeft
                Set-DarkMode
                Set-MiscTweaks
                Write-Host "All selected steps finished. Review $Script:SessionBackup if you need to revert." -ForegroundColor Green
            }
            Pause
        }
        'R' {
            $items = @(Get-ChildItem -LiteralPath $Script:BackupDir -Filter 'session-*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            if ($items.Count -eq 0) {
                Write-Host "No backup files found." -ForegroundColor Yellow
                Pause
                continue
            }
            Write-Host "Recent backups:" -ForegroundColor Cyan
            for ($i = 0; $i -lt $items.Count; $i++) {
                Write-Host ("  [{0}] {1}" -f ($i + 1), $items[$i].Name)
            }
            $n = Read-Host "Enter number to restore (or blank to cancel)"
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            $idx = 0
            if (-not [int]::TryParse($n, [ref]$idx) -or $idx -lt 1 -or $idx -gt $items.Count) {
                Write-Warning "Invalid selection."
                Pause
                continue
            }
            $file = $items[$idx - 1].FullName
            Write-Host "Restoring from $file ..." -ForegroundColor Yellow
            Restore-FromBackupFile -FilePath $file
            Pause
        }
        'L' {
            $lines = @(Get-Backups)
            if ($lines.Count -eq 0) { Write-Host "(none yet)" }
            else { $lines | ForEach-Object { Write-Host $_ } }
            Pause
        }
        'Q' { return }
        default {
            Write-Host "Unknown option." -ForegroundColor Yellow
            Start-Sleep -Seconds 1
        }
    }
}

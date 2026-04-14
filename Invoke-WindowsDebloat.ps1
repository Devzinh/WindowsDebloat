<#
.SYNOPSIS
  Interactive Windows 10/11 cleanup: remove optional apps, tighten privacy, tweak UI - with backups you can restore.

.NOTES
  If not elevated, the script will ask UAC permission and relaunch itself as Administrator.
  Backups are saved under: <script folder>\backups\
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$DryRun,
    [switch]$RunAll,
    [string]$LogFile,
    [switch]$SkipElevationCheck
)

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Continue'

$Script:RootDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$Script:BackupDir = Join-Path $Script:RootDir 'backups'
$Script:SessionBackup = $null
$Script:SessionChanges = [System.Collections.Generic.List[object]]::new()
$Script:LogFile = $null
$Script:Summary = @{
    Succeeded = 0
    Failed    = 0
    Skipped   = 0
    Details   = [System.Collections.Generic.List[object]]::new()
}

function ConvertTo-LogDataString {
    param([hashtable]$Data)

    if ($null -eq $Data -or $Data.Count -eq 0) {
        return $null
    }

    try {
        return ($Data | ConvertTo-Json -Depth 8 -Compress)
    } catch {
        return ($Data | Out-String).Trim()
    }
}

function Write-Log {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Info', 'Warning', 'Error', 'Success', 'Debug')]
        [string]$Level,
        [Parameter(Mandatory)]
        [string]$Message,
        [hashtable]$Data
    )

    $dataText = ConvertTo-LogDataString -Data $Data
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level.ToUpperInvariant(), $Message
    if ($dataText) {
        $line = '{0} | Data: {1}' -f $line, $dataText
    }

    switch ($Level) {
        'Info' { Write-Host $Message -ForegroundColor Cyan }
        'Success' { Write-Host $Message -ForegroundColor Green }
        'Debug' { Write-Host $Message -ForegroundColor DarkGray }
        'Warning' { Write-Warning $Message }
        'Error' { Write-Error $Message }
    }

    if ($Script:LogFile) {
        try {
            $parent = Split-Path -Parent $Script:LogFile
            if ($parent -and (Test-Path -LiteralPath $parent)) {
                Add-Content -LiteralPath $Script:LogFile -Value $line -Encoding UTF8
            }
        } catch {
            # Keep logging failures non-fatal.
        }
    }
}

function Add-SummaryDetail {
    param(
        [Parameter(Mandatory)]
        [string]$Label,
        [Parameter(Mandatory)]
        [ValidateSet('Succeeded', 'Failed', 'Skipped')]
        [string]$Result,
        [string]$Error
    )

    switch ($Result) {
        'Succeeded' { $Script:Summary.Succeeded++ }
        'Failed' { $Script:Summary.Failed++ }
        'Skipped' { $Script:Summary.Skipped++ }
    }

    $Script:Summary.Details.Add([pscustomobject]@{
        Timestamp = Get-Date
        Label     = $Label
        Result    = $Result
        Error     = $Error
    })
}

function Show-Summary {
    if ($Script:Summary.Details.Count -eq 0) {
        Write-Log -Level Info -Message 'No tracked operations were recorded in this session.'
        return
    }

    Write-Log -Level Info -Message 'Execution summary:'
    $rows = foreach ($detail in $Script:Summary.Details) {
        $symbol = switch ($detail.Result) {
            'Succeeded' { [char]0x2713 }
            'Failed' { [char]0x2717 }
            default { 'skipped' }
        }

        [pscustomobject]@{
            Result    = $symbol
            Operation = $detail.Label
            Error     = $detail.Error
        }
    }

    $rows | Format-Table -AutoSize | Out-String | ForEach-Object {
        foreach ($line in ($_ -split [Environment]::NewLine)) {
            if (-not [string]::IsNullOrWhiteSpace($line)) {
                Write-Log -Level Info -Message $line
            }
        }
    }

    Write-Log -Level Info -Message ('Succeeded: {0} | Failed: {1} | Skipped: {2}' -f $Script:Summary.Succeeded, $Script:Summary.Failed, $Script:Summary.Skipped)
}

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
    if ($DryRun) { $args += ' -DryRun' }
    if ($RunAll) { $args += ' -RunAll' }
    if ($LogFile) { $args += " -LogFile `"$LogFile`"" }
    if ($SkipElevationCheck) { $args += ' -SkipElevationCheck' }

    Write-Log -Level Warning -Message 'Administrator rights are required. Requesting UAC elevation...'
    try {
        Start-Process -FilePath $hostExe -ArgumentList $args -Verb RunAs -ErrorAction Stop | Out-Null
        Write-Log -Level Success -Message 'A new elevated PowerShell window was opened. Continue there.'
        exit
    } catch {
        Write-Log -Level Error -Message 'Elevation was canceled or failed. Please run PowerShell as Administrator and try again.'
        exit 1
    }
}

function Test-OSCompatibility {
    $build = [System.Environment]::OSVersion.Version.Build
    Write-Log -Level Info -Message "Detected Windows build: $build"
    if ($build -lt 19041) {
        Write-Log -Level Warning -Message "Windows build $build is below 19041. Some tweaks may not apply on this OS."
        return $false
    }

    return $true
}

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
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not (Test-Path -LiteralPath $Script:BackupDir)) {
        if ($DryRun) {
            Write-Log -Level Debug -Message "DRY-RUN: Would create backup directory '$Script:BackupDir'."
            return
        }

        if ($PSCmdlet.ShouldProcess($Script:BackupDir, 'Create backup directory')) {
            New-Item -ItemType Directory -Path $Script:BackupDir -Force | Out-Null
            Write-Log -Level Debug -Message "Created backup directory '$Script:BackupDir'."
        }
    }
}

function Initialize-LogFile {
    if ([string]::IsNullOrWhiteSpace($LogFile)) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $Script:LogFile = Join-Path $Script:BackupDir "run-$stamp.log"
    } else {
        $Script:LogFile = $LogFile
    }

    try {
        $parent = Split-Path -Parent $Script:LogFile
        if ($parent -and -not (Test-Path -LiteralPath $parent) -and -not $DryRun) {
            New-Item -ItemType Directory -Path $parent -Force -ErrorAction Stop | Out-Null
        }
        if (-not (Test-Path -LiteralPath $Script:LogFile) -and (Test-Path -LiteralPath $parent) -and -not $DryRun) {
            New-Item -ItemType File -Path $Script:LogFile -Force -ErrorAction Stop | Out-Null
        }
    } catch {
        $Script:LogFile = $null
    }
}

function Initialize-SessionBackup {
    Initialize-BackupDir
    if ($null -ne $Script:SessionBackup) { return }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $Script:SessionBackup = Join-Path $Script:BackupDir "session-$stamp.json"
    Write-Log -Level Debug -Message "Reversible changes this run are logged to: $Script:SessionBackup"
}

function Save-SessionBackup {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    if (-not $Script:SessionBackup) { return }

    if ($DryRun) {
        Write-Log -Level Debug -Message "DRY-RUN: Would write session backup file '$Script:SessionBackup'."
        return
    }

    $payload = @{
        CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        Computer   = $env:COMPUTERNAME
        User       = $env:USERNAME
        Changes    = @($Script:SessionChanges)
    }

    if ($PSCmdlet.ShouldProcess($Script:SessionBackup, 'Write session backup file')) {
        $payload | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Script:SessionBackup -Encoding UTF8
    }
}

function Add-ChangeRecord {
    param([hashtable]$Record)
    Initialize-SessionBackup
    $Script:SessionChanges.Add($Record)
    if ($DryRun) {
        Write-Log -Level Debug -Message "DRY-RUN: Skipping session backup write for change '$($Record.Id)'."
        return
    }
    Save-SessionBackup
}

function Remove-OldBackups {
    [CmdletBinding(SupportsShouldProcess)]
    param([int]$KeepCount = 10)

    if (-not (Test-Path -LiteralPath $Script:BackupDir)) {
        Write-Log -Level Debug -Message 'Backup directory does not exist yet. No old backups to rotate.'
        return
    }

    $files = @(Get-ChildItem -LiteralPath $Script:BackupDir -Filter 'session-*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($files.Count -le $KeepCount) {
        Write-Log -Level Debug -Message "Backup rotation checked. Nothing to remove (keep count: $KeepCount)."
        return
    }

    $removed = 0
    foreach ($file in $files[$KeepCount..($files.Count - 1)]) {
        if ($DryRun) {
            Write-Log -Level Debug -Message "DRY-RUN: Would delete old backup '$($file.FullName)'."
            $removed++
            continue
        }

        if ($PSCmdlet.ShouldProcess($file.FullName, 'Remove old backup file')) {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction SilentlyContinue
            $removed++
        }
    }

    if ($DryRun) {
        Write-Log -Level Info -Message "Backup rotation would remove $removed old backup file(s)."
    } else {
        Write-Log -Level Info -Message "Backup rotation removed $removed old backup file(s)."
    }
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
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$Path,
        [string]$Name,
        [int]$Value,
        [string]$ChangeId
    )

    $prev = Read-RegistryValueSafe -Path $Path -Name $Name
    if ($DryRun) {
        Write-Log -Level Debug -Message "DRY-RUN: Would set registry DWORD '$Path\$Name' to '$Value'." -Data @{ ChangeId = $ChangeId; Previous = $prev; New = $Value }
        Add-ChangeRecord @{
            Kind     = 'RegistryDWord'
            Id       = $ChangeId
            Path     = $Path
            Name     = $Name
            Previous = $prev
            New      = $Value
        }
        return
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        if ($PSCmdlet.ShouldProcess($Path, 'Create registry path')) {
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }
    }
    if ($PSCmdlet.ShouldProcess("$Path\$Name", "Set registry DWORD to $Value")) {
        Set-ItemProperty -LiteralPath $Path -Name $Name -Value $Value -Type DWord -Force -ErrorAction Stop
    }
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
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$ServiceName,
        [string]$NewStartMode,
        [string]$ChangeId
    )

    if (-not (Get-Service -Name $ServiceName -ErrorAction SilentlyContinue)) {
        Write-Log -Level Warning -Message "Service '$ServiceName' not found on this system. Skipping."
        return
    }

    $svc = Get-Service -Name $ServiceName -ErrorAction Stop
    $prev = $svc.StartType.ToString()

    if ($DryRun) {
        Write-Log -Level Debug -Message "DRY-RUN: Would set service '$ServiceName' startup type to '$NewStartMode'." -Data @{ ChangeId = $ChangeId; Previous = $prev; New = $NewStartMode }
        Add-ChangeRecord @{
            Kind        = 'ServiceStartType'
            Id          = $ChangeId
            ServiceName = $ServiceName
            Previous    = $prev
            New         = $NewStartMode
        }
        return
    }

    if ($svc.Status -eq 'Running' -and $NewStartMode -in @('Disabled', 'Manual')) {
        if ($PSCmdlet.ShouldProcess($ServiceName, 'Stop running service before changing startup type')) {
            Stop-Service -Name $ServiceName -Force -ErrorAction SilentlyContinue
        }
    }
    if ($PSCmdlet.ShouldProcess($ServiceName, "Set startup type to $NewStartMode")) {
        Set-Service -Name $ServiceName -StartupType $NewStartMode -ErrorAction Stop
    }
    Add-ChangeRecord @{
        Kind        = 'ServiceStartType'
        Id          = $ChangeId
        ServiceName = $ServiceName
        Previous    = $prev
        New         = $NewStartMode
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
        if ($DryRun) {
            Add-SummaryDetail -Label $Label -Result Skipped
        } else {
            Add-SummaryDetail -Label $Label -Result Succeeded
        }
        return $true
    } catch {
        $msg = $_.Exception.Message
        if ([string]::IsNullOrWhiteSpace($msg)) {
            $msg = $_.ToString()
        }
        Add-SummaryDetail -Label $Label -Result Failed -Error $msg
        Write-Log -Level Warning -Message "$Label failed: $msg"
        return $false
    }
}

function Invoke-ClassicContextMenuEnable {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    # Windows 11: restore legacy right-click menu
    $clsid = 'HKCU:\Software\Classes\clsid\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}'
    $base = Join-Path $clsid 'InprocServer32'
    $parentExisted = Test-Path -LiteralPath $clsid
    $inprocExisted = Test-Path -LiteralPath $base
    $prevDefault = $null
    if ($inprocExisted) {
        $prevDefault = (Get-ItemProperty -LiteralPath $base -Name '(default)' -ErrorAction SilentlyContinue).'(default)'
    }

    if ($DryRun) {
        Write-Log -Level Debug -Message "DRY-RUN: Would enable classic context menu using '$base'."
        Add-ChangeRecord @{
            Kind            = 'ClassicContextMenu'
            Id              = 'ui-classic-context-menu'
            ClsidPath       = $clsid
            InprocPath      = $base
            ParentExisted   = $parentExisted
            InprocExisted   = $inprocExisted
            PreviousDefault = $prevDefault
        }
        return
    }

    if (-not $inprocExisted) {
        if ($PSCmdlet.ShouldProcess($base, 'Create classic context menu registry path')) {
            New-Item -Path $base -Force | Out-Null
        }
    }
    if ($PSCmdlet.ShouldProcess($base, 'Set classic context menu default value')) {
        Set-ItemProperty -LiteralPath $base -Name '(default)' -Value '' -Force
    }
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
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $names = Get-BloatPackageNames
    $removed = [System.Collections.Generic.List[string]]::new()
    for ($i = 0; $i -lt $names.Count; $i++) {
        $n = $names[$i]
        $percent = [int](($i / [Math]::Max($names.Count, 1)) * 100)
        Write-Progress -Activity 'Removing optional apps (current user)' -Status $n -PercentComplete $percent
        $pkgs = Get-AppxPackage -Name $n -ErrorAction SilentlyContinue
        foreach ($p in $pkgs) {
            try {
                if ($DryRun) {
                    Write-Log -Level Debug -Message "DRY-RUN: Would remove app package '$($p.PackageFullName)'."
                    $removed.Add($p.PackageFullName)
                    continue
                }
                if ($PSCmdlet.ShouldProcess($p.PackageFullName, 'Remove AppX package for current user')) {
                    Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop
                    $removed.Add($p.PackageFullName)
                }
            } catch {
                Write-Log -Level Warning -Message "Could not remove $($p.PackageFullName): $_"
            }
        }
    }
    Write-Progress -Activity 'Removing optional apps (current user)' -Completed

    if ($removed.Count -gt 0) {
        Add-ChangeRecord @{
            Kind             = 'RemovedAppxPackages'
            Id               = 'apps-removed-user'
            PackageFullNames = @($removed)
        }
    }

    Add-SummaryDetail -Label 'Remove optional pre-installed apps (current user)' -Result ($(if ($DryRun) { 'Skipped' } else { 'Succeeded' }))
    Write-Log -Level Success -Message "Removed $($removed.Count) app package(s) for current user."
    Write-Log -Level Warning -Message 'Tip: To bring an app back, reinstall it from the Microsoft Store (or use winget).'
}

function Remove-BloatwareProvisioned {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $names = Get-BloatPackageNames
    $removed = [System.Collections.Generic.List[string]]::new()
    $allProvisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
    for ($i = 0; $i -lt $names.Count; $i++) {
        $n = $names[$i]
        $percent = [int](($i / [Math]::Max($names.Count, 1)) * 100)
        Write-Progress -Activity 'Removing provisioned packages' -Status $n -PercentComplete $percent
        $prov = $allProvisioned | Where-Object { $_.DisplayName -eq $n }
        foreach ($p in $prov) {
            try {
                if ($DryRun) {
                    Write-Log -Level Debug -Message "DRY-RUN: Would de-provision package '$($p.PackageName)'."
                    $removed.Add($p.PackageName)
                    continue
                }
                if ($PSCmdlet.ShouldProcess($p.PackageName, 'Remove provisioned AppX package')) {
                    $null = Remove-AppxProvisionedPackage -Online -PackageName $p.PackageName -ErrorAction Stop
                    $removed.Add($p.PackageName)
                }
            } catch {
                Write-Log -Level Warning -Message "Could not de-provision $($p.PackageName): $_"
            }
        }
    }
    Write-Progress -Activity 'Removing provisioned packages' -Completed

    if ($removed.Count -gt 0) {
        Add-ChangeRecord @{
            Kind         = 'RemovedProvisionedPackages'
            Id           = 'apps-removed-provisioned'
            PackageNames = @($removed)
        }
    }

    Add-SummaryDetail -Label 'Remove optional apps for NEW profiles (provisioned)' -Result ($(if ($DryRun) { 'Skipped' } else { 'Succeeded' }))
    Write-Log -Level Success -Message "Removed $($removed.Count) provisioned package(s) (future user profiles)."
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
        Write-Log -Level Success -Message 'Privacy-related tweaks applied (with backups).'
    } else {
        Write-Log -Level Warning -Message "Privacy tweaks completed with warnings. Success: $ok, Failed: $failed."
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

    Write-Log -Level Success -Message 'User interface tweaks applied. Sign out or restart Explorer for full effect.'
    Write-Log -Level Debug -Message '  (Task Manager -> Windows Explorer -> Restart)'
    Add-SummaryDetail -Label 'UI: classic right-click (Win11), hide Start recommendations, disable Copilot' -Result ($(if ($DryRun) { 'Skipped' } else { 'Succeeded' }))
}

function Set-TaskbarLeft {
    $path = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
    Set-RegistryDwordWithBackup -Path $path -Name 'TaskbarAl' -Value 0 -ChangeId 'ui-taskbar-left'
    Write-Log -Level Success -Message 'Taskbar alignment set to LEFT (Win11). Restart Explorer to refresh.'
    Add-SummaryDetail -Label 'Taskbar: align icons to the LEFT (Win11)' -Result ($(if ($DryRun) { 'Skipped' } else { 'Succeeded' }))
}

function Set-DarkMode {
    [CmdletBinding(SupportsShouldProcess)]
    param()

    $path = 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Themes\Personalize'
    if (-not (Test-Path -LiteralPath $path)) {
        if ($DryRun) {
            Write-Log -Level Debug -Message "DRY-RUN: Would create registry path '$path'."
        } else {
            if ($PSCmdlet.ShouldProcess($path, 'Create registry path for dark mode')) {
                New-Item -Path $path -Force | Out-Null
            }
        }
    }
    Set-RegistryDwordWithBackup -Path $path -Name 'AppsUseLightTheme' -Value 0 -ChangeId 'theme-apps-dark'
    Set-RegistryDwordWithBackup -Path $path -Name 'SystemUsesLightTheme' -Value 0 -ChangeId 'theme-system-dark'
    Write-Log -Level Success -Message 'Dark mode enabled for apps and Windows (current user).'
    Add-SummaryDetail -Label 'Appearance: enable dark mode (current user)' -Result ($(if ($DryRun) { 'Skipped' } else { 'Succeeded' }))
}

function Set-MiscTweaks {
    # Show file extensions
    Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'HideFileExt' -Value 0 -ChangeId 'misc-show-ext'
    # Disable lock screen tips / suggestions
    Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338387Enabled' -Value 0 -ChangeId 'misc-lock-tips'
    Set-RegistryDwordWithBackup -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'RotatingLockScreenEnabled' -Value 0 -ChangeId 'misc-lock-rotate-off'
    Write-Log -Level Success -Message 'Misc tweaks applied.'
    Add-SummaryDetail -Label 'Extras: show file extensions, reduce lock screen tips' -Result ($(if ($DryRun) { 'Skipped' } else { 'Succeeded' }))
}

function Restore-FromBackupFile {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$FilePath)

    if (-not (Test-Path -LiteralPath $FilePath)) {
        Write-Log -Level Warning -Message "Backup not found: $FilePath"
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
                if ($DryRun) {
                    Write-Log -Level Debug -Message "DRY-RUN: Would restore registry DWORD '$path\$name'."
                    continue
                }
                if ($null -eq $prev) {
                    if ($PSCmdlet.ShouldProcess("$path\$name", 'Remove registry value during restore')) {
                        Remove-ItemProperty -LiteralPath $path -Name $name -Force -ErrorAction SilentlyContinue
                    }
                } else {
                    if (-not (Test-Path -LiteralPath $path)) {
                        if ($PSCmdlet.ShouldProcess($path, 'Create registry path during restore')) {
                            New-Item -Path $path -Force | Out-Null
                        }
                    }
                    if ($PSCmdlet.ShouldProcess("$path\$name", 'Restore registry DWORD value')) {
                        Set-ItemProperty -LiteralPath $path -Name $name -Value $prev -Type DWord -Force
                    }
                }
            }
            'ServiceStartType' {
                $svcName = Get-ChangeProperty -Change $c -PascalName 'ServiceName'
                $prev = Get-ChangeProperty -Change $c -PascalName 'Previous'
                if ($null -eq $prev) {
                    Write-Log -Level Warning -Message "No previous start type recorded for service $svcName - skipping restore."
                    continue
                }
                try {
                    if ($DryRun) {
                        Write-Log -Level Debug -Message "DRY-RUN: Would restore service '$svcName' startup type to '$prev'."
                    } elseif ($PSCmdlet.ShouldProcess($svcName, "Restore service startup type to $prev")) {
                        Set-Service -Name $svcName -StartupType $prev -ErrorAction Stop
                    }
                } catch {
                    Write-Log -Level Warning -Message "Could not restore service $svcName : $_"
                }
            }
            'ClassicContextMenu' {
                $clsid = Get-ChangeProperty -Change $c -PascalName 'ClsidPath'
                $inproc = Get-ChangeProperty -Change $c -PascalName 'InprocPath'
                $parentExisted = Get-ChangeProperty -Change $c -PascalName 'ParentExisted'
                $inprocExisted = Get-ChangeProperty -Change $c -PascalName 'InprocExisted'
                $prevData = Get-ChangeProperty -Change $c -PascalName 'PreviousDefault'
                if ($DryRun) {
                    Write-Log -Level Debug -Message "DRY-RUN: Would restore classic context menu registry state."
                    continue
                }
                if (-not $parentExisted) {
                    if ($clsid -and (Test-Path -LiteralPath $clsid) -and $PSCmdlet.ShouldProcess($clsid, 'Remove classic context menu registry tree')) {
                        Remove-Item -LiteralPath $clsid -Recurse -Force
                    }
                } elseif (-not $inprocExisted) {
                    if ($inproc -and (Test-Path -LiteralPath $inproc) -and $PSCmdlet.ShouldProcess($inproc, 'Remove classic context menu InprocServer32 key')) {
                        Remove-Item -LiteralPath $inproc -Recurse -Force -ErrorAction SilentlyContinue
                    }
                } elseif ($inproc -and (Test-Path -LiteralPath $inproc)) {
                    $val = ''
                    if ($null -ne $prevData) { $val = $prevData }
                    if ($PSCmdlet.ShouldProcess($inproc, 'Restore classic context menu default value')) {
                        Set-ItemProperty -LiteralPath $inproc -Name '(default)' -Value $val -Force
                    }
                }
            }
            'RemovedAppxPackages' {
                Write-Log -Level Warning -Message 'Skipping automatic reinstall of removed apps (use Microsoft Store / winget).'
            }
            'RemovedProvisionedPackages' {
                Write-Log -Level Warning -Message 'Skipping automatic restore of provisioned packages (use Add-AppxPackage / image tools).'
            }
            default {
                Write-Log -Level Warning -Message "Unknown backup entry kind: $kind"
            }
        }
    }
    Write-Log -Level Success -Message "Restore finished for: $FilePath"
    Write-Log -Level Warning -Message 'Sign out or reboot if Explorer, Start, or shell still look wrong.'
}

function Show-MainMenu {
    Clear-Host
    Write-Log -Level Info -Message '========================================'
    Write-Log -Level Info -Message '  Windows 10/11 Cleanup (interactive)'
    Write-Log -Level Info -Message '========================================'
    Write-Log -Level Info -Message ''
    Write-Log -Level Info -Message ' 1) Remove optional pre-installed apps (current user)'
    Write-Log -Level Info -Message ' 2) Remove optional apps for NEW profiles (provisioned)  [extra thorough]'
    Write-Log -Level Info -Message ' 3) Privacy: telemetry, ads ID, activity feed, location service'
    Write-Log -Level Info -Message ' 4) UI: classic right-click (Win11), hide Start recommendations, disable Copilot'
    Write-Log -Level Info -Message ' 5) Taskbar: align icons to the LEFT (Win11)'
    Write-Log -Level Info -Message ' 6) Appearance: enable dark mode (current user)'
    Write-Log -Level Info -Message ' 7) Extras: show file extensions, reduce lock screen tips'
    Write-Log -Level Info -Message ' 8) Run ALL safe tweaks above (1,3,4,5,6,7) - skips provisioned removal'
    Write-Log -Level Info -Message ''
    Write-Log -Level Warning -Message '--- Restore ---'
    Write-Log -Level Info -Message ' R) Restore from a backup file (revert registry & services from that session)'
    Write-Log -Level Info -Message ' L) List backup files'
    Write-Log -Level Info -Message ''
    Write-Log -Level Info -Message ' Q) Quit'
    Write-Log -Level Info -Message ''
}

function Get-Backups {
    Initialize-BackupDir
    Get-ChildItem -LiteralPath $Script:BackupDir -Filter 'session-*.json' -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending |
        ForEach-Object { "{0}  ({1})" -f $_.Name, $_.LastWriteTime }
}

function Invoke-RunAllSafeTweaks {
    Initialize-SessionBackup
    Remove-BloatwareForCurrentUser
    Set-PrivacyTweaks
    Set-UiTweaks
    Set-TaskbarLeft
    Set-DarkMode
    Set-MiscTweaks
    Write-Log -Level Success -Message "All selected steps finished. Review $Script:SessionBackup if you need to revert."
    Show-Summary
}

if ($SkipElevationCheck) {
    Write-Log -Level Warning -Message 'Skipping elevation check because -SkipElevationCheck was specified.'
} else {
    Ensure-ElevatedSession
}

Initialize-BackupDir
Initialize-LogFile
Initialize-BackupDir
Remove-OldBackups
$null = Test-OSCompatibility

Write-Log -Level Debug -Message "Administrator rights detected. Backups folder: $Script:BackupDir"
if ($Script:LogFile) {
    Write-Log -Level Debug -Message "Log file: $Script:LogFile"
}
if ($DryRun) {
    Write-Log -Level Warning -Message '[DRY-RUN MODE] No changes will be written to this system.'
}
Start-Sleep -Milliseconds 400

if ($RunAll) {
    Invoke-RunAllSafeTweaks
    if ($Script:Summary.Failed -gt 0) {
        Write-Log -Level Warning -Message "WARNING: $($Script:Summary.Failed) operation(s) failed during this session. Review the log at: $Script:LogFile"
    }
    if ($Script:LogFile) {
        Write-Log -Level Info -Message "Session log saved to: $Script:LogFile"
    }
    return
}

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
            Write-Log -Level Warning -Message 'This removes packages from the system image for future accounts. Continue? (y/N)'
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
            Write-Log -Level Warning -Message 'This runs options 1,3,4,5,6,7 in one go. Continue? (y/N)'
            $c = (Read-Host).Trim()
            # PowerShell uses case-insensitive default string comparison; 'Y' matches -eq 'y'.
            if ($c -eq 'y') {
                Invoke-RunAllSafeTweaks
            }
            Pause
        }
        'R' {
            $items = @(Get-ChildItem -LiteralPath $Script:BackupDir -Filter 'session-*.json' -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            if ($items.Count -eq 0) {
                Write-Log -Level Warning -Message 'No backup files found.'
                Pause
                continue
            }
            Write-Log -Level Info -Message 'Recent backups:'
            for ($i = 0; $i -lt $items.Count; $i++) {
                Write-Log -Level Info -Message ("  [{0}] {1}" -f ($i + 1), $items[$i].Name)
            }
            $n = Read-Host 'Enter number to restore (or blank to cancel)'
            if ([string]::IsNullOrWhiteSpace($n)) { continue }
            $idx = 0
            if (-not [int]::TryParse($n, [ref]$idx) -or $idx -lt 1 -or $idx -gt $items.Count) {
                Write-Log -Level Warning -Message 'Invalid selection.'
                Pause
                continue
            }
            $file = $items[$idx - 1].FullName
            Write-Log -Level Warning -Message 'WARNING: This will revert registry and service changes from the selected session.'
            $confirmRestore = Read-Host 'Type YES to confirm restore, or press Enter to cancel:'
            if ($confirmRestore -ne 'YES') {
                Write-Log -Level Warning -Message 'Restore cancelled.'
                Pause
                continue
            }
            Write-Log -Level Warning -Message "Restoring from $file ..."
            Restore-FromBackupFile -FilePath $file
            Pause
        }
        'L' {
            $lines = @(Get-Backups)
            if ($lines.Count -eq 0) { Write-Log -Level Info -Message '(none yet)' }
            else { $lines | ForEach-Object { Write-Log -Level Info -Message $_ } }
            Pause
        }
        'Q' { break }
        default {
            Write-Log -Level Warning -Message 'Unknown option.'
            Start-Sleep -Seconds 1
        }
    }
}

if ($Script:Summary.Failed -gt 0) {
    Write-Log -Level Warning -Message "WARNING: $($Script:Summary.Failed) operation(s) failed during this session. Review the log at: $Script:LogFile"
}

if ($Script:LogFile) {
    Write-Log -Level Info -Message "Session log saved to: $Script:LogFile"
}

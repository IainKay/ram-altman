[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$Status,
    [switch]$DryRun,
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

$script:AppName = "RAM Altman"
$script:AppRoot = Join-Path $env:APPDATA "RAMAltman"
$script:ConfigPath = Join-Path $script:AppRoot "config.json"
$script:StatePath = Join-Path $script:AppRoot "state.json"
$script:LogPath = Join-Path $script:AppRoot "memory.csv"
$script:LockPath = Join-Path $script:AppRoot "run.lock"
$script:Config = $null
$script:DryRunMode = [bool]$DryRun
$script:LockHandle = $null

function Show-Help {
    @"
RAM Altman for Windows

Usage:
  .\ram-altman.ps1             Check memory and send an alert if needed
  .\ram-altman.ps1 -Setup      Configure an email provider and threshold
  .\ram-altman.ps1 -Status     Show configuration and current memory
  .\ram-altman.ps1 -DryRun     Preview an alert without sending or changing state
  .\ram-altman.ps1 -Help       Show this help

The script supports Resend and Brevo email APIs. It does not require SMTP,
WSL, Python, or third-party PowerShell modules.

Configuration and logs are stored under:
  $script:AppRoot
"@ | Write-Host
}

function Ensure-AppDirectory {
    if (-not (Test-Path -LiteralPath $script:AppRoot)) {
        New-Item -ItemType Directory -Path $script:AppRoot -Force | Out-Null
    }
}

function Read-NonEmpty {
    param([string]$Prompt, [string]$Default = "")

    while ($true) {
        if ($Default) {
            $answer = Read-Host "$Prompt [$Default]"
            if ([string]::IsNullOrWhiteSpace($answer)) {
                return $Default
            }
        } else {
            $answer = Read-Host $Prompt
        }

        if (-not [string]::IsNullOrWhiteSpace($answer)) {
            return $answer.Trim()
        }

        Write-Host "Please enter a value."
    }
}

function Read-EmailAddress {
    param([string]$Prompt)

    while ($true) {
        $value = (Read-NonEmpty $Prompt).Trim()

        if ($value -match '^[^@\s]+@[^@\s]+\.[^@\s]+$') {
            return $value
        }

        Write-Host "That does not look like an email address. Try again."
    }
}

function Read-Secret {
    param([string]$Prompt)

    $secure = Read-Host $Prompt -AsSecureString

    if ($secure.Length -eq 0) {
        throw "The API key cannot be empty."
    }

    return $secure
}

function Protect-ApiKey {
    param([Security.SecureString]$SecureKey)

    return ConvertFrom-SecureString -SecureString $SecureKey
}

function Unprotect-ApiKey {
    param([string]$ProtectedKey)

    $secure = ConvertTo-SecureString -String $ProtectedKey
    $ptr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)

    try {
        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($ptr)
    } finally {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($ptr)
        $secure.Dispose()
    }
}

function Save-Configuration {
    param([hashtable]$Config)

    Ensure-AppDirectory

    $json = $Config | ConvertTo-Json -Depth 5
    $tempPath = "$($script:ConfigPath).tmp"

    [IO.File]::WriteAllText(
        $tempPath,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )

    Move-Item -LiteralPath $tempPath -Destination $script:ConfigPath -Force
}

function Load-Configuration {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "Configuration not found. Run .\ram-altman.ps1 -Setup first."
    }

    $loaded = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json

    if ($loaded.Version -ne 1) {
        throw "Unsupported configuration version. Back up and recreate the configuration with -Setup."
    }

    $required = @(
        "Provider",
        "SenderEmail",
        "RecipientEmail",
        "Threshold",
        "ProtectedApiKey"
    )

    foreach ($field in $required) {
        if ($null -eq $loaded.$field -or
            [string]::IsNullOrWhiteSpace([string]$loaded.$field)) {
            throw "Configuration is missing '$field'. Run -Setup again."
        }
    }

    $provider = [string]$loaded.Provider

    if ($provider -notin @("Resend", "Brevo")) {
        throw "Unknown email provider '$provider'. Run -Setup again."
    }

    $threshold = 0.0

    if (-not [double]::TryParse(
        [string]$loaded.Threshold,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$threshold
    ) -or $threshold -lt 0 -or $threshold -gt 100) {
        throw "The configured threshold must be between 0 and 100."
    }

    $script:Config = @{
        Version = 1
        Provider = $provider
        SenderName = [string]$loaded.SenderName
        SenderEmail = [string]$loaded.SenderEmail
        RecipientEmail = [string]$loaded.RecipientEmail
        Threshold = $threshold
        ProtectedApiKey = [string]$loaded.ProtectedApiKey
    }

    # Validate that the protected key can be decrypted by this Windows user.
    $null = Unprotect-ApiKey $script:Config.ProtectedApiKey
}

function Start-Setup {
    Ensure-AppDirectory

    Write-Host ""
    Write-Host "RAM Altman email setup" -ForegroundColor Cyan
    Write-Host "The API key will be encrypted for this Windows user using DPAPI."
    Write-Host ""

    Write-Host "Choose an email provider:"
    Write-Host "  1. Resend"
    Write-Host "  2. Brevo"

    while ($true) {
        $choice = Read-Host "Provider (1 or 2)"

        if ($choice -eq "1") {
            $provider = "Resend"
            break
        }

        if ($choice -eq "2") {
            $provider = "Brevo"
            break
        }

        Write-Host "Enter 1 or 2."
    }

    if ($provider -eq "Resend") {
        Write-Host "Create an API key at https://resend.com/api-keys"
    } else {
        Write-Host "Create an API key at https://app.brevo.com/settings/keys/api"
    }

    $secureKey = Read-Secret "Paste your $provider API key"
    $senderName = Read-Host "Sender display name (optional)"
    $senderEmail = Read-EmailAddress "Verified sender email address"
    $recipientEmail = Read-EmailAddress "Recipient email address"

    while ($true) {
        $thresholdText = Read-NonEmpty "Alert when available RAM is above this percentage" "10"
        $threshold = 0.0

        $valid = [double]::TryParse(
            $thresholdText,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$threshold
        )

        if ($valid -and $threshold -ge 0 -and $threshold -le 100) {
            break
        }

        Write-Host "Enter a number from 0 to 100, for example 10 or 12.5."
    }

    $config = @{
        Version = 1
        Provider = $provider
        SenderName = $senderName.Trim()
        SenderEmail = $senderEmail
        RecipientEmail = $recipientEmail
        Threshold = $threshold
        ProtectedApiKey = Protect-ApiKey $secureKey
    }

    $secureKey.Dispose()
    Save-Configuration $config

    Write-Host ""
    Write-Host "Configuration saved to $script:ConfigPath" -ForegroundColor Green
    Write-Host "No test email was sent. The first real alert will test the provider credentials."
    Write-Host "Make sure your sender address/domain is verified with $provider."
}

function Get-MemoryInformation {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem

    if ($null -eq $os -or $os.TotalVisibleMemorySize -le 0) {
        throw "Windows did not return valid physical-memory information."
    }

    $totalBytes = [double]$os.TotalVisibleMemorySize * 1KB
    $availableBytes = [double]$os.FreePhysicalMemory * 1KB
    $usedBytes = [Math]::Max(0, $totalBytes - $availableBytes)

    $availablePercent = ($availableBytes / $totalBytes) * 100
    $usedPercent = 100 - $availablePercent

    [pscustomobject]@{
        TimestampUtc = [DateTime]::UtcNow.ToString("o")
        TotalBytes = [long]$totalBytes
        AvailableBytes = [long]$availableBytes
        UsedBytes = [long]$usedBytes
        AvailablePercent = [Math]::Round($availablePercent, 2)
        UsedPercent = [Math]::Round($usedPercent, 2)
    }
}

function Write-MemorySample {
    param($Memory)

    Ensure-AppDirectory

    $row = [pscustomobject]@{
        TimestampUtc = $Memory.TimestampUtc
        TotalGiB = [Math]::Round($Memory.TotalBytes / 1GB, 3)
        AvailableGiB = [Math]::Round($Memory.AvailableBytes / 1GB, 3)
        UsedGiB = [Math]::Round($Memory.UsedBytes / 1GB, 3)
        AvailablePercent = $Memory.AvailablePercent
        UsedPercent = $Memory.UsedPercent
    }

    if (Test-Path -LiteralPath $script:LogPath) {
        $row | Export-Csv -LiteralPath $script:LogPath -NoTypeInformation -Append -Encoding UTF8
    } else {
        $row | Export-Csv -LiteralPath $script:LogPath -NoTypeInformation -Encoding UTF8
    }
}

function Get-State {
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return @{ LastEmailDate = "" }
    }

    try {
        $state = Get-Content -LiteralPath $script:StatePath -Raw | ConvertFrom-Json
        return @{ LastEmailDate = [string]$state.LastEmailDate }
    } catch {
        throw "The state file is unreadable: $script:StatePath. Back it up before repairing it. $($_.Exception.Message)"
    }
}

function Save-State {
    param([hashtable]$State)

    $json = $State | ConvertTo-Json -Depth 3
    $tempPath = "$($script:StatePath).tmp"

    [IO.File]::WriteAllText(
        $tempPath,
        $json,
        (New-Object System.Text.UTF8Encoding($false))
    )

    Move-Item -LiteralPath $tempPath -Destination $script:StatePath -Force
}

function Get-RandomItem {
    param([string[]]$Items)

    return $Items[(Get-Random -Minimum 0 -Maximum $Items.Count)]
}

function New-AlertMessage {
    param($Memory)

    $subjects = @(
        "A small RAM situation has developed",
        "Your computer is having a memory moment",
        "RAM report: the numbers are doing a thing",
        "Available memory has crossed the line"
    )

    $openings = @(
        "The machine has reported its current memory situation.",
        "A routine memory check has found something worth mentioning.",
        "Windows has supplied today's RAM figures. Humanity continues to invent computers."
    )

    $closings = @(
        "Please enjoy this completely unsolicited systems update.",
        "The memory has been measured. The spreadsheet people may rejoice.",
        "No action has been taken beyond sending this report."
    )

    $subject = Get-RandomItem $subjects
    $opening = Get-RandomItem $openings
    $closing = Get-RandomItem $closings

    $body = @"
$opening

Available physical memory: $($Memory.AvailablePercent)%
Used physical memory:      $($Memory.UsedPercent)%
Available:                 $([Math]::Round($Memory.AvailableBytes / 1GB, 2)) GiB
Total physical memory:     $([Math]::Round($Memory.TotalBytes / 1GB, 2)) GiB
Alert threshold:           $($script:Config.Threshold)%

$closing

Reported by RAM Altman for Windows.
"@

    return [pscustomobject]@{
        Subject = $subject
        Body = $body
    }
}

function Send-ProviderEmail {
    param(
        [string]$Subject,
        [string]$Body
    )

    $apiKey = Unprotect-ApiKey $script:Config.ProtectedApiKey
    $headers = @{ Accept = "application/json" }
    $json = $null
    $uri = $null

    if ($script:Config.Provider -eq "Resend") {
        $uri = "https://api.resend.com/emails"
        $headers["Authorization"] = "Bearer $apiKey"

        if ([string]::IsNullOrWhiteSpace($script:Config.SenderName)) {
            $from = $script:Config.SenderEmail
        } else {
            $from = "$($script:Config.SenderName) <$($script:Config.SenderEmail)>"
        }

        $payload = @{
            from = $from
            to = @($script:Config.RecipientEmail)
            subject = $Subject
            text = $Body
        }
    } else {
        $uri = "https://api.brevo.com/v3/smtp/email"
        $headers["api-key"] = $apiKey

        $sender = @{
            email = $script:Config.SenderEmail
        }

        if (-not [string]::IsNullOrWhiteSpace($script:Config.SenderName)) {
            $sender.name = $script:Config.SenderName
        }

        $payload = @{
            sender = $sender
            to = @(
                @{
                    email = $script:Config.RecipientEmail
                }
            )
            subject = $Subject
            textContent = $Body
        }
    }

    $json = $payload | ConvertTo-Json -Depth 6

    try {
        # PowerShell 5.1 may otherwise negotiate older TLS defaults on some systems.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

        $null = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers `
            -ContentType "application/json" -Body $json -TimeoutSec 30
    } catch {
        $detail = $_.Exception.Message

        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $detail = "$detail`n$($_.ErrorDetails.Message)"
        }

        throw "Email provider request failed: $detail"
    } finally {
        $apiKey = $null
        $json = $null
    }
}

function Show-Status {
    $memory = Get-MemoryInformation

    Write-Host "RAM Altman for Windows" -ForegroundColor Cyan
    Write-Host ("Total physical RAM:     {0:N2} GiB" -f ($memory.TotalBytes / 1GB))
    Write-Host ("Available physical RAM: {0:N2} GiB ({1:N2}%)" -f ($memory.AvailableBytes / 1GB), $memory.AvailablePercent)
    Write-Host ("Used physical RAM:      {0:N2} GiB ({1:N2}%)" -f ($memory.UsedBytes / 1GB), $memory.UsedPercent)

    if (Test-Path -LiteralPath $script:ConfigPath) {
        Load-Configuration

        Write-Host ("Provider:               {0}" -f $script:Config.Provider)
        Write-Host ("Recipient:              {0}" -f $script:Config.RecipientEmail)
        Write-Host ("Alert threshold:        {0}%" -f $script:Config.Threshold)

        $state = Get-State

        if ($state.LastEmailDate) {
            Write-Host ("Last alert date:         {0}" -f $state.LastEmailDate)
        } else {
            Write-Host "Last alert date:         none"
        }
    } else {
        Write-Host "Email configuration:    not configured"
        Write-Host "Run .\ram-altman.ps1 -Setup"
    }
}

function Enter-RunLock {
    Ensure-AppDirectory

    try {
        $script:LockHandle = [IO.File]::Open(
            $script:LockPath,
            [IO.FileMode]::OpenOrCreate,
            [IO.FileAccess]::ReadWrite,
            [IO.FileShare]::None
        )

        return $true
    } catch [IO.IOException] {
        return $false
    }
}

function Invoke-Monitor {
    if (-not (Enter-RunLock)) {
        Write-Host "Another RAM Altman instance is already running. Exiting."
        return
    }

    try {
        $memory = Get-MemoryInformation
        Write-MemorySample $memory

        Write-Host ("Available RAM: {0:N2}% ({1:N2} GiB of {2:N2} GiB)" -f
            $memory.AvailablePercent,
            ($memory.AvailableBytes / 1GB),
            ($memory.TotalBytes / 1GB)
        )

        if ($script:DryRunMode) {
            if (Test-Path -LiteralPath $script:ConfigPath) {
                Load-Configuration
                $message = New-AlertMessage $memory

                Write-Host ""
                Write-Host "DRY RUN: no email sent and daily state not changed." -ForegroundColor Yellow
                Write-Host "Subject: $($message.Subject)"
                Write-Host $message.Body
            } else {
                Write-Host "DRY RUN: configure email with -Setup to preview a complete alert."
            }

            return
        }

        Load-Configuration

        if ($memory.AvailablePercent -le $script:Config.Threshold) {
            Write-Host ("No alert: available RAM is not above the {0}% threshold." -f $script:Config.Threshold)
            return
        }

        $today = (Get-Date).ToString("yyyy-MM-dd")
        $state = Get-State

        if ($state.LastEmailDate -eq $today) {
            Write-Host "An alert has already been accepted by the provider today. No duplicate sent."
            return
        }

        $message = New-AlertMessage $memory

        Send-ProviderEmail -Subject $message.Subject -Body $message.Body
        Save-State @{ LastEmailDate = $today }

        Write-Host "Alert accepted by the email provider." -ForegroundColor Green
    } finally {
        if ($null -ne $script:LockHandle) {
            $script:LockHandle.Dispose()
            $script:LockHandle = $null
        }
    }
}

try {
    if ($Help) {
        Show-Help
        exit 0
    }

    if ($Setup) {
        Start-Setup
        exit 0
    }

    if ($Status) {
        Show-Status
        exit 0
    }

    Invoke-Monitor
    exit 0
} catch {
    Write-Error $_
    exit 1
}

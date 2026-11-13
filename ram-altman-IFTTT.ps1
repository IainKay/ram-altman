
# RAM Altman - IFTTT Edition
# Version: 2.0.0
# Platform: Windows 10/11
# PowerShell: 5.1+

[CmdletBinding()]
param(
    [switch]$Setup,
    [switch]$Status,
    [switch]$DryRun,
    [switch]$Help
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------
# Application paths
# ---------------------------------------------------------------------

$script:AppName = "RAM Altman"
$script:AppRoot = Join-Path $env:APPDATA "RAMAltman"
$script:ConfigPath = Join-Path $script:AppRoot "config.json"
$script:StatePath = Join-Path $script:AppRoot "state.json"
$script:LogPath = Join-Path $script:AppRoot "memory.csv"
$script:LockPath = Join-Path $script:AppRoot "run.lock"

$script:Config = $null
$script:LockHandle = $null

# ---------------------------------------------------------------------
# General utilities
# ---------------------------------------------------------------------

function Ensure-AppDirectory {
    if (-not (Test-Path -LiteralPath $script:AppRoot)) {
        New-Item -ItemType Directory -Path $script:AppRoot -Force |
            Out-Null
    }
}

function Show-Help {
    Write-Host @"
RAM Altman - IFTTT Edition
Version 2.0.0

USAGE

  .\ram-altman.ps1 -Setup
  .\ram-altman.ps1 -Status
  .\ram-altman.ps1 -DryRun
  .\ram-altman.ps1 -Help
  .\ram-altman.ps1

OPTIONS

  -Setup      Configure IFTTT Webhooks.
  -Status     Display memory and configuration information.
  -DryRun     Preview a post without triggering IFTTT.
  -Help       Display this help message.

DESCRIPTION

  RAM Altman monitors available physical memory.

  When available memory exceeds the configured percentage,
  it triggers an IFTTT Webhooks event.

  IFTTT can then publish the generated message to X.

  A maximum of one event is triggered per local calendar day.

DATA DIRECTORY

  $script:AppRoot

"@
}

function Read-NonEmpty {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Prompt,

        [string]$Default = ""
    )

    while ($true) {
        if ($Default) {
            $value = Read-Host "$Prompt [$Default]"

            if ([string]::IsNullOrWhiteSpace($value)) {
                return $Default
            }
        } else {
            $value = Read-Host $Prompt
        }

        if (-not [string]::IsNullOrWhiteSpace($value)) {
            return $value.Trim()
        }

        Write-Host "A value is required."
    }
}

function Read-Threshold {
    param([double]$Default = 10)

    while ($true) {
        $value = Read-NonEmpty `
            -Prompt "Available RAM alert threshold (%)" `
            -Default ([string]$Default)

        $threshold = 0.0

        $valid = [double]::TryParse(
            $value,
            [Globalization.NumberStyles]::Float,
            [Globalization.CultureInfo]::InvariantCulture,
            [ref]$threshold
        )

        if ($valid -and $threshold -ge 0 -and $threshold -le 100) {
            return $threshold
        }

        Write-Host "Enter a percentage between 0 and 100."
    }
}

# ---------------------------------------------------------------------
# Secure configuration
# ---------------------------------------------------------------------

function Protect-Secret {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $secure = ConvertTo-SecureString `
        -String $Value `
        -AsPlainText `
        -Force

    try {
        return ConvertFrom-SecureString -SecureString $secure
    } finally {
        $secure.Dispose()
    }
}

function Unprotect-Secret {
    param(
        [Parameter(Mandatory = $true)]
        [string]$ProtectedValue
    )

    $secure = ConvertTo-SecureString -String $ProtectedValue
    $pointer = [IntPtr]::Zero

    try {
        $pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR(
            $secure
        )

        return [Runtime.InteropServices.Marshal]::PtrToStringBSTR(
            $pointer
        )
    } finally {
        if ($pointer -ne [IntPtr]::Zero) {
            [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer)
        }

        $secure.Dispose()
    }
}

function Save-JsonFile {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [object]$Value
    )

    $json = $Value | ConvertTo-Json -Depth 5
    $temporaryPath = "$Path.tmp"
    $encoding = New-Object System.Text.UTF8Encoding($false)

    [IO.File]::WriteAllText(
        $temporaryPath,
        $json,
        $encoding
    )

    Move-Item `
        -LiteralPath $temporaryPath `
        -Destination $Path `
        -Force
}

function Test-WebhookUrl {
    param([string]$Url)

    try {
        $uri = [Uri]$Url

        if ($uri.Scheme -ne "https") {
            return $false
        }

        if ($uri.Host -ne "maker.ifttt.com") {
            return $false
        }

        if ($uri.Query -or $uri.Fragment) {
            return $false
        }

        return $uri.AbsolutePath -match `
            '^/trigger/[A-Za-z0-9_]+/with/key/[A-Za-z0-9_-]+/?$'
    } catch {
        return $false
    }
}

function Load-Configuration {
    if (-not (Test-Path -LiteralPath $script:ConfigPath)) {
        throw "Configuration not found. Run -Setup first."
    }

    $loaded = Get-Content `
        -LiteralPath $script:ConfigPath `
        -Raw |
        ConvertFrom-Json

    if ($loaded.Version -ne 2) {
        throw "Unsupported configuration version. Run -Setup again."
    }

    if ($loaded.Provider -ne "IFTTT") {
        throw "Invalid provider in configuration."
    }

    $threshold = 0.0

    $valid = [double]::TryParse(
        [string]$loaded.Threshold,
        [Globalization.NumberStyles]::Float,
        [Globalization.CultureInfo]::InvariantCulture,
        [ref]$threshold
    )

    if (-not $valid -or $threshold -lt 0 -or $threshold -gt 100) {
        throw "Invalid RAM threshold in configuration."
    }

    if ([string]::IsNullOrWhiteSpace([string]$loaded.ProtectedWebhookUrl)) {
        throw "Missing protected webhook URL."
    }

    $script:Config = @{
        Version = 2
        Provider = "IFTTT"
        Threshold = $threshold
        Mention = [string]$loaded.Mention
        ProtectedWebhookUrl = [string]$loaded.ProtectedWebhookUrl
    }

    $url = Unprotect-Secret $script:Config.ProtectedWebhookUrl

    if (-not (Test-WebhookUrl $url)) {
        throw "The saved webhook URL is invalid. Run -Setup again."
    }

    if ($script:Config.Mention -notmatch '^@[A-Za-z0-9_]{1,15}$') {
        throw "Invalid X username in configuration."
    }
}

# ---------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------

function Start-Setup {
    Ensure-AppDirectory

    Write-Host ""
    Write-Host "RAM Altman - IFTTT setup" -ForegroundColor Cyan
    Write-Host "--------------------------------"
    Write-Host ""
    Write-Host "You need an IFTTT Webhooks Applet connected to X."
    Write-Host "See README.md for the complete setup instructions."
    Write-Host ""

    Write-Host "Your webhook URL should resemble:"
    Write-Host "https://maker.ifttt.com/trigger/ram_altman_alert/with/key/..."
    Write-Host ""

    while ($true) {
        $url = Read-NonEmpty "IFTTT Webhooks URL"

        if (Test-WebhookUrl $url) {
            break
        }

        Write-Host "Invalid IFTTT Webhooks URL."
        Write-Host "Check that you copied the complete URL."
    }

    $mention = Read-NonEmpty `
        -Prompt "X username to mention" `
        -Default "@sama"

    if ($mention -notmatch '^@[A-Za-z0-9_]{1,15}$') {
        throw "Invalid X username. Use a handle such as @sama."
    }

    $threshold = Read-Threshold -Default 10

    $config = @{
        Version = 2
        Provider = "IFTTT"
        Threshold = $threshold
        Mention = $mention
        ProtectedWebhookUrl = Protect-Secret $url
    }

    Save-JsonFile `
        -Path $script:ConfigPath `
        -Value $config

    Write-Host ""
    Write-Host "Configuration saved successfully." -ForegroundColor Green
    Write-Host "Webhook URL encrypted using Windows DPAPI."
    Write-Host "Mention: $mention"
    Write-Host "Available RAM threshold: $threshold%"
    Write-Host ""
    Write-Host "No test post was sent."
}

# ---------------------------------------------------------------------
# Memory monitoring
# ---------------------------------------------------------------------

function Get-MemoryInformation {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem

    if ($null -eq $os -or $os.TotalVisibleMemorySize -le 0) {
        throw "Unable to retrieve physical memory information."
    }

    $totalBytes = [double]$os.TotalVisibleMemorySize * 1KB
    $availableBytes = [double]$os.FreePhysicalMemory * 1KB

    $usedBytes = [Math]::Max(
        0,
        $totalBytes - $availableBytes
    )

    $availablePercent = ($availableBytes / $totalBytes) * 100
    $usedPercent = 100 - $availablePercent

    return [pscustomobject]@{
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
        $row | Export-Csv `
            -LiteralPath $script:LogPath `
            -NoTypeInformation `
            -Append `
            -Encoding UTF8
    } else {
        $row | Export-Csv `
            -LiteralPath $script:LogPath `
            -NoTypeInformation `
            -Encoding UTF8
    }
}

# ---------------------------------------------------------------------
# Daily state
# ---------------------------------------------------------------------

function Get-State {
    if (-not (Test-Path -LiteralPath $script:StatePath)) {
        return @{
            LastWebhookDate = ""
        }
    }

    try {
        $state = Get-Content `
            -LiteralPath $script:StatePath `
            -Raw |
            ConvertFrom-Json

        return @{
            LastWebhookDate = [string]$state.LastWebhookDate
        }
    } catch {
        throw "The state file is unreadable. Back it up before repairing it."
    }
}

function Save-State {
    param([string]$Date)

    Save-JsonFile `
        -Path $script:StatePath `
        -Value @{
            LastWebhookDate = $Date
        }
}

# ---------------------------------------------------------------------
# Tweet generation
# ---------------------------------------------------------------------

function Get-RandomItem {
    param([string[]]$Items)

    return Get-Random -InputObject $Items
}

function New-AlertMessage {
    param($Memory)

    $subjects = @(
        "RAM report: the numbers are doing a thing.",
        "A small memory situation has developed.",
        "The computer has submitted its RAM report.",
        "Windows has more memory news. Naturally.",
        "An unsolicited systems update has arrived."
    )

    $openings = @(
        "A routine memory check has found something worth reporting.",
        "The machine has requested that these figures be communicated.",
        "Another day, another completely unnecessary RAM report.",
        "The computer has once again decided to make its memory situation public."
    )

    $closings = @(
        "The memory has been measured. Humanity may continue.",
        "No intervention has been performed. The spreadsheet is safe.",
        "This concludes today's entirely unnecessary systems update.",
        "The RAM has spoken."
    )

    $subject = Get-RandomItem $subjects
    $opening = Get-RandomItem $openings
    $closing = Get-RandomItem $closings

    $message = @"
$($script:Config.Mention) $subject

$opening

Available RAM: $($Memory.AvailablePercent)%
Used RAM: $($Memory.UsedPercent)%
Available: $([Math]::Round($Memory.AvailableBytes / 1GB, 2)) GiB
Total RAM: $([Math]::Round($Memory.TotalBytes / 1GB, 2)) GiB

$closing

#RAMAltman
"@

    $message = ($message -replace '\r?\n', ' ').Trim()

    # Keep below the standard 280-character post limit.
    if ($message.Length -gt 275) {
        $message = $message.Substring(0, 272) + "..."
    }

    return $message
}

# ---------------------------------------------------------------------
# IFTTT integration
# ---------------------------------------------------------------------

function Send-IFTTTEvent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $true)]
        $Memory
    )

    $url = Unprotect-Secret $script:Config.ProtectedWebhookUrl

    $payload = @{
        value1 = $Message
        value2 = "Available RAM: $($Memory.AvailablePercent)%"
        value3 = "Total RAM: $([Math]::Round($Memory.TotalBytes / 1GB, 2)) GiB"
    }

    $json = $payload | ConvertTo-Json -Compress

    try {
        # Ensure TLS 1.2 is available on Windows PowerShell 5.1.
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.SecurityProtocolType]::Tls12

        $response = Invoke-WebRequest `
            -Method Post `
            -Uri $url `
            -Body $json `
            -ContentType "application/json" `
            -UseBasicParsing `
            -TimeoutSec 30

        if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
            throw "IFTTT returned HTTP status $($response.StatusCode)."
        }

        return $response.StatusCode
    } catch {
        $statusCode = $null

        if ($null -ne $_.Exception.Response) {
            try {
                $statusCode = [int]$_.Exception.Response.StatusCode
            } catch {
                $statusCode = $null
            }
        }

        if ($null -ne $statusCode) {
            throw "IFTTT request failed with HTTP status $statusCode."
        }

        throw "IFTTT request failed. Check your connection and webhook configuration."
    } finally {
        $url = $null
        $json = $null
        $payload = $null
    }
}

# ---------------------------------------------------------------------
# Execution lock
# ---------------------------------------------------------------------

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

function Exit-RunLock {
    if ($null -ne $script:LockHandle) {
        $script:LockHandle.Dispose()
        $script:LockHandle = $null
    }
}

# ---------------------------------------------------------------------
# Status
# ---------------------------------------------------------------------

function Show-Status {
    $memory = Get-MemoryInformation

    Write-Host ""
    Write-Host "RAM Altman - IFTTT Edition" -ForegroundColor Cyan
    Write-Host "--------------------------------"
    Write-Host ("Total physical RAM:     {0:N2} GiB" -f (
        $memory.TotalBytes / 1GB
    ))
    Write-Host ("Available physical RAM: {0:N2} GiB ({1:N2}%)" -f (
        $memory.AvailableBytes / 1GB
    ), $memory.AvailablePercent)
    Write-Host ("Used physical RAM:      {0:N2} GiB ({1:N2}%)" -f (
        $memory.UsedBytes / 1GB
    ), $memory.UsedPercent)

    if (Test-Path -LiteralPath $script:ConfigPath) {
        Load-Configuration

        Write-Host ""
        Write-Host "Configuration"
        Write-Host "Provider:        IFTTT"
        Write-Host "Mention:         $($script:Config.Mention)"
        Write-Host "Threshold:       $($script:Config.Threshold)%"

        $state = Get-State

        if ($state.LastWebhookDate) {
            Write-Host "Last trigger:    $($state.LastWebhookDate)"
        } else {
            Write-Host "Last trigger:    None"
        }
    } else {
        Write-Host ""
        Write-Host "Configuration: Not configured"
        Write-Host "Run .\ram-altman.ps1 -Setup"
    }

    Write-Host ""
}

# ---------------------------------------------------------------------
# Main monitoring routine
# ---------------------------------------------------------------------

function Invoke-Monitor {
    if (-not (Enter-RunLock)) {
        Write-Host "Another RAM Altman instance is already running."
        return
    }

    try {
        $memory = Get-MemoryInformation

        Write-MemorySample $memory

        Write-Host ""
        Write-Host "RAM Altman - IFTTT Edition" -ForegroundColor Cyan
        Write-Host ("Available RAM: {0:N2}% ({1:N2} GiB)" -f (
            $memory.AvailablePercent
        ), (
            $memory.AvailableBytes / 1GB
        ))

        if ($DryRun) {
            if (Test-Path -LiteralPath $script:ConfigPath) {
                Load-Configuration
            } else {
                $script:Config = @{
                    Threshold = 10
                    Mention = "@sama"
                }
            }

            $message = New-AlertMessage $memory

            Write-Host ""
            Write-Host "DRY RUN" -ForegroundColor Yellow
            Write-Host "No webhook was triggered."
            Write-Host "No daily state was changed."
            Write-Host ""
            Write-Host "Generated post:"
            Write-Host $message
            Write-Host ""

            return
        }

        Load-Configuration

        if ($memory.AvailablePercent -le $script:Config.Threshold) {
            Write-Host (
                "No alert: available RAM has not exceeded the {0}% threshold." -f
                $script:Config.Threshold
            )

            return
        }

        $today = (Get-Date).ToString("yyyy-MM-dd")
        $state = Get-State

        if ($state.LastWebhookDate -eq $today) {
            Write-Host "An IFTTT event has already been triggered today."
            return
        }

        $message = New-AlertMessage $memory

        Write-Host ""
        Write-Host "Generated post:"
        Write-Host $message
        Write-Host ""

        $statusCode = Send-IFTTTEvent `
            -Message $message `
            -Memory $memory

        Save-State -Date $today

        Write-Host "IFTTT accepted the webhook request." -ForegroundColor Green
        Write-Host "HTTP status: $statusCode"
        Write-Host "X publication has not been independently verified."
    } finally {
        Exit-RunLock
    }
}

# ---------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------

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

# ram-altman.ps1 - Windows-native port of ram-altman.sh
# Requires Windows PowerShell 5.1 or PowerShell 7+ on Windows. No WSL or third-party modules.
#
# Usage:
#   .\ram-altman.ps1            Log a sample and send the daily email if due
#   .\ram-altman.ps1 --status   Print current memory figures and exit
#   .\ram-altman.ps1 --dry-run  Print the email that would be sent and exit
#   .\ram-altman.ps1 --help     Show this help
#
# For SMTP, set RAM_ALTMAN_SMTP_HOST. Port defaults to 587 (STARTTLS).
# See the companion README for configuration.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# ----- Settings (environment variables) ---------------------------------------
$script:Recipient   = [string]$env:RAM_ALTMAN_TO
$script:Sender      = [string]$env:RAM_ALTMAN_FROM
$script:SenderName  = [string]$env:RAM_ALTMAN_FROM_NAME
$script:ThresholdText = if ($env:RAM_ALTMAN_THRESHOLD) { [string]$env:RAM_ALTMAN_THRESHOLD } else { '10' }
$script:SmtpHost    = [string]$env:RAM_ALTMAN_SMTP_HOST
$script:SmtpPort    = if ($env:RAM_ALTMAN_SMTP_PORT) { [string]$env:RAM_ALTMAN_SMTP_PORT } else { '587' }
$script:SmtpUser    = [string]$env:RAM_ALTMAN_SMTP_USER
$script:SmtpPassword = [string]$env:RAM_ALTMAN_SMTP_PASSWORD
$script:SmtpSslText = if ($env:RAM_ALTMAN_SMTP_SSL) { [string]$env:RAM_ALTMAN_SMTP_SSL } else { 'true' }
$script:CustomSendmail = [string]$env:RAM_ALTMAN_SENDMAIL
$script:MemInfoPath = [string]$env:RAM_ALTMAN_MEMINFO

if ($env:RAM_ALTMAN_STATE_DIR) {
    $script:StateDir = [string]$env:RAM_ALTMAN_STATE_DIR
} elseif ($env:XDG_STATE_HOME) {
    $script:StateDir = Join-Path $env:XDG_STATE_HOME 'ram-altman'
} elseif ($env:LOCALAPPDATA) {
    $script:StateDir = Join-Path $env:LOCALAPPDATA 'ram-altman'
} else {
    $script:StateDir = Join-Path $HOME '.local/state/ram-altman'
}

$script:UsageLog = Join-Path $script:StateDir 'usage.csv'
$script:LastSentFile = Join-Path $script:StateDir 'last_sent'
$script:MaxLogBytes = 10MB
$script:LogLinesToKeep = 50000
$script:DryRun = $false
$script:TotalKB = [long]0
$script:AvailableKB = [long]0
$script:UsedKB = [long]0
$script:FreeKB = [long]0
$script:CacheKB = [long]0
$script:AvailablePct = '0.0'
$script:EmailSubject = ''
$script:EmailBody = ''

function Stop-RamAltman {
    param([Parameter(Mandatory = $true)][string]$Message)
    [Console]::Error.WriteLine("ram-altman: $Message")
    exit 1
}

function ConvertTo-GiB {
    param([long]$Kilobytes)
    return (($Kilobytes / 1048576.0).ToString('F1', [Globalization.CultureInfo]::InvariantCulture) + ' GiB')
}

function Read-MemInfoFixture {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        Stop-RamAltman "cannot read $Path"
    }

    $values = @{
        MemTotal = [long]0; MemFree = [long]0; MemAvailable = [long]0
        Buffers = [long]0; Cached = [long]0; SReclaimable = [long]0; Shmem = [long]0
    }
    $hasAvailable = $false

    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ($line -match '^(MemTotal|MemFree|MemAvailable|Buffers|Cached|SReclaimable|Shmem):\s+(\d+)\s+kB(?:\s|$)') {
            $key = $Matches[1]
            $value = [long]::Parse($Matches[2], [Globalization.CultureInfo]::InvariantCulture)
            $values[$key] = $value
            if ($key -eq 'MemAvailable') { $hasAvailable = $true }
        }
    }

    if ($values.MemTotal -le 0) {
        Stop-RamAltman "could not find MemTotal in $Path"
    }

    # Same fallback used by the Linux script on kernels without MemAvailable.
    $cache = $values.Buffers + $values.Cached + $values.SReclaimable - $values.Shmem
    if ($cache -lt 0) { $cache = 0 }
    if (-not $hasAvailable) { $values.MemAvailable = $values.MemFree + $cache }
    if ($values.MemAvailable -gt $values.MemTotal) { $values.MemAvailable = $values.MemTotal }

    return @{
        Total = [long]$values.MemTotal
        Available = [long]$values.MemAvailable
        Free = [long]$values.MemFree
        Cache = [long]$cache
    }
}

function Read-WindowsMemory {
    # GlobalMemoryStatusEx's ullAvailPhys includes standby, free and zero pages,
    # which Windows can immediately reuse. This is the Windows equivalent of
    # the Linux MemAvailable measure used by the original script.
    if (-not ('RamAltman.NativeMemory' -as [type])) {
        $nativeCode = @'
using System;
using System.Runtime.InteropServices;
namespace RamAltman {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Auto)]
    public struct MEMORYSTATUSEX {
        public uint dwLength;
        public uint dwMemoryLoad;
        public ulong ullTotalPhys;
        public ulong ullAvailPhys;
        public ulong ullTotalPageFile;
        public ulong ullAvailPageFile;
        public ulong ullTotalVirtual;
        public ulong ullAvailVirtual;
        public ulong ullAvailExtendedVirtual;
    }
    public static class NativeMemory {
        [DllImport("kernel32.dll", SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX lpBuffer);
    }
}
'@
        Add-Type -TypeDefinition $nativeCode -ErrorAction Stop
    }

    $status = New-Object RamAltman.MEMORYSTATUSEX
    $status.dwLength = [uint32][Runtime.InteropServices.Marshal]::SizeOf($status)
    $ok = [RamAltman.NativeMemory]::GlobalMemoryStatusEx([ref]$status)
    if (-not $ok) {
        $win32Error = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
        Stop-RamAltman "GlobalMemoryStatusEx failed (Win32 error $win32Error)"
    }

    $totalKB = [long][Math]::Floor(([double]$status.ullTotalPhys) / 1024.0)
    $availableKB = [long][Math]::Floor(([double]$status.ullAvailPhys) / 1024.0)
    if ($totalKB -le 0) { Stop-RamAltman 'Windows returned an invalid total physical memory value' }

    # Windows exposes free/zero-list bytes separately through its language-
    # neutral WMI performance class. The difference to AvailableBytes represents
    # primarily reclaimable standby/cache pages.
    $freeKB = $availableKB
    try {
        $perf = Get-CimInstance -ClassName Win32_PerfRawData_PerfOS_Memory -ErrorAction Stop
        if ($null -ne $perf -and $null -ne $perf.FreeAndZeroPageListBytes) {
            $freeKB = [long][Math]::Floor(([double]$perf.FreeAndZeroPageListBytes) / 1024.0)
        }
    } catch {
        # Keep the correct total/available figures if the optional breakdown
        # counter is unavailable (for example, a disabled WMI performance class).
        $freeKB = $availableKB
    }

    if ($freeKB -gt $availableKB) { $freeKB = $availableKB }
    $cacheKB = $availableKB - $freeKB
    return @{
        Total = $totalKB
        Available = $availableKB
        Free = $freeKB
        Cache = $cacheKB
    }
}

function Read-Memory {
    if ($script:MemInfoPath) {
        $memory = Read-MemInfoFixture -Path $script:MemInfoPath
    } else {
        $memory = Read-WindowsMemory
    }

    $script:TotalKB = [long]$memory.Total
    $script:AvailableKB = [long]$memory.Available
    $script:FreeKB = [long]$memory.Free
    $script:CacheKB = [long]$memory.Cache
    $script:UsedKB = $script:TotalKB - $script:AvailableKB
    $script:AvailablePct = (($script:AvailableKB * 100.0) / $script:TotalKB).ToString('F1', [Globalization.CultureInfo]::InvariantCulture)
}

function Test-OverThreshold {
    # Strictly greater-than, matching the Linux implementation (10.0% is not over 10%).
    return (([decimal]$script:AvailableKB * [decimal]100) -gt ($script:Threshold * [decimal]$script:TotalKB))
}

function Show-Status {
    Write-Output ('Total:      {0}' -f (ConvertTo-GiB $script:TotalKB))
    Write-Output ('Used:       {0}' -f (ConvertTo-GiB $script:UsedKB))
    Write-Output ('Available:  {0} ({1}%)' -f (ConvertTo-GiB $script:AvailableKB), $script:AvailablePct)
    Write-Output ('  Free:     {0}' -f (ConvertTo-GiB $script:FreeKB))
    Write-Output ('  Cache:    {0}' -f (ConvertTo-GiB $script:CacheKB))
}

function Write-UsageSample {
    [void][System.IO.Directory]::CreateDirectory($script:StateDir)
    if (-not (Test-Path -LiteralPath $script:UsageLog -PathType Leaf)) {
        [System.IO.File]::WriteAllText(
            $script:UsageLog,
            "timestamp,total_kb,used_kb,available_kb,available_pct`r`n",
            [System.Text.UTF8Encoding]::new($false)
        )
    }

    $now = [DateTimeOffset]::Now
    $timestamp = $now.ToString("yyyy-MM-dd'T'HH:mm:ss", [Globalization.CultureInfo]::InvariantCulture) + $now.ToString('zzz').Replace(':', '')
    $row = '{0},{1},{2},{3},{4}{5}' -f $timestamp, $script:TotalKB, $script:UsedKB, $script:AvailableKB, $script:AvailablePct, "`r`n"
    [System.IO.File]::AppendAllText($script:UsageLog, $row, [System.Text.UTF8Encoding]::new($false))

    if ((Get-Item -LiteralPath $script:UsageLog).Length -gt $script:MaxLogBytes) {
        $lines = [System.IO.File]::ReadAllLines($script:UsageLog)
        $tailCount = [Math]::Min($script:LogLinesToKeep, [Math]::Max(0, $lines.Length - 1))
        $kept = @()
        if ($lines.Length -gt 0) { $kept += $lines[0] }
        if ($tailCount -gt 0) { $kept += $lines[($lines.Length - $tailCount)..($lines.Length - 1)] }
        $tmp = $script:UsageLog + '.tmp'
        [System.IO.File]::WriteAllLines($tmp, [string[]]$kept, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $tmp -Destination $script:UsageLog -Force
    }
}

function Get-ShuffledIndices {
    param([int]$Count)
    $items = [System.Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $Count; $i++) { $items.Add($i) }
    # Fisher-Yates shuffle.
    for ($i = $items.Count - 1; $i -gt 0; $i--) {
        $j = Get-Random -Minimum 0 -Maximum ($i + 1)
        $tmp = $items[$i]
        $items[$i] = $items[$j]
        $items[$j] = $tmp
    }
    return $items.ToArray()
}

function Get-MessageIndex {
    param([string]$Name, [int]$Count)
    if ($script:DryRun) {
        return (Get-Random -Minimum 0 -Maximum $Count)
    }

    $bagPath = Join-Path $script:StateDir ("bag_{0}" -f $Name)
    $lastPath = $bagPath + '.last'
    $bag = @()

    if (Test-Path -LiteralPath $bagPath -PathType Leaf) {
        $bag = @([System.IO.File]::ReadAllLines($bagPath) | Where-Object { $_ -match '^\d+$' } | ForEach-Object { [int]$_ })
    }

    if ($bag.Count -eq 0) {
        $bag = @(Get-ShuffledIndices -Count $Count)
        $last = ''
        if (Test-Path -LiteralPath $lastPath -PathType Leaf) {
            $last = ([System.IO.File]::ReadAllText($lastPath)).Trim()
        }
        # Prevent a round boundary from repeating the previous round's last item.
        if ($Count -gt 1 -and [string]$bag[0] -eq $last) {
            $bag = @($bag[1..($bag.Count - 1)] + $bag[0])
        }
    }

    $next = [int]$bag[0]
    if ($bag.Count -gt 1) {
        $remaining = [string[]]($bag | Select-Object -Skip 1 | ForEach-Object { [string]$_ })
        [System.IO.File]::WriteAllLines($bagPath, $remaining, [System.Text.UTF8Encoding]::new($false))
    } else {
        [System.IO.File]::WriteAllText($bagPath, '', [System.Text.UTF8Encoding]::new($false))
    }
    [System.IO.File]::WriteAllText($lastPath, [string]$next, [System.Text.UTF8Encoding]::new($false))

    # Covers message lists being shortened after a bag was dealt.
    if ($next -ge $Count) { $next = Get-Random -Minimum 0 -Maximum $Count }
    return $next
}

function New-RamAltmanEmail {
    $total = ConvertTo-GiB $script:TotalKB
    $available = ConvertTo-GiB $script:AvailableKB
    $pct = $script:AvailablePct

    $subjects = @(
        'Good news: we found some RAM',
        'Unused RAM detected in the wild',
        'RAM sighting on my PC',
        "$available of RAM, just sitting there",
        'You missed a spot',
        'Daily RAM census: some survived',
        "$pct% of my RAM remains at large",
        "Still not all of it, I'm afraid"
    )

    $bodies = @(
        "I'm writing to report that you appear to have missed some. This PC has $total of RAM and $available of it ($pct%) is currently available. I assume this is an oversight.",
        "A routine inspection of my PC found $available of unclaimed RAM out of $total. That's $pct% of the machine doing absolutely nothing. I thought you'd want to know before someone tries to train something on it.",
        "Daily status report:`r`n`r`n  Total RAM:     $total`r`n  Available:     $available ($pct%)`r`n  Threat level:  someone at OpenAI might notice",
        "Even with every browser tab I own open, $available of my $total of RAM is still available. I'm as surprised as you are.",
        "Please don't be alarmed, but there is $available of RAM on my desk that isn't in a data centre. That's $pct% of what's installed here, and as far as I can tell it has no plans today.",
        "Before you ask: yes, I counted the page cache as available. The kernel gives it back the moment anyone asks, which leaves $available of $total up for grabs.",
        "Today's forecast for my PC: clear skies, light workloads and $pct% available memory. Expect $available of the installed $total to stay idle through the evening.",
        "I hear RAM is hard to come by these days, so it feels a bit rude to be sitting on $available of it. Total installed: $total. It's not for sale, I just like knowing it's there.",
        "I have a confession. I have $available of RAM that I'm not using, which is $pct% of the $total in this PC. I've told nobody but you and a cron job.",
        "If $available of RAM sits idle in a PC and nobody allocates it, does it still count as capacity? Asking on behalf of the $pct% of my memory with nothing to do."
    )

    $signoffs = @(
        'Yours in abundance,',
        'Regards from the last free RAM in the county,',
        'Hoarding responsibly,',
        'Stay allocated,',
        'Yours, with memory to spare,',
        'Kind regards,'
    )

    $subjectIndex = Get-MessageIndex -Name 'subject' -Count $subjects.Count
    $bodyIndex = Get-MessageIndex -Name 'body' -Count $bodies.Count
    $signoffIndex = Get-MessageIndex -Name 'signoff' -Count $signoffs.Count

    $body = @(
        'Hi Sam,',
        '',
        $bodies[$bodyIndex],
        '',
        $signoffs[$signoffIndex],
        $(if ($script:SenderName) { $script:SenderName } else { 'A concerned RAM owner' }),
        '',
        '--',
        '',
        'Sent automatically, at most once a day, by a small script on one PC.',
        "Reply if you'd like it to stop."
    ) -join "`r`n"

    return [pscustomobject]@{
        Subject = [string]$subjects[$subjectIndex]
        Body = [string]$body
    }
}

function Assert-SafeHeaderValue {
    param([string]$Value, [string]$Label)
    if ($Value -match '[\r\n]') { Stop-RamAltman "$Label must not contain a line break" }
}

function ConvertTo-EncodedHeaderWord {
    param([string]$Value)
    if ([string]::IsNullOrEmpty($Value)) { return '' }
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    return '=?UTF-8?B?' + [Convert]::ToBase64String($bytes) + '?='
}

function Get-RawMailMessage {
    param([string]$Subject, [string]$Body)
    Assert-SafeHeaderValue -Value $script:Sender -Label 'sender address'
    Assert-SafeHeaderValue -Value $script:Recipient -Label 'recipient address'
    Assert-SafeHeaderValue -Value $script:SenderName -Label 'sender name'
    $from = $script:Sender
    if ($script:SenderName) { $from = (ConvertTo-EncodedHeaderWord $script:SenderName) + " <$($script:Sender)>" }
    $dateHeader = [DateTimeOffset]::Now.ToString('r', [Globalization.CultureInfo]::InvariantCulture)
    return @(
        "From: $from",
        "To: $($script:Recipient)",
        "Subject: $Subject",
        "Date: $dateHeader",
        'MIME-Version: 1.0',
        'Content-Type: text/plain; charset=UTF-8',
        'Content-Transfer-Encoding: 8bit',
        'Auto-Submitted: auto-generated',
        '',
        $Body,
        ''
    ) -join "`r`n"
}

function Invoke-ExternalMailCommand {
    param([string]$CommandPath, [string]$Arguments, [string]$Message)

    $resolved = (Resolve-Path -LiteralPath $CommandPath -ErrorAction Stop).Path
    $extension = [System.IO.Path]::GetExtension($resolved).ToLowerInvariant()
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.CreateNoWindow = $true

    if ($extension -eq '.cmd' -or $extension -eq '.bat') {
        $psi.FileName = $env:ComSpec
        $psi.Arguments = '/d /s /c ""' + $resolved + '" ' + $Arguments + '"'
    } elseif ($extension -eq '.ps1') {
        $powershell = Join-Path $PSHOME 'powershell.exe'
        if (-not (Test-Path -LiteralPath $powershell)) {
            $powershell = (Get-Command pwsh.exe -ErrorAction Stop).Source
        }
        $psi.FileName = $powershell
        $psi.Arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $resolved + '" ' + $Arguments
    } else {
        $psi.FileName = $resolved
        $psi.Arguments = $Arguments
    }

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi
    if (-not $process.Start()) { return $false }
    $messageBytes = [System.Text.Encoding]::UTF8.GetBytes($Message)
    $process.StandardInput.BaseStream.Write($messageBytes, 0, $messageBytes.Length)
    $process.StandardInput.BaseStream.Flush()
    $process.StandardInput.Close()
    $process.WaitForExit()
    return ($process.ExitCode -eq 0)
}

function Send-RamAltmanEmail {
    param([string]$Subject, [string]$Body)

    # Optional sendmail-compatible executable, useful with Windows ports of
    # sendmail/msmtp and for local SMTP relay tools. It receives RFC-style mail
    # on stdin, just like the Linux sendmail -t -i path.
    $sendmailPath = $script:CustomSendmail
    if (-not $sendmailPath) {
        $sendmailCommand = Get-Command sendmail.exe -ErrorAction SilentlyContinue
        if (-not $sendmailCommand) { $sendmailCommand = Get-Command msmtp.exe -ErrorAction SilentlyContinue }
        if ($sendmailCommand) { $sendmailPath = $sendmailCommand.Source }
    }
    if ($sendmailPath) {
        $rawMessage = Get-RawMailMessage -Subject $Subject -Body $Body
        try { return (Invoke-ExternalMailCommand -CommandPath $sendmailPath -Arguments '-t -i' -Message $rawMessage) }
        catch { [Console]::Error.WriteLine("ram-altman: sendmail command failed: $($_.Exception.Message)"); return $false }
    }

    # Native SMTP requires no extra executable or module. Authentication is
    # optional for trusted LAN relays; SSL uses STARTTLS (normally port 587).
    if (-not $script:SmtpHost) {
        [Console]::Error.WriteLine('ram-altman: no sendmail.exe found and RAM_ALTMAN_SMTP_HOST is not set')
        return $false
    }

    $port = 0
    if (-not [int]::TryParse($script:SmtpPort, [ref]$port) -or $port -lt 1 -or $port -gt 65535) {
        [Console]::Error.WriteLine('ram-altman: RAM_ALTMAN_SMTP_PORT must be between 1 and 65535')
        return $false
    }
    $enableSsl = $false
    if (-not [bool]::TryParse($script:SmtpSslText, [ref]$enableSsl)) {
        [Console]::Error.WriteLine('ram-altman: RAM_ALTMAN_SMTP_SSL must be true or false')
        return $false
    }

    $message = $null
    $client = $null
    try {
        if ($script:SenderName) {
            $fromAddress = [System.Net.Mail.MailAddress]::new($script:Sender, $script:SenderName, [System.Text.Encoding]::UTF8)
        } else {
            $fromAddress = [System.Net.Mail.MailAddress]::new($script:Sender)
        }
        $message = New-Object System.Net.Mail.MailMessage
        $message.From = $fromAddress
        [void]$message.To.Add($script:Recipient)
        $message.Subject = $Subject
        $message.SubjectEncoding = [System.Text.Encoding]::UTF8
        $message.Body = $Body
        $message.BodyEncoding = [System.Text.Encoding]::UTF8
        $message.IsBodyHtml = $false
        $message.Headers.Add('Auto-Submitted', 'auto-generated')

        $client = [System.Net.Mail.SmtpClient]::new($script:SmtpHost, $port)
        $client.EnableSsl = $enableSsl
        $client.Timeout = 30000
        $client.UseDefaultCredentials = $false
        if ($script:SmtpUser) {
            $client.Credentials = [System.Net.NetworkCredential]::new($script:SmtpUser, $script:SmtpPassword)
        }
        $client.Send($message)
        return $true
    } catch {
        [Console]::Error.WriteLine("ram-altman: SMTP send failed: $($_.Exception.Message)")
        return $false
    } finally {
        if ($null -ne $client) { $client.Dispose() }
        if ($null -ne $message) { $message.Dispose() }
    }
}

function Enter-StateLock {
    $lockPath = Join-Path $script:StateDir 'lock'
    try {
        return [System.IO.File]::Open($lockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
    } catch [System.IO.IOException] {
        # Another instance holds the exclusive handle. Match flock -n: do nothing.
        return $null
    }
}

function Show-Help {
    $helpText = @'
ram-altman.ps1 - track RAM usage and, at most once a day, tell Sam Altman
when this PC has RAM to spare.

Usage:
  ram-altman.ps1            Log a sample and send the daily email if due
  ram-altman.ps1 --status   Print current memory figures and exit
  ram-altman.ps1 --dry-run  Print the email that would be sent and exit
  ram-altman.ps1 --help     Show this help

Memory calculation:
  used = MemTotal - MemAvailable
  On Windows, MemAvailable is taken from GlobalMemoryStatusEx and includes
  standby, free and zero-page memory that Windows can immediately reuse.

Required for sending:
  RAM_ALTMAN_TO, RAM_ALTMAN_FROM
  RAM_ALTMAN_SMTP_HOST (unless sendmail.exe or RAM_ALTMAN_SENDMAIL is available)

Optional SMTP settings:
  RAM_ALTMAN_SMTP_PORT       Default: 587
  RAM_ALTMAN_SMTP_USER       Optional SMTP username
  RAM_ALTMAN_SMTP_PASSWORD   Optional SMTP password
  RAM_ALTMAN_SMTP_SSL        Default: true (STARTTLS)
  RAM_ALTMAN_FROM_NAME       Optional display name
  RAM_ALTMAN_THRESHOLD      Default: 10 (send only when strictly above this %)
  RAM_ALTMAN_STATE_DIR      Default: %LOCALAPPDATA%\ram-altman
  RAM_ALTMAN_MEMINFO        Optional Linux-style meminfo fixture (mainly for testing)
'@
    Write-Output $helpText
}

function Invoke-Main {
    param([string[]]$CliArgs)
    $option = if ($CliArgs.Count -gt 0) { [string]$CliArgs[0] } else { '' }
    switch ($option) {
        '--status' {
            Read-Memory
            Show-Status
            return
        }
        '--dry-run' {
            $script:DryRun = $true
            Read-Memory
            Show-Status
            if (-not (Test-OverThreshold)) {
                Write-Output "No email: available RAM is not above $($script:ThresholdText)%."
                return
            }
            $email = New-RamAltmanEmail
            if (-not $script:Recipient) { $script:Recipient = 'recipient-not-set@example.com' }
            if (-not $script:Sender) { $script:Sender = 'sender-not-set@example.com' }
            Write-Output ''
            Get-RawMailMessage -Subject $email.Subject -Body $email.Body | Write-Output
            return
        }
        { $_ -eq '-h' -or $_ -eq '--help' } {
            Show-Help
            return
        }
        '' { }
        default { Stop-RamAltman "unknown option: $option (try --help)" }
    }

    if (-not $script:Recipient) { Stop-RamAltman 'RAM_ALTMAN_TO is not set' }
    if (-not $script:Sender) { Stop-RamAltman 'RAM_ALTMAN_FROM is not set' }

    $threshold = [decimal]0
    if (-not [decimal]::TryParse($script:ThresholdText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$threshold)) {
        Stop-RamAltman 'RAM_ALTMAN_THRESHOLD must be a number (use a dot as decimal separator)'
    }
    $script:Threshold = $threshold

    [void][System.IO.Directory]::CreateDirectory($script:StateDir)
    $lock = Enter-StateLock
    if ($null -eq $lock) { return }

    try {
        Read-Memory
        Write-UsageSample
        if (-not (Test-OverThreshold)) { return }

        $today = [DateTime]::Now.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
        $lastSent = ''
        if (Test-Path -LiteralPath $script:LastSentFile -PathType Leaf) {
            $lastSent = ([System.IO.File]::ReadAllText($script:LastSentFile)).Trim()
        }
        if ($lastSent -eq $today) { return }

        $email = New-RamAltmanEmail
        if (-not (Send-RamAltmanEmail -Subject $email.Subject -Body $email.Body)) {
            Stop-RamAltman 'email failed to send; will try again on the next run'
        }

        # Only record successful sends, so a failed send is retried next run.
        [System.IO.File]::WriteAllText($script:LastSentFile, $today, [System.Text.UTF8Encoding]::new($false))
    } finally {
        if ($null -ne $lock) { $lock.Dispose() }
    }
}

# Resolve/validate the threshold before it is used. Status and dry-run do not
# need mail configuration, matching the Linux script.
$script:Threshold = [decimal]0
if (-not [decimal]::TryParse($script:ThresholdText, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$script:Threshold)) {
    if ($args.Count -gt 0 -and $args[0] -in @('--status', '--dry-run', '--help', '-h')) {
        # The threshold is irrelevant for --status/help; --dry-run will report it
        # when the comparison is attempted. Keep malformed values from silently
        # changing the threshold.
        if ($args[0] -ne '--status' -and $args[0] -notin @('--help', '-h')) {
            Stop-RamAltman 'RAM_ALTMAN_THRESHOLD must be a number (use a dot as decimal separator)'
        }
    } else {
        Stop-RamAltman 'RAM_ALTMAN_THRESHOLD must be a number (use a dot as decimal separator)'
    }
}

Invoke-Main -CliArgs $args

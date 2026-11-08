# test-ram-altman.ps1 - Windows-native regression tests for ram-altman.ps1
# Requires Windows PowerShell 5.1 or PowerShell 7+ on Windows.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$script:TargetScript = Join-Path $PSScriptRoot 'ram-altman.ps1'
if (-not (Test-Path -LiteralPath $script:TargetScript -PathType Leaf)) {
    throw "Cannot find $script:TargetScript"
}

$powerShellCommand = Get-Command powershell.exe -ErrorAction SilentlyContinue
if (-not $powerShellCommand) { $powerShellCommand = Get-Command pwsh.exe -ErrorAction SilentlyContinue }
if (-not $powerShellCommand) { throw 'Could not find powershell.exe or pwsh.exe' }
$script:PowerShellExe = $powerShellCommand.Source

$script:Work = Join-Path ([System.IO.Path]::GetTempPath()) ('ram-altman-test-' + [Guid]::NewGuid().ToString('N'))
$script:BinDir = Join-Path $script:Work 'bin'
$script:StateDir = Join-Path $script:Work 'state'
$script:MemInfo = Join-Path $script:Work 'meminfo'
$script:Outbox = Join-Path $script:Work 'outbox'
$script:FailMarker = Join-Path $script:Work 'fail'
$script:FakeSendmail = Join-Path $script:BinDir 'fake-sendmail.cmd'
$script:PassCount = 0
$script:FailCount = 0

$environmentNames = @(
    'RAM_ALTMAN_TO', 'RAM_ALTMAN_FROM', 'RAM_ALTMAN_FROM_NAME',
    'RAM_ALTMAN_THRESHOLD', 'RAM_ALTMAN_STATE_DIR', 'RAM_ALTMAN_MEMINFO',
    'RAM_ALTMAN_SENDMAIL', 'RAM_ALTMAN_SMTP_HOST', 'RAM_ALTMAN_SMTP_PORT',
    'RAM_ALTMAN_SMTP_USER', 'RAM_ALTMAN_SMTP_PASSWORD', 'RAM_ALTMAN_SMTP_SSL',
    'RAM_ALTMAN_TEST_OUTBOX', 'RAM_ALTMAN_TEST_FAIL'
)
$oldEnvironment = @{}
foreach ($name in $environmentNames) { $oldEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }

function Set-MemoryFixture {
    param(
        [long]$Total,
        [long]$Free,
        [Nullable[long]]$Available,
        [long]$Buffers,
        [long]$Cached,
        [long]$Slab,
        [long]$Shmem
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("MemTotal:       $Total kB")
    $lines.Add("MemFree:        $Free kB")
    if ($null -ne $Available) { $lines.Add("MemAvailable:   $Available kB") }
    $lines.Add("Buffers:        $Buffers kB")
    $lines.Add("Cached:         $Cached kB")
    $lines.Add('SwapCached:     999999 kB')
    $lines.Add("SReclaimable:   $Slab kB")
    $lines.Add("Shmem:          $Shmem kB")
    [System.IO.File]::WriteAllLines($script:MemInfo, $lines.ToArray(), [System.Text.UTF8Encoding]::new($false))
}

function Invoke-Monitor {
    param([string[]]$Arguments = @())
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = @(& $script:PowerShellExe -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script:TargetScript @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
    }
    return [pscustomobject]@{
        ExitCode = $exitCode
        Output = ($output | ForEach-Object { [string]$_ }) -join "`n"
    }
}

function Get-SentCount {
    if (-not (Test-Path -LiteralPath $script:Outbox -PathType Leaf)) { return 0 }
    $content = [System.IO.File]::ReadAllText($script:Outbox)
    return [regex]::Matches($content, '(?m)^=====END=====$').Count
}

function Assert-Equal {
    param([string]$Name, [object]$Actual, [object]$Expected)
    if ([string]$Actual -ceq [string]$Expected) {
        $script:PassCount++
        Write-Output "ok    $Name"
    } else {
        $script:FailCount++
        Write-Output "FAIL  $Name (expected '$Expected', got '$Actual')"
    }
}

function Assert-True {
    param([string]$Name, [bool]$Condition, [string]$Detail = '')
    if ($Condition) {
        $script:PassCount++
        Write-Output "ok    $Name"
    } else {
        $script:FailCount++
        Write-Output "FAIL  $Name $Detail"
    }
}

try {
    [void][System.IO.Directory]::CreateDirectory($script:BinDir)
    [void][System.IO.Directory]::CreateDirectory($script:StateDir)

    $fakeScript = @'
@echo off
if defined RAM_ALTMAN_TEST_FAIL if exist "%RAM_ALTMAN_TEST_FAIL%" exit /b 75
findstr /R "^" >> "%RAM_ALTMAN_TEST_OUTBOX%"
echo =====END=====>>"%RAM_ALTMAN_TEST_OUTBOX%"
exit /b 0
'@
    [System.IO.File]::WriteAllText($script:FakeSendmail, $fakeScript, [System.Text.Encoding]::ASCII)

    $env:RAM_ALTMAN_TO = 'to@example.com'
    $env:RAM_ALTMAN_FROM = 'from@example.com'
    $env:RAM_ALTMAN_FROM_NAME = ''
    $env:RAM_ALTMAN_STATE_DIR = $script:StateDir
    $env:RAM_ALTMAN_MEMINFO = $script:MemInfo
    $env:RAM_ALTMAN_SENDMAIL = $script:FakeSendmail
    $env:RAM_ALTMAN_TEST_OUTBOX = $script:Outbox
    $env:RAM_ALTMAN_TEST_FAIL = $script:FailMarker
    $env:RAM_ALTMAN_THRESHOLD = '10'
    Remove-Item Env:RAM_ALTMAN_SMTP_HOST -ErrorAction SilentlyContinue

    # Mostly page cache: little is free, but plenty is available.
    Set-MemoryFixture -Total 16000000 -Free 300000 -Available 9000000 -Buffers 200000 -Cached 8000000 -Slab 500000 -Shmem 100000
    $null = Invoke-Monitor
    Assert-Equal 'cache counts as available: email sent' (Get-SentCount) 1
    $null = Invoke-Monitor
    $null = Invoke-Monitor
    Assert-Equal 'second and third run same day: no more email' (Get-SentCount) 1

    $csvLines = [System.IO.File]::ReadAllLines((Join-Path $script:StateDir 'usage.csv'))
    $lastFields = $csvLines[$csvLines.Length - 1].Split(',')
    Assert-Equal 'used = total - available' $lastFields[2] 7000000
    Assert-Equal 'three samples logged' ($csvLines.Length - 1) 3

    # Next day, tight on memory.
    [System.IO.File]::WriteAllText((Join-Path $script:StateDir 'last_sent'), '2000-01-01', [System.Text.Encoding]::ASCII)
    Set-MemoryFixture -Total 16000000 -Free 300000 -Available 1000000 -Buffers 100000 -Cached 800000 -Slab 100000 -Shmem 100000
    $null = Invoke-Monitor
    Assert-Equal '6.2% available: no email' (Get-SentCount) 1

    # Exactly 10% is not over 10%.
    Set-MemoryFixture -Total 16000000 -Free 300000 -Available 1600000 -Buffers 100000 -Cached 800000 -Slab 100000 -Shmem 100000
    $null = Invoke-Monitor
    Assert-Equal 'exactly 10%: no email' (Get-SentCount) 1
    Set-MemoryFixture -Total 16000000 -Free 300000 -Available 1600001 -Buffers 100000 -Cached 800000 -Slab 100000 -Shmem 100000
    $null = Invoke-Monitor
    Assert-Equal 'just over 10%: email sent' (Get-SentCount) 2

    # A failed send is retried, and only recorded once it works.
    [System.IO.File]::WriteAllText((Join-Path $script:StateDir 'last_sent'), '2000-01-01', [System.Text.Encoding]::ASCII)
    [System.IO.File]::WriteAllText($script:FailMarker, 'fail', [System.Text.Encoding]::ASCII)
    $failed = Invoke-Monitor
    Assert-Equal 'failed send exits non-zero' $failed.ExitCode 1
    Assert-Equal 'failed send not recorded' ([System.IO.File]::ReadAllText((Join-Path $script:StateDir 'last_sent'))) '2000-01-01'
    Remove-Item -LiteralPath $script:FailMarker -Force
    $null = Invoke-Monitor
    Assert-Equal 'retry succeeds' (Get-SentCount) 3

    # Old kernel with no MemAvailable: free + buffers + cached + slab - shmem.
    # SwapCached in the fixture must not be picked up as Cached.
    Set-MemoryFixture -Total 16000000 -Free 1000000 -Available $null -Buffers 200000 -Cached 3000000 -Slab 500000 -Shmem 700000
    $fallback = Invoke-Monitor -Arguments @('--status')
    $availableLine = ($fallback.Output -split "`n" | Where-Object { $_ -match '^Available:' } | Select-Object -First 1).Trim()
    Assert-Equal 'fallback estimate' $availableLine 'Available:  3.8 GiB (25.0%)'

    # Variety: 10 bodies should all appear across 10 days, with no back-to-back repeat.
    Remove-Item -LiteralPath $script:Outbox -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath $script:StateDir -Filter 'bag_*' -ErrorAction SilentlyContinue | Remove-Item -Force
    Set-MemoryFixture -Total 16000000 -Free 300000 -Available 9000000 -Buffers 200000 -Cached 8000000 -Slab 500000 -Shmem 100000
    for ($i = 0; $i -lt 40; $i++) {
        [System.IO.File]::WriteAllText((Join-Path $script:StateDir 'last_sent'), '2000-01-01', [System.Text.Encoding]::ASCII)
        $result = Invoke-Monitor
        if ($result.ExitCode -ne 0) { throw "monitor failed during message rotation test: $($result.Output)" }
    }

    $outboxText = [System.IO.File]::ReadAllText($script:Outbox)
    $bodies = @()
    foreach ($message in ($outboxText -split '=====END=====\r?\n')) {
        $match = [regex]::Match($message, '(?ms)^Hi Sam,\r?\n\r?\n(.*?)(?:\r?\n)')
        if ($match.Success) { $bodies += $match.Groups[1].Value }
    }
    $uniqueFirstTen = @($bodies | Select-Object -First 10 | Sort-Object -Unique).Count
    Assert-Equal 'all opening lines used' $uniqueFirstTen 10
    $hasAdjacentRepeat = $false
    for ($i = 1; $i -lt $bodies.Count; $i++) {
        if ($bodies[$i] -ceq $bodies[$i - 1]) { $hasAdjacentRepeat = $true; break }
    }
    Assert-True 'no back-to-back repeat' (-not $hasAdjacentRepeat)

    # Config errors.
    $env:RAM_ALTMAN_TO = ''
    $configError = Invoke-Monitor
    Assert-Equal 'missing recipient refused' $configError.ExitCode 1
    $env:RAM_ALTMAN_TO = 'to@example.com'

    Write-Output ''
    Write-Output ("$($script:PassCount) passed, $($script:FailCount) failed")
    Write-Output ''
    Write-Output '--- real machine status ---'
    Remove-Item Env:RAM_ALTMAN_MEMINFO -ErrorAction SilentlyContinue
    $realStatus = Invoke-Monitor -Arguments @('--status')
    Write-Output $realStatus.Output
    Assert-Equal 'real machine status exits successfully' $realStatus.ExitCode 0

    Write-Output ''
    Write-Output '--- sample dry run ---'
    $env:RAM_ALTMAN_MEMINFO = $script:MemInfo
    $dryRun = Invoke-Monitor -Arguments @('--dry-run')
    Write-Output $dryRun.Output
    Assert-Equal 'dry run exits successfully' $dryRun.ExitCode 0

    Write-Output ''
    Write-Output ("Final result: $($script:PassCount) passed, $($script:FailCount) failed")
    if ($script:FailCount -gt 0) { exit 1 }
} finally {
    foreach ($name in $environmentNames) {
        [Environment]::SetEnvironmentVariable($name, $oldEnvironment[$name], 'Process')
    }
    Remove-Item -LiteralPath $script:Work -Recurse -Force -ErrorAction SilentlyContinue
}

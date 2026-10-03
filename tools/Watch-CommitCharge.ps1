#Requires -Version 5.1
<#
.SYNOPSIS
    Samples Windows commit charge and per-process commit size over time.

.DESCRIPTION
    Built to answer one question: when system commit charge climbs toward the
    limit, which processes are holding it?

    Commit charge is a reservation against RAM + pagefile. It is NOT the same as
    RAM in use. A process can hold tens of GB of commit while its working set is
    nearly zero -- which is exactly what a hung JVM looks like. This script tracks
    both, plus CPU-time delta, so a frozen process is distinguishable from a busy
    one.

    Writes two CSVs:
      commit-system.csv     one row per sample, system totals
      commit-processes.csv  one row per tracked process per sample

.PARAMETER IntervalSeconds
    Seconds between samples. Default 60.

.PARAMETER DurationMinutes
    Stop after this many minutes. 0 = run until Ctrl+C. Default 0.

.PARAMETER TopN
    Number of top processes by private bytes to record each sample. Default 15.

.PARAMETER WarnPercent
    Emit a console warning when commit charge exceeds this percent of the limit.
    Default 80.

.PARAMETER Snapshot
    Take a single sample, print it, and exit. No CSV written.

.PARAMETER OutputDir
    Directory for the CSVs. Resolution order: explicit parameter, then
    FE_COMMIT_LOG_DIR env var, then secrets file, then .\reports.

.EXAMPLE
    .\Watch-CommitCharge.ps1 -Snapshot
    Immediate look at current commit state and any orphaned JVMs.

.EXAMPLE
    .\Watch-CommitCharge.ps1 -IntervalSeconds 30
    Start before launching the pack. Leave running. Ctrl+C when done.
#>

[CmdletBinding()]
param(
    [int]    $IntervalSeconds = 60,
    [int]    $DurationMinutes = 0,
    [int]    $TopN            = 15,
    [double] $WarnPercent     = 80,
    [switch] $Snapshot,
    [string] $OutputDir
)

$ScriptVersion = '1.0.0'
Write-Host "Watch-CommitCharge.ps1 v$ScriptVersion" -ForegroundColor Cyan

# --------------------------------------------------------------------------
# Config resolution: explicit param -> env var -> secrets file -> default
# --------------------------------------------------------------------------

$sharedModule = Join-Path $PSScriptRoot 'PackConfig.ps1'
if (Test-Path -LiteralPath $sharedModule) {
    . $sharedModule
    Write-Host "  loaded PackConfig.ps1" -ForegroundColor DarkGray
}

function Resolve-Setting {
    param(
        [string] $ParamName,
        [string] $EnvName,
        [string] $SecretKey,
        [string] $Default
    )
    # Explicit parameter always wins.
    if ($PSBoundParameters.ContainsKey($ParamName)) {
        return (Get-Variable -Name $ParamName -ValueOnly -Scope 1)
    }
    $envVal = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not [string]::IsNullOrWhiteSpace($envVal)) { return $envVal }

    $secretsPath = Join-Path $PSScriptRoot 'secrets.local.env'
    if (Test-Path -LiteralPath $secretsPath) {
        foreach ($line in [IO.File]::ReadAllLines($secretsPath)) {
            if ($line -match "^\s*$([regex]::Escape($SecretKey))\s*=\s*'?([^']*)'?\s*$") {
                if (-not [string]::IsNullOrWhiteSpace($Matches[1])) { return $Matches[1] }
            }
        }
    }
    return $Default
}

if (-not $Snapshot) {
    if (-not $PSBoundParameters.ContainsKey('OutputDir')) {
        $OutputDir = Resolve-Setting -ParamName 'OutputDir' `
                                     -EnvName   'FE_COMMIT_LOG_DIR' `
                                     -SecretKey 'FE_COMMIT_LOG_DIR' `
                                     -Default   (Join-Path $PSScriptRoot 'reports')
    }
    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $systemCsv  = Join-Path $OutputDir 'commit-system.csv'
    $processCsv = Join-Path $OutputDir 'commit-processes.csv'
    Write-Host "  output: $OutputDir" -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------
# Sampling
# --------------------------------------------------------------------------

# Win32_OperatingSystem is locale-independent, unlike Get-Counter path names.
#   TotalVirtualMemorySize = commit limit (KB)
#   FreeVirtualMemory      = available commit (KB)
function Get-CommitState {
    $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    $limitMB  = [math]::Round($os.TotalVirtualMemorySize / 1KB, 1)
    $freeMB   = [math]::Round($os.FreeVirtualMemory      / 1KB, 1)
    $chargeMB = [math]::Round($limitMB - $freeMB, 1)
    [pscustomobject]@{
        CommitLimitMB  = $limitMB
        CommitChargeMB = $chargeMB
        CommitPct      = if ($limitMB -gt 0) { [math]::Round(100 * $chargeMB / $limitMB, 2) } else { 0 }
        PhysTotalMB    = [math]::Round($os.TotalVisibleMemorySize / 1KB, 1)
        PhysFreeMB     = [math]::Round($os.FreePhysicalMemory     / 1KB, 1)
        PagefileMB     = [math]::Round(($os.TotalVirtualMemorySize - $os.TotalVisibleMemorySize) / 1KB, 1)
    }
}

# Command lines let us tell the MC client from the dedicated server.
function Get-JavaCommandLines {
    $map = @{}
    try {
        $rows = Get-CimInstance -ClassName Win32_Process `
                                -Filter "Name='java.exe' OR Name='javaw.exe'" `
                                -ErrorAction Stop
        foreach ($r in $rows) { $map[[int]$r.ProcessId] = $r.CommandLine }
    } catch {
        Write-Verbose "Could not read command lines: $($_.Exception.Message)"
    }
    return $map
}

function Get-JvmRole {
    param([string] $CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return 'unknown' }
    if ($CommandLine -match 'nogui|forge_everything_server|server\.jar') { return 'server' }
    if ($CommandLine -match 'ModrinthApp|MojangTricksIntelDrivers|net\.minecraft\.client') { return 'client' }
    if ($CommandLine -match '-Xmx(\d+)G')  { return "jvm-$($Matches[1])G" }
    if ($CommandLine -match '-Xmx(\d+)M')  { return "jvm-$([math]::Round([int]$Matches[1]/1024))G" }
    return 'jvm'
}

# CPU-time deltas across samples are the liveness signal. Responding=False is
# not usable here: the dedicated server has no window, so it always reports
# False. A process holding commit with a flat CPU delta is the thing to find.
$script:LastCpu = @{}

function Get-ProcessSample {
    param([int] $Top)

    $cmdLines = Get-JavaCommandLines
    $procs    = Get-Process -ErrorAction SilentlyContinue |
                Sort-Object -Property PrivateMemorySize64 -Descending

    $isJava = { param($p) $p.ProcessName -in @('java','javaw') }

    # Always include every JVM, even if it falls outside the top N.
    $selected = @()
    $selected += $procs | Select-Object -First $Top
    $selected += $procs | Where-Object { & $isJava $_ }
    $selected = $selected | Sort-Object -Property Id -Unique

    $out = @()
    foreach ($p in $selected) {
        $cpuSec = $null
        try { $cpuSec = [math]::Round($p.TotalProcessorTime.TotalSeconds, 1) } catch { }

        $cpuDelta = $null
        if ($null -ne $cpuSec -and $script:LastCpu.ContainsKey($p.Id)) {
            $cpuDelta = [math]::Round($cpuSec - $script:LastCpu[$p.Id], 1)
        }
        if ($null -ne $cpuSec) { $script:LastCpu[$p.Id] = $cpuSec }

        $start = $null
        try { $start = $p.StartTime.ToString('yyyy-MM-dd HH:mm:ss') } catch { }

        $role = ''
        if ((& $isJava $p) -and $cmdLines.ContainsKey($p.Id)) {
            $role = Get-JvmRole -CommandLine $cmdLines[$p.Id]
        }

        $out += [pscustomobject]@{
            Name         = $p.ProcessName
            ProcessId    = $p.Id
            Role         = $role
            PrivateMB    = [math]::Round($p.PrivateMemorySize64 / 1MB, 1)
            WorkingSetMB = [math]::Round($p.WorkingSet64        / 1MB, 1)
            CpuSec       = $cpuSec
            CpuDeltaSec  = $cpuDelta
            StartTime    = $start
        }
    }
    return $out | Sort-Object -Property PrivateMB -Descending
}

# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

function Write-CsvRows {
    param([string] $Path, [object[]] $Rows, [string[]] $Columns)

    if (-not $Rows -or $Rows.Count -eq 0) { return }

    $sb = New-Object System.Text.StringBuilder
    if (-not (Test-Path -LiteralPath $Path)) {
        [void]$sb.AppendLine(($Columns -join ','))
    }
    foreach ($r in $Rows) {
        $vals = foreach ($c in $Columns) {
            $v = $r.$c
            if ($null -eq $v) { '' }
            elseif ($v -is [string] -and $v -match '[",]') { '"' + ($v -replace '"', '""') + '"' }
            else { $v }
        }
        [void]$sb.AppendLine(($vals -join ','))
    }
    # AppendAllText rather than Add-Content: Add-Content can fail silently
    # under file locks and we cannot afford a gap in the series.
    [IO.File]::AppendAllText($Path, $sb.ToString(), [Text.Encoding]::UTF8)
}

function Show-Sample {
    param($State, [object[]] $Procs, [double] $Warn)

    $colour = 'Green'
    if     ($State.CommitPct -ge 95)    { $colour = 'Red' }
    elseif ($State.CommitPct -ge $Warn) { $colour = 'Yellow' }

    Write-Host ''
    Write-Host ("[{0}] Commit {1:N0} / {2:N0} MB  ({3}%)   PhysFree {4:N0} MB   Pagefile {5:N0} MB" -f `
        (Get-Date -Format 'HH:mm:ss'), $State.CommitChargeMB, $State.CommitLimitMB,
        $State.CommitPct, $State.PhysFreeMB, $State.PagefileMB) -ForegroundColor $colour

    $jvms = @($Procs | Where-Object { $_.Name -in @('java','javaw') })
    if ($jvms.Count -gt 0) {
        Write-Host ("  JVMs: {0}" -f $jvms.Count) -ForegroundColor DarkGray
        foreach ($j in $jvms) {
            $flag = ''
            # Held commit, no CPU progress, tiny resident set = candidate zombie.
            if ($null -ne $j.CpuDeltaSec -and $j.CpuDeltaSec -le 0.5 -and $j.PrivateMB -gt 1024) {
                $flag = '   <-- NO CPU PROGRESS'
            }
            $line = "    pid {0,-7} {1,-8} private {2,9:N0} MB   ws {3,9:N0} MB   cpuD {4,7}{5}" -f `
                    $j.ProcessId, $j.Role, $j.PrivateMB, $j.WorkingSetMB,
                    $(if ($null -eq $j.CpuDeltaSec) { 'n/a' } else { $j.CpuDeltaSec }), $flag
            Write-Host $line -ForegroundColor $(if ($flag) { 'Red' } else { 'Gray' })
        }
        if ($jvms.Count -gt 2) {
            Write-Host "  WARNING: more than two JVMs alive. Expected one client + one server." -ForegroundColor Red
        }
    }

    if ($State.CommitPct -ge $Warn) {
        Write-Host "  Top commit holders:" -ForegroundColor Yellow
        $Procs | Select-Object -First 8 | ForEach-Object {
            Write-Host ("    {0,-28} pid {1,-7} {2,9:N0} MB" -f $_.Name, $_.ProcessId, $_.PrivateMB) -ForegroundColor DarkYellow
        }
    }
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

$systemCols  = @('Timestamp','CommitChargeMB','CommitLimitMB','CommitPct','PhysTotalMB','PhysFreeMB','PagefileMB','JvmCount')
$processCols = @('Timestamp','Name','ProcessId','Role','PrivateMB','WorkingSetMB','CpuSec','CpuDeltaSec','StartTime')

if ($Snapshot) {
    $state = Get-CommitState
    $procs = Get-ProcessSample -Top $TopN
    Show-Sample -State $state -Procs $procs -Warn $WarnPercent
    Write-Host ''
    Write-Host "  Snapshot only -- CPU deltas need at least two samples to mean anything." -ForegroundColor DarkGray
    Write-Host "  Run without -Snapshot to sample continuously." -ForegroundColor DarkGray
    return
}

Write-Host "  interval ${IntervalSeconds}s; warn at ${WarnPercent}%; Ctrl+C to stop" -ForegroundColor DarkGray

$deadline = if ($DurationMinutes -gt 0) { (Get-Date).AddMinutes($DurationMinutes) } else { [datetime]::MaxValue }
$sampleNo = 0

try {
    while ((Get-Date) -lt $deadline) {
        $stamp = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
        $state = Get-CommitState
        $procs = Get-ProcessSample -Top $TopN
        $jvmCount = @($procs | Where-Object { $_.Name -in @('java','javaw') }).Count

        Write-CsvRows -Path $systemCsv -Columns $systemCols -Rows @(
            [pscustomobject]@{
                Timestamp      = $stamp
                CommitChargeMB = $state.CommitChargeMB
                CommitLimitMB  = $state.CommitLimitMB
                CommitPct      = $state.CommitPct
                PhysTotalMB    = $state.PhysTotalMB
                PhysFreeMB     = $state.PhysFreeMB
                PagefileMB     = $state.PagefileMB
                JvmCount       = $jvmCount
            })

        $procRows = foreach ($p in $procs) {
            [pscustomobject]@{
                Timestamp    = $stamp
                Name         = $p.Name
                ProcessId    = $p.ProcessId
                Role         = $p.Role
                PrivateMB    = $p.PrivateMB
                WorkingSetMB = $p.WorkingSetMB
                CpuSec       = $p.CpuSec
                CpuDeltaSec  = $p.CpuDeltaSec
                StartTime    = $p.StartTime
            }
        }
        Write-CsvRows -Path $processCsv -Columns $processCols -Rows @($procRows)

        $sampleNo++
        Show-Sample -State $state -Procs $procs -Warn $WarnPercent

        Start-Sleep -Seconds $IntervalSeconds
    }
} finally {
    Write-Host ''
    Write-Host "Stopped after $sampleNo samples." -ForegroundColor Cyan
    if ($sampleNo -gt 0) {
        Write-Host "  $systemCsv"  -ForegroundColor DarkGray
        Write-Host "  $processCsv" -ForegroundColor DarkGray
    }
}

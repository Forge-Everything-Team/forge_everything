#Requires -Version 5.1
<#
.SYNOPSIS
    Samples GPU memory -- adapter-resident and per-process committed -- over time.

.DESCRIPTION
    Companion to Watch-CommitCharge.ps1, built for the other failure mode: the
    NVIDIA OpenGL driver killing javaw.exe with "An application has requested
    more GPU memory than is available in the system" (Error code 6), which lands
    in the Windows Application log rather than a Minecraft crash report.

    Two different numbers matter, and they do not agree by design:

      Adapter "Dedicated Usage"  what is actually resident in VRAM right now.
                                 Matches nvidia-smi memory.used. Capped by the
                                 12 GB on the card.

      Process "Dedicated Usage"  what each process has COMMITTED. Under WDDM an
                                 allocation can be committed but paged out to
                                 system memory, so the sum of these routinely
                                 exceeds both the adapter figure and the card's
                                 physical VRAM. This is the number the driver's
                                 allocation budget cares about, so it is the one
                                 that predicts Error code 6.

    Tracking only nvidia-smi will make the crash look impossible -- the card will
    read half empty. The per-process committed total is where the pressure shows.

    Writes two CSVs:
      vram-adapter.csv    one row per sample, adapter totals + nvidia-smi
      vram-processes.csv  one row per tracked process per sample

.PARAMETER IntervalSeconds
    Seconds between samples. Default 30. VRAM moves faster than commit charge.

.PARAMETER DurationMinutes
    Stop after this many minutes. 0 = run until Ctrl+C. Default 0.

.PARAMETER TopN
    Number of top processes by committed GPU memory to record each sample.
    Default 15.

.PARAMETER WarnPercent
    Emit a console warning when committed GPU memory across all processes
    exceeds this percent of physical VRAM. Default 85.

.PARAMETER Snapshot
    Take a single sample, print it, and exit. No CSV written.

.PARAMETER OutputDir
    Directory for the CSVs. Resolution order: explicit parameter, then
    FE_VRAM_LOG_DIR env var, then secrets file, then .\reports.

.EXAMPLE
    .\Watch-VramUsage.ps1 -Snapshot
    What is holding GPU memory right now, before the pack is launched.

.EXAMPLE
    .\Watch-VramUsage.ps1 -IntervalSeconds 30
    Start before launching the pack. Leave running. Ctrl+C after the crash, then
    read the tail of vram-processes.csv for javaw's committed curve.
#>

[CmdletBinding()]
param(
    [int]    $IntervalSeconds = 30,
    [int]    $DurationMinutes = 0,
    [int]    $TopN            = 15,
    [double] $WarnPercent     = 85,
    [switch] $Snapshot,
    [string] $OutputDir
)

$ScriptVersion = '1.0.0'
Write-Host "Watch-VramUsage.ps1 v$ScriptVersion" -ForegroundColor Cyan

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
                                     -EnvName   'FE_VRAM_LOG_DIR' `
                                     -SecretKey 'FE_VRAM_LOG_DIR' `
                                     -Default   (Join-Path $PSScriptRoot 'reports')
    }
    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
    $adapterCsv = Join-Path $OutputDir 'vram-adapter.csv'
    $processCsv = Join-Path $OutputDir 'vram-processes.csv'
    Write-Host "  output: $OutputDir" -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------
# Physical VRAM. Win32_VideoController.AdapterRAM is a 32-bit field and wraps
# at 4 GB, so it reports 4 GB for a 12 GB card. nvidia-smi is authoritative.
# --------------------------------------------------------------------------

function Get-PhysicalVramMB {
    try {
        $raw = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) {
            return [double](($raw -split "`n")[0].Trim())
        }
    } catch { }
    Write-Verbose "nvidia-smi unavailable; VRAM percentages will be omitted."
    return 0
}

$script:PhysicalVramMB = Get-PhysicalVramMB
if ($script:PhysicalVramMB -gt 0) {
    Write-Host ("  physical VRAM: {0:N0} MB" -f $script:PhysicalVramMB) -ForegroundColor DarkGray
}

# --------------------------------------------------------------------------
# Sampling
# --------------------------------------------------------------------------

# Counter instance names look like:
#   pid_35080_luid_0x00000000_0x000110dd_phys_0
# A process gets one instance per adapter+segment, so values must be summed per
# pid rather than taken from a single instance.
function Get-GpuCounterTotals {
    param([string] $CounterPath)

    $byKey = @{}
    try {
        $set = Get-Counter -Counter $CounterPath -ErrorAction Stop
    } catch {
        # Counter names are locale-dependent; on a non-English Windows this path
        # will not resolve and the sample is simply skipped.
        Write-Verbose "Counter '$CounterPath' unavailable: $($_.Exception.Message)"
        return $byKey
    }
    foreach ($sample in $set.CounterSamples) {
        if ($sample.InstanceName -match '^pid_(\d+)_') { $key = [int]$Matches[1] }
        elseif ($sample.InstanceName -match '^luid_(.+?)_phys_') { $key = $Matches[1] }
        else { continue }
        $byKey[$key] = [double]$byKey[$key] + [double]$sample.CookedValue
    }
    return $byKey
}

function Get-AdapterSample {
    $dedicated = Get-GpuCounterTotals -CounterPath '\GPU Adapter Memory(*)\Dedicated Usage'
    $shared    = Get-GpuCounterTotals -CounterPath '\GPU Adapter Memory(*)\Shared Usage'

    # Sum across adapters. The iGPU contributes a negligible amount here, and
    # folding it in avoids having to map LUIDs back to device names.
    $dedicatedMB = 0.0
    foreach ($v in $dedicated.Values) { $dedicatedMB += $v / 1MB }
    $sharedMB = 0.0
    foreach ($v in $shared.Values) { $sharedMB += $v / 1MB }

    $smiUsedMB = $null
    try {
        $raw = & nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null
        if ($LASTEXITCODE -eq 0 -and $raw) { $smiUsedMB = [double](($raw -split "`n")[0].Trim()) }
    } catch { }

    [pscustomobject]@{
        AdapterDedicatedMB = [math]::Round($dedicatedMB, 1)
        AdapterSharedMB    = [math]::Round($sharedMB, 1)
        NvidiaSmiUsedMB    = if ($null -ne $smiUsedMB) { [math]::Round($smiUsedMB, 1) } else { $null }
        PhysicalVramMB     = $script:PhysicalVramMB
    }
}

# Minecraft is the process we care about; everything else matters only as
# competition for the same allocation budget.
function Get-GpuRole {
    param([string] $Name, [string] $CommandLine)
    if ($Name -notin @('java', 'javaw')) { return '' }
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return 'jvm' }
    if ($CommandLine -match 'nogui|forge_everything_server|server\.jar') { return 'server' }
    if ($CommandLine -match 'ModrinthApp|MojangTricksIntelDrivers|net\.minecraft\.client') { return 'client' }
    return 'jvm'
}

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

function Get-ProcessSample {
    param([int] $Top)

    $committed = Get-GpuCounterTotals -CounterPath '\GPU Process Memory(*)\Dedicated Usage'
    $sharedMem = Get-GpuCounterTotals -CounterPath '\GPU Process Memory(*)\Shared Usage'
    if ($committed.Count -eq 0) { return @() }

    $cmdLines = Get-JavaCommandLines

    # Always include every JVM, even if it falls outside the top N -- the point
    # of the run is javaw's curve, and early in a session it is not yet on top.
    $ranked   = $committed.GetEnumerator() | Sort-Object -Property Value -Descending
    $selected = @($ranked | Select-Object -First $Top)
    $selected += @($ranked | Where-Object { $cmdLines.ContainsKey($_.Key) })
    $selected = $selected | Sort-Object -Property Key -Unique

    $out = @()
    foreach ($entry in $selected) {
        $procId = $entry.Key
        $p = Get-Process -Id $procId -ErrorAction SilentlyContinue
        # A process can exit between the counter read and here; keep the row,
        # since a large allocation vanishing is itself a useful signal.
        $name = if ($p) { $p.ProcessName } else { '(exited)' }

        $out += [pscustomobject]@{
            Name            = $name
            ProcessId       = $procId
            Role            = Get-GpuRole -Name $name -CommandLine $cmdLines[$procId]
            GpuCommittedMB  = [math]::Round($entry.Value / 1MB, 1)
            GpuSharedMB     = [math]::Round([double]$sharedMem[$procId] / 1MB, 1)
        }
    }
    return $out | Sort-Object -Property GpuCommittedMB -Descending
}

# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------

function Write-SampleToHost {
    param($Adapter, $Processes, [double] $CommittedTotalMB)

    $pct = if ($Adapter.PhysicalVramMB -gt 0) {
        [math]::Round(100 * $CommittedTotalMB / $Adapter.PhysicalVramMB, 1)
    } else { $null }

    $line = "  adapter resident {0,8:N0} MB" -f $Adapter.AdapterDedicatedMB
    if ($Adapter.PhysicalVramMB -gt 0) { $line += " / {0:N0} MB VRAM" -f $Adapter.PhysicalVramMB }
    Write-Host $line -ForegroundColor DarkGray

    $line = "  committed total  {0,8:N0} MB" -f $CommittedTotalMB
    if ($null -ne $pct) { $line += " ({0}% of VRAM)" -f $pct }
    $color = if ($null -ne $pct -and $pct -ge $WarnPercent) { 'Yellow' } else { 'DarkGray' }
    Write-Host $line -ForegroundColor $color

    foreach ($row in ($Processes | Select-Object -First 8)) {
        $tag = if ($row.Role) { " [$($row.Role)]" } else { '' }
        Write-Host ("    {0,9:N0} MB  {1}{2}" -f $row.GpuCommittedMB, $row.Name, $tag) -ForegroundColor DarkGray
    }
}

$deadline = if ($DurationMinutes -gt 0) { (Get-Date).AddMinutes($DurationMinutes) } else { $null }
$warned   = $false

if (-not $Snapshot) {
    Write-Host "  sampling every $IntervalSeconds s -- Ctrl+C to stop" -ForegroundColor DarkGray
}

do {
    $stamp     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $adapter   = Get-AdapterSample
    $processes = Get-ProcessSample -Top $TopN

    $committedTotalMB = 0.0
    foreach ($row in $processes) { $committedTotalMB += $row.GpuCommittedMB }
    $committedTotalMB = [math]::Round($committedTotalMB, 1)

    Write-Host $stamp -ForegroundColor Cyan
    Write-SampleToHost -Adapter $adapter -Processes $processes -CommittedTotalMB $committedTotalMB

    if ($Snapshot) { break }

    $adapterRow = [pscustomobject]@{
        Timestamp          = $stamp
        AdapterDedicatedMB = $adapter.AdapterDedicatedMB
        AdapterSharedMB    = $adapter.AdapterSharedMB
        NvidiaSmiUsedMB    = $adapter.NvidiaSmiUsedMB
        PhysicalVramMB     = $adapter.PhysicalVramMB
        CommittedTotalMB   = $committedTotalMB
        CommittedPct       = if ($adapter.PhysicalVramMB -gt 0) {
                                 [math]::Round(100 * $committedTotalMB / $adapter.PhysicalVramMB, 2)
                             } else { $null }
        ProcessCount       = $processes.Count
    }
    $adapterRow | Export-Csv -LiteralPath $adapterCsv -NoTypeInformation -Append -Encoding UTF8

    foreach ($row in $processes) {
        [pscustomobject]@{
            Timestamp      = $stamp
            Name           = $row.Name
            ProcessId      = $row.ProcessId
            Role           = $row.Role
            GpuCommittedMB = $row.GpuCommittedMB
            GpuSharedMB    = $row.GpuSharedMB
        } | Export-Csv -LiteralPath $processCsv -NoTypeInformation -Append -Encoding UTF8
    }

    if ($adapter.PhysicalVramMB -gt 0) {
        $pct = 100 * $committedTotalMB / $adapter.PhysicalVramMB
        if ($pct -ge $WarnPercent -and -not $warned) {
            Write-Warning ("Committed GPU memory at {0:N1}% of physical VRAM -- Error code 6 territory." -f $pct)
            $warned = $true
        } elseif ($pct -lt $WarnPercent) {
            $warned = $false
        }
    }

    if ($deadline -and (Get-Date) -ge $deadline) { break }
    Start-Sleep -Seconds $IntervalSeconds
} while ($true)

if (-not $Snapshot) {
    Write-Host "done" -ForegroundColor Cyan
    Write-Host "  $adapterCsv" -ForegroundColor DarkGray
    Write-Host "  $processCsv" -ForegroundColor DarkGray
}

<#
.SYNOPSIS
    Triages a tag_audit export into tags that are ACTUALLY broken ("cooked"),
    using the ProbeJS runtime dump as the authority.

.DESCRIPTION
    Export-TagInventory reports ~800 dangling refs and ~6200 unknown-namespace
    entries. Almost none of that is breakage:

      * The audit scans the mods folder only. It never sees the vanilla client
        jar or the NeoForge jar, so every reference to a built-in tag
        (c:ingots/gold, minecraft:jungle_logs, c:obsidians ...) is reported
        dangling even though it resolves fine at runtime.
      * Optional entries (Required=False, reported as Severity "soft") are meant
        to vanish silently when the target mod is absent. Working as intended.

    This script closes both blind spots by parsing the ProbeJS type dump, which
    reads tags straight from the game's registries after datapack merge. Every
    "*Tag" literal union in @special\types\index.d.ts becomes a per-registry
    lookup set. A dangling reference ProbeJS can see is not broken, full stop.

    VERDICTS

      COOKED   Confirmed breakage. A required reference to a tag that does not
               exist at runtime, a replace=true collision between two declaring
               sources, or a tag file that failed to parse.
      DEAD     Required reference into a mod that is not installed. Real, but
               the fix is "install it" or "stub it", not "the tag is wrong".
      SUSPECT  Unresolved. Only occurs without a ProbeJS dump, or for a registry
               ProbeJS emitted no union for.
      NOISE    Optional / soft findings. Written only with -IncludeNoise.

.PARAMETER AuditDir
    Folder holding the Export-TagInventory CSVs. Defaults to TAG_AUDIT_DIR, then
    OUTPUT_DIR\tag_audit, then .\tag_audit.

.PARAMETER LogPath
    A client log containing the "Mod List:" block. Defaults to CLIENT_LOG, then
    INSTANCE_ROOT\logs\latest.log.

.PARAMETER ProbeDir
    The ProbeJS dump. Accepts the instance root, the .probe folder, or
    @special\types\index.d.ts directly - the file is located automatically.
    Defaults to PROBE_DIR, then INSTANCE_ROOT\.probe.

    Strongly recommended. Without it every c:/minecraft:/neoforge: reference is
    unresolvable and lands in SUSPECT.

.PARAMETER OutDir
    Report folder. Defaults to COOKED_TAGS_DIR, then OUTPUT_DIR\cooked.

.PARAMETER SecretsFile
    Alternative settings file. Defaults to secrets.local.env beside the scripts,
    or $env:FORGE_EVERYTHING_SECRETS.

.PARAMETER ExportTagIndex
    Also write runtime_tags_by_registry.csv and runtime_tags.txt, the flattened
    ProbeJS index, for use as input to other tooling.

.PARAMETER IncludeNoise
    Also write noise_tags.csv with the soft/optional findings.

.EXAMPLE
    .\Get-CookedTags.ps1

    With INSTANCE_ROOT and OUTPUT_DIR set in secrets.local.env, that is the
    whole invocation.

.EXAMPLE
    .\Get-CookedTags.ps1 -AuditDir .\tag_audit -LogPath .\logs\latest.log -ExportTagIndex

.NOTES
    PS 5.1 compatible. -LiteralPath throughout (mod jars have [bracket] names),
    StringBuilder + WriteAllText for output via PackConfig, no -AsHashtable.

    SECRETS KEYS READ
        TAG_AUDIT_DIR       tag audit CSV folder      (Export-TagInventory's own key)
        CLIENT_LOG          latest.log                (new)
        PROBE_DIR           the .probe folder         (new)
        COOKED_TAGS_DIR     report output folder      (new)
        INSTANCE_ROOT       parent for the three above when they are unset
        OUTPUT_DIR          parent for AuditDir / OutDir when they are unset

    The ProbeJS dump is a snapshot. If it predates the mods folder the index is
    stale and the script warns. Re-dump with /probejs dump from INSIDE A WORLD -
    a main-menu dump contains no datapack tags at all.
#>

[CmdletBinding()]
param(
    [string] $AuditDir,
    [string] $LogPath,
    [string] $ProbeDir,
    [string] $OutDir,
    [string] $SecretsFile,
    [switch] $ExportTagIndex,
    [switch] $IncludeNoise
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$script:ScriptVersion = '2.1.0'

# Namespaces owned by the game/loader. A mods-folder scan cannot see these, so
# without a runtime index every reference into them is a false positive.
$script:BuiltinNamespaces = @('minecraft', 'c', 'neoforge', 'forge', 'fabric')

$configPath = Join-Path $PSScriptRoot 'PackConfig.ps1'
if (-not (Test-Path -LiteralPath $configPath)) {
    throw "PackConfig.ps1 not found beside this script ($PSScriptRoot). Every script in this folder dot-sources it."
}
. $configPath

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Assert-PathExists {
    param([string] $Path, [string] $Label)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        throw "$Label is not set. Pass it on the command line, or set the matching key in secrets.local.env."
    }
    if (-not (Test-Path -LiteralPath $Path)) { throw "$Label not found: $Path" }
    return (Resolve-Path -LiteralPath $Path).ProviderPath
}

function New-StringSet {
    return New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
}

function Get-TagNamespace {
    param([string] $TagId)
    if ([string]::IsNullOrWhiteSpace($TagId)) { return 'minecraft' }
    $i = $TagId.IndexOf(':')
    if ($i -lt 1) { return 'minecraft' }   # bare paths default to minecraft
    return $TagId.Substring(0, $i)
}

function Import-AuditCsv {
    param([string] $Dir, [string] $Name, [switch] $Optional)
    $path = Join-Path $Dir $Name
    if (-not (Test-Path -LiteralPath $path)) {
        if ($Optional) { Write-Verbose "Optional audit file missing: $Name"; return @() }
        throw "Required audit file missing: $path"
    }
    $rows = @(Import-Csv -LiteralPath $path)
    Write-Host ("  {0,-34} {1,7} row(s)" -f $Name, $rows.Count) -ForegroundColor DarkGray
    return $rows
}

# ---------------------------------------------------------------------------
# Loaded mod IDs, from the client log's "Mod List:" block
# ---------------------------------------------------------------------------

function Get-LoadedModIds {
    param([string] $LogFile)

    $ids = New-StringSet
    $inList = $false
    $sinceHit = 0

    $reader = New-Object System.IO.StreamReader($LogFile)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $inList) {
                if ($line -match 'Mod List:') { $inList = $true }
                continue
            }
            # Entries look like:  <tab><tab>Advanced AE 1.6.11-1.21.1 (advanced_ae)
            if ($line -match '\(([a-z0-9_\-\.]+)\)\s*$') {
                [void]$ids.Add($Matches[1]); $sinceHit = 0; continue
            }
            $sinceHit++
            # Blanks and the "Name Version (Mod Id)" header are tolerated; a run
            # of real content means the block has ended.
            if ($line.Trim().Length -gt 0 -and $sinceHit -gt 3) { break }
        }
    }
    finally { $reader.Dispose() }

    if ($ids.Count -eq 0) {
        throw "No 'Mod List:' block in $LogFile - is this a log from a completed launch?"
    }
    return $ids
}

# ---------------------------------------------------------------------------
# ProbeJS runtime tag index
# ---------------------------------------------------------------------------

function Find-ProbeTypesFile {
    param([string] $Path)

    $p = (Resolve-Path -LiteralPath $Path).ProviderPath
    if (-not (Test-Path -LiteralPath $p -PathType Container)) { return $p }

    # Accept the instance root or the .probe folder itself.
    $candidates = @(
        (Join-Path $p '@special\types\index.d.ts'),
        (Join-Path $p '.probe\@special\types\index.d.ts')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c -PathType Leaf) {
            return (Resolve-Path -LiteralPath $c).ProviderPath
        }
    }
    throw "Could not locate '@special\types\index.d.ts' under: $p  (run /probejs dump from inside a world)"
}

function ConvertTo-RegistryKey {
    # ItemTag -> item ; WorldgenBiomeTag -> worldgen_biome ;
    # IronsJewelryPatternTag -> irons_jewelry_pattern
    param([string] $TypeName)

    $n = $TypeName
    if ($n.EndsWith('Tag')) { $n = $n.Substring(0, $n.Length - 3) }

    $sb = New-Object System.Text.StringBuilder
    for ($i = 0; $i -lt $n.Length; $i++) {
        $ch = $n[$i]
        if ($i -gt 0 -and [char]::IsUpper($ch)) { [void]$sb.Append('_') }
        [void]$sb.Append([char]::ToLowerInvariant($ch))
    }
    return $sb.ToString()
}

function Import-ProbeTagIndex {
    param([string] $TypesFile)

    $byRegistry = New-Object 'System.Collections.Generic.Dictionary[string, System.Collections.Generic.HashSet[string]]' ([StringComparer]::OrdinalIgnoreCase)
    $flat = New-StringSet

    # Find declaration positions first, then slice between them. Extracting
    # literals with one greedy union regex backtracks catastrophically - the
    # Item union alone is a 3.3 MB single line.
    $declRx = New-Object System.Text.RegularExpressions.Regex('type\s+([A-Za-z0-9_$]+)\s*=')
    $litRx  = New-Object System.Text.RegularExpressions.Regex('"([^"]+)"')

    $reader = New-Object System.IO.StreamReader($TypesFile)
    try {
        while ($null -ne ($line = $reader.ReadLine())) {
            if ($line.IndexOf('Tag') -lt 0) { continue }

            $decls = @($declRx.Matches($line))
            for ($i = 0; $i -lt $decls.Count; $i++) {
                $name = $decls[$i].Groups[1].Value
                if (-not $name.EndsWith('Tag')) { continue }

                $start = $decls[$i].Index + $decls[$i].Length
                if ($i + 1 -lt $decls.Count) { $end = $decls[$i + 1].Index } else { $end = $line.Length }
                $seg = $line.Substring($start, $end - $start)

                # A type alias ends at its semicolon; do not bleed into the next.
                $semi = $seg.IndexOf(';')
                if ($semi -ge 0) { $seg = $seg.Substring(0, $semi) }

                $key = ConvertTo-RegistryKey -TypeName $name
                if (-not $byRegistry.ContainsKey($key)) { $byRegistry[$key] = New-StringSet }

                foreach ($m in $litRx.Matches($seg)) {
                    $tag = $m.Groups[1].Value
                    # Union members are tag IDs; ignore anything that is not one.
                    if ($tag -match '^[a-z0-9_\-\.]+:[a-z0-9_\-\./]+$') {
                        [void]$byRegistry[$key].Add($tag)
                        [void]$flat.Add($tag)
                    }
                }
            }
        }
    }
    finally { $reader.Dispose() }

    return [pscustomobject]@{
        ByRegistry = $byRegistry
        Flat       = $flat
        Registries = $byRegistry.Count
        SourceFile = $TypesFile
    }
}

function Test-TagAtRuntime {
    <#
    .SYNOPSIS
        Returns 'hit', 'miss' or 'unknown'.

    .DESCRIPTION
        Registry match order: exact key, then prefix, then the flat set.

        The prefix step exists because custom mod registries get split across
        several unions - the audit calls the registry "irons_jewelry" while
        ProbeJS emits IronsJewelryMaterialTag and IronsJewelryPatternTag. Without
        it, thirteen perfectly valid tags read as broken.
    #>
    param($Index, [string] $Registry, [string] $TagId)

    if ($null -eq $Index) { return 'unknown' }

    $key = $Registry -replace '/', '_'

    if ($Index.ByRegistry.ContainsKey($key)) {
        if ($Index.ByRegistry[$key].Contains($TagId)) { return 'hit' }
        return 'miss'
    }

    $sawPrefix = $false
    foreach ($k in $Index.ByRegistry.Keys) {
        if ($k.StartsWith($key + '_', [System.StringComparison]::OrdinalIgnoreCase)) {
            $sawPrefix = $true
            if ($Index.ByRegistry[$k].Contains($TagId)) { return 'hit' }
        }
    }
    if ($sawPrefix) { return 'miss' }

    if ($Index.Flat.Contains($TagId)) { return 'hit' }
    return 'unknown'
}

# ---------------------------------------------------------------------------
# Classification
# ---------------------------------------------------------------------------

$script:FindingColumns = @(
    'Verdict', 'Score', 'Kind', 'TagId', 'Registry',
    'Problem', 'Detail', 'Source', 'File', 'Fix'
)

function New-Finding {
    param(
        [string] $Verdict, [int] $Score, [string] $Kind, [string] $TagId,
        [string] $Registry, [string] $Problem, [string] $Detail,
        [string] $Source, [string] $File, [string] $Fix
    )
    return [pscustomobject][ordered]@{
        Verdict = $Verdict; Score = $Score; Kind = $Kind; TagId = $TagId
        Registry = $Registry; Problem = $Problem; Detail = $Detail
        Source = $Source; File = $File; Fix = $Fix
    }
}

function Invoke-DanglingTriage {
    param([object[]] $Rows, $LoadedMods, $Index)

    $out = New-Object System.Collections.ArrayList
    foreach ($r in $Rows) {
        $state = Test-TagAtRuntime -Index $Index -Registry $r.Registry -TagId $r.MissingTag
        if ($state -eq 'hit') { continue }   # exists at runtime, so not broken

        $ns = Get-TagNamespace $r.MissingTag

        if ($r.Severity -ne 'HARD') {
            $verdict = 'NOISE'; $score = 10
            $fix = 'Optional reference - resolves to nothing and is skipped. No action needed.'
        }
        elseif ($state -eq 'unknown') {
            $verdict = 'SUSPECT'; $score = 40
            $fix = "No runtime union covers registry '$($r.Registry)'. Supply -ProbeDir, or confirm in-game."
        }
        elseif ($LoadedMods.Contains($ns) -or ($script:BuiltinNamespaces -contains $ns)) {
            $verdict = 'COOKED'; $score = 100
            $fix = "'$($r.MissingTag)' does not exist at runtime. Declare it in forgeeverything_datapack, or correct the referencing mod's data."
        }
        else {
            $verdict = 'DEAD'; $score = 70
            $fix = "Mod '$ns' is not installed. Install it, or stub '$($r.MissingTag)' as an empty tag in forgeeverything_datapack."
        }

        [void]$out.Add((New-Finding -Verdict $verdict -Score $score -Kind 'DanglingRef' `
            -TagId $r.ReferencingTag -Registry $r.Registry `
            -Problem 'References a tag that does not exist' -Detail $r.MissingTag `
            -Source $r.SourceName -File $r.File -Fix $fix))
    }
    return $out.ToArray()
}

function Invoke-UnknownNamespaceTriage {
    param([object[]] $Rows, $LoadedMods)

    $out = New-Object System.Collections.ArrayList
    foreach ($r in $Rows) {
        if ($r.Severity -ne 'HARD') {
            $verdict = 'NOISE'; $score = 10
            $fix = 'Optional entry - dropped silently when the mod is absent. No action needed.'
        }
        elseif ($LoadedMods.Contains($r.EntryNs)) {
            $verdict = 'COOKED'; $score = 100
            $fix = "'$($r.EntryNs)' is loaded but does not register '$($r.EntryId)'. Version mismatch against what the declaring mod expects."
        }
        else {
            $verdict = 'DEAD'; $score = 90
            $fix = "Required entry from absent mod '$($r.EntryNs)'. This tag fails to load. Override the file in forgeeverything_datapack with the entry marked optional, or install the mod."
        }

        [void]$out.Add((New-Finding -Verdict $verdict -Score $score -Kind 'UnknownNamespace' `
            -TagId $r.TagId -Registry $r.Registry `
            -Problem 'Required entry from an unrecognised namespace' -Detail $r.EntryId `
            -Source $r.SourceName -File $r.File -Fix $fix))
    }
    return $out.ToArray()
}

function Invoke-ConflictTriage {
    param([object[]] $Rows, $Index)

    $out = New-Object System.Collections.ArrayList
    foreach ($r in $Rows) {
        $declCount = 0
        [void][int]::TryParse($r.DeclaringCount, [ref]$declCount)
        if ($declCount -le 1) { continue }

        if ($r.HasReplace -eq 'True') {
            # Load order picks a winner and the loser's entries are discarded,
            # with nothing in the log to say so.
            [void]$out.Add((New-Finding -Verdict 'COOKED' -Score 95 -Kind 'ReplaceConflict' `
                -TagId $r.TagId -Registry $r.Registry `
                -Problem "replace=true with $declCount declaring sources" -Detail $r.DeclaredBy `
                -Source $r.DeclaredBy -File '' `
                -Fix 'Load order decides which mod wins; the loser''s entries vanish silently. Re-declare the union in forgeeverything_datapack with replace=false.'))
        }
        elseif ($r.LegacyDirUsed -eq 'True') {
            # Mixed tags/items vs tags/item across sources on one tag.
            $state = Test-TagAtRuntime -Index $Index -Registry $r.Registry -TagId $r.TagId
            if ($state -eq 'hit') { continue }   # merged fine at runtime
            [void]$out.Add((New-Finding -Verdict 'SUSPECT' -Score 35 -Kind 'LegacyDir' `
                -TagId $r.TagId -Registry $r.Registry `
                -Problem 'Mixed legacy plural / singular tag directories' -Detail $r.DeclaredBy `
                -Source $r.DeclaredBy -File '' `
                -Fix '1.21.1 expects singular dirs (tags\item). NeoForge still maps the plural form, but this tag is absent from the runtime index - verify in-game.'))
        }
    }
    return $out.ToArray()
}

function Invoke-ParseErrorTriage {
    param([object[]] $Rows)

    $out = New-Object System.Collections.ArrayList
    foreach ($r in $Rows) {
        [void]$out.Add((New-Finding -Verdict 'COOKED' -Score 100 -Kind 'ParseError' `
            -TagId $r.TagId -Registry '' `
            -Problem 'Tag JSON failed to parse' -Detail $r.Error `
            -Source $r.SourceName -File $r.File `
            -Fix 'Malformed or empty tag file. Override it with valid JSON in forgeeverything_datapack.'))
    }
    return $out.ToArray()
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

Write-Host "Get-CookedTags.ps1 v$script:ScriptVersion" -ForegroundColor Cyan

Initialize-PackConfig -SecretsFile $SecretsFile -ScriptRoot $PSScriptRoot

# $PSBoundParameters guards: PowerShell cannot otherwise distinguish a value you
# typed from an empty default it filled in, and the secrets file would win.

if (-not $PSBoundParameters.ContainsKey('AuditDir')) {
    $AuditDir = Get-PackFolderSetting -Name 'TAG_AUDIT_DIR' -ParentName 'OUTPUT_DIR' -ChildFolder 'tag_audit' -Default '.\tag_audit'
}

if (-not $PSBoundParameters.ContainsKey('LogPath')) {
    $LogPath = Get-PackSetting -Name 'CLIENT_LOG' -AsPath
    if (-not $LogPath) {
        $instance = Get-PackSetting -Name 'INSTANCE_ROOT' -AsPath
        if ($instance) { $LogPath = Join-Path $instance 'logs\latest.log' }
    }
    if (-not $LogPath) { $LogPath = '.\logs\latest.log' }
}

if (-not $PSBoundParameters.ContainsKey('ProbeDir')) {
    $ProbeDir = Get-PackFolderSetting -Name 'PROBE_DIR' -ParentName 'INSTANCE_ROOT' -ChildFolder '.probe'
}

if (-not $PSBoundParameters.ContainsKey('OutDir')) {
    $OutDir = Get-PackOutputFolder -Name 'COOKED_TAGS_DIR' -DefaultFolderName 'cooked'
}
elseif (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
}

$AuditDir = Assert-PathExists -Path $AuditDir -Label 'AuditDir (TAG_AUDIT_DIR)'
$LogPath  = Assert-PathExists -Path $LogPath  -Label 'LogPath (CLIENT_LOG)'

Show-PackConfigSummary -Title 'Resolved paths' -Values @{
    'AuditDir'  = $AuditDir
    'LogPath'   = $LogPath
    'ProbeDir'  = $ProbeDir
    'OutDir'    = $OutDir
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

Write-Host "`nParsing mod list from log..." -ForegroundColor Cyan
$loadedMods = Get-LoadedModIds -LogFile $LogPath
Write-Host ("  {0} mod ID(s) loaded at runtime" -f $loadedMods.Count) -ForegroundColor DarkGray

$index = $null
if ($ProbeDir -and (Test-Path -LiteralPath $ProbeDir)) {
    $typesFile = Find-ProbeTypesFile -Path $ProbeDir
    Write-Host 'Parsing ProbeJS runtime tag index...' -ForegroundColor Cyan
    $index = Import-ProbeTagIndex -TypesFile $typesFile
    Write-Host ("  {0} tag(s) across {1} registries" -f $index.Flat.Count, $index.Registries) -ForegroundColor DarkGray

    # A dump older than the audit was taken against a different mods folder.
    $probeStamp = (Get-Item -LiteralPath $typesFile).LastWriteTime
    $auditStamp = (Get-Item -LiteralPath (Join-Path $AuditDir 'dangling_tag_refs.csv')).LastWriteTime
    if ($probeStamp -lt $auditStamp.AddDays(-1)) {
        Write-Warning ("ProbeJS dump is {0:N0} day(s) older than the audit ({1:yyyy-MM-dd} vs {2:yyyy-MM-dd}). Re-dump from inside a world if the mods folder changed since." -f `
            ($auditStamp - $probeStamp).TotalDays, $probeStamp, $auditStamp)
    }
}
else {
    Write-Warning 'No ProbeJS dump found: every c:/minecraft:/neoforge: reference will land in SUSPECT. Set PROBE_DIR or INSTANCE_ROOT.'
}

Write-Host 'Loading audit CSVs...' -ForegroundColor Cyan
$dangling  = Import-AuditCsv -Dir $AuditDir -Name 'dangling_tag_refs.csv'
$unknownNs = Import-AuditCsv -Dir $AuditDir -Name 'unknown_namespace_entries.csv'
$conflicts = Import-AuditCsv -Dir $AuditDir -Name 'declaring_conflicts.csv'
$parseErrs = Import-AuditCsv -Dir $AuditDir -Name 'parse_errors.csv' -Optional

Write-Host 'Triaging...' -ForegroundColor Cyan
$findings = New-Object System.Collections.ArrayList
foreach ($f in (Invoke-DanglingTriage         -Rows $dangling  -LoadedMods $loadedMods -Index $index)) { [void]$findings.Add($f) }
foreach ($f in (Invoke-UnknownNamespaceTriage -Rows $unknownNs -LoadedMods $loadedMods))               { [void]$findings.Add($f) }
foreach ($f in (Invoke-ConflictTriage         -Rows $conflicts -Index $index))                         { [void]$findings.Add($f) }
foreach ($f in (Invoke-ParseErrorTriage       -Rows $parseErrs))                                       { [void]$findings.Add($f) }

$all     = $findings.ToArray()
$cooked  = @($all | Where-Object { $_.Verdict -eq 'COOKED'  })
$dead    = @($all | Where-Object { $_.Verdict -eq 'DEAD'    })
$suspect = @($all | Where-Object { $_.Verdict -eq 'SUSPECT' })
$noise   = @($all | Where-Object { $_.Verdict -eq 'NOISE'   })

$sortSpec   = @(@{ Expression = 'Score'; Descending = $true }, 'Kind', 'TagId')
$actionable = @($cooked + $dead + $suspect | Sort-Object -Property $sortSpec)

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

Write-Host 'Writing reports...' -ForegroundColor Cyan

[void](Write-PackCsvFile -Rows @($cooked | Sort-Object -Property $sortSpec) `
    -Columns $script:FindingColumns -Path (Join-Path $OutDir 'cooked_tags.csv') -Label 'cooked_tags.csv')

[void](Write-PackCsvFile -Rows $actionable `
    -Columns $script:FindingColumns -Path (Join-Path $OutDir 'tag_triage_all.csv') -Label 'tag_triage_all.csv')

if ($IncludeNoise) {
    [void](Write-PackCsvFile -Rows @($noise | Sort-Object Kind, TagId) `
        -Columns $script:FindingColumns -Path (Join-Path $OutDir 'noise_tags.csv') -Label 'noise_tags.csv')
}

if ($ExportTagIndex -and $null -ne $index) {
    $idxSb  = New-Object System.Text.StringBuilder
    $flatSb = New-Object System.Text.StringBuilder
    [void]$idxSb.AppendLine('"Registry","TagId"')
    foreach ($k in ($index.ByRegistry.Keys | Sort-Object)) {
        foreach ($t in ($index.ByRegistry[$k] | Sort-Object)) {
            [void]$idxSb.AppendLine((ConvertTo-PackCsvField -Value $k) + ',' + (ConvertTo-PackCsvField -Value $t))
        }
    }
    foreach ($t in ($index.Flat | Sort-Object)) { [void]$flatSb.AppendLine($t) }

    Write-PackTextFile -Path (Join-Path $OutDir 'runtime_tags_by_registry.csv') -Content $idxSb.ToString()
    Write-PackTextFile -Path (Join-Path $OutDir 'runtime_tags.txt') -Content $flatSb.ToString()
    Write-Host ("  {0,-34} {1} tag(s)" -f 'runtime_tags.txt', $index.Flat.Count) -ForegroundColor DarkGray
}

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("COOKED TAG TRIAGE - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  (v$script:ScriptVersion)")
[void]$sb.AppendLine("Audit  : $AuditDir")
[void]$sb.AppendLine("Log    : $LogPath")
[void]$sb.AppendLine("Runtime: $($loadedMods.Count) mod IDs")
if ($null -ne $index) {
    [void]$sb.AppendLine("Probe  : $($index.Flat.Count) tags across $($index.Registries) registries")
    [void]$sb.AppendLine("         $($index.SourceFile)")
}
else {
    [void]$sb.AppendLine('Probe  : not supplied - SUSPECT tier unresolved')
}
[void]$sb.AppendLine()
[void]$sb.AppendLine('VERDICTS')
[void]$sb.AppendLine(("  COOKED  (fix these)      : {0}" -f $cooked.Count))
[void]$sb.AppendLine(("  DEAD    (mod not present): {0}" -f $dead.Count))
[void]$sb.AppendLine(("  SUSPECT (unresolved)     : {0}" -f $suspect.Count))
[void]$sb.AppendLine(("  NOISE   (ignore)         : {0}" -f $noise.Count))
[void]$sb.AppendLine()

[void]$sb.AppendLine('COOKED BY KIND')
foreach ($g in ($cooked | Group-Object Kind | Sort-Object Count -Descending)) {
    [void]$sb.AppendLine(("  {0,4}  {1}" -f $g.Count, $g.Name))
}
[void]$sb.AppendLine()

[void]$sb.AppendLine('DETAIL')
foreach ($f in $actionable) {
    [void]$sb.AppendLine(("  [{0}] [{1}] {2}" -f $f.Verdict, $f.Kind, $f.TagId))
    [void]$sb.AppendLine(("        -> {0}" -f $f.Detail))
    [void]$sb.AppendLine(("        src {0}" -f $f.Source))
    [void]$sb.AppendLine(("        fix {0}" -f $f.Fix))
}

Write-PackTextFile -Path (Join-Path $OutDir 'cooked_summary.txt') -Content $sb.ToString()

Write-Host ''
Write-Host ("COOKED  : {0}" -f $cooked.Count)  -ForegroundColor Red
Write-Host ("DEAD    : {0}" -f $dead.Count)    -ForegroundColor Yellow
Write-Host ("SUSPECT : {0}" -f $suspect.Count) -ForegroundColor DarkYellow
Write-Host ("NOISE   : {0}" -f $noise.Count)   -ForegroundColor DarkGray
Write-Host ''
Write-Host "Reports in $OutDir" -ForegroundColor Green

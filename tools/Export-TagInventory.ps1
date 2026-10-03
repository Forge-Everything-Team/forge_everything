<#
.SYNOPSIS
    Static tag inventory for a NeoForge 1.21.1 modpack instance.

.DESCRIPTION
    Scans every mod jar, Paxi datapack, and (optionally) the KubeJS data folder for
    data/<namespace>/tags/**/*.json declarations and flattens them into queryable tables.

    This is a STATIC scan. It reports what each source *declares*, not what the game
    resolved after merging/replacement. Provenance is the point: when LMFT reports a
    cooked tag, this tells you which jar shipped the bad entry.

    Outputs (written to -OutputDir):
      tags_raw.csv                  One row per tag file per source.
      tag_entries.csv               One row per entry. The workhorse table.
      tags_merged.csv               One row per tag id, aggregated across all sources.
      dangling_tag_refs.csv         Entries pointing at #tags nobody declares.
      unknown_namespace_entries.csv Entries whose namespace has no matching source.
      declaring_conflicts.csv       Tags declared by 3+ sources, or with replace=true.
      parse_errors.csv              Malformed / unreadable tag JSON.
      unused_tags.csv               Only with -ScanUsage. Candidates, not proof.
      tags_master.json              Full structured dump for programmatic use.
      summary.txt                   Counts and headline findings.

.PARAMETER InstanceRoot
    Modpack instance root. Config key: INSTANCE_ROOT. The mods, Paxi, KubeJS and
    datapacks folders all derive from this unless overridden individually.

.PARAMETER ModsFolder
    Config key: INSTANCE_MODS_FOLDER. Defaults to INSTANCE_ROOT\mods.

.PARAMETER PaxiDatapacksFolder
    Config key: INSTANCE_PAXI_DATAPACKS_FOLDER. Defaults to
    INSTANCE_ROOT\paxi\datapacks.

.PARAMETER DatapacksFolder
    Config key: INSTANCE_DATAPACKS_FOLDER. The instance-level datapacks folder.

.PARAMETER KubeJsFolder
    Config key: INSTANCE_KUBEJS_FOLDER. Only scanned with -IncludeKubeJS.

.PARAMETER OutputDir
    Where to write results. Config key: TAG_AUDIT_DIR, else OUTPUT_DIR\tag_audit.

.PARAMETER ExtraDataDirs
    Additional datapack roots to scan. Accepts folders containing data/, folders
    containing datapacks, or .zip datapacks.

.PARAMETER IncludeNestedJars
    Also scan META-INF/jarjar/*.jar inside each mod jar. Slower; catches embedded
    datapack libraries.

.PARAMETER IncludeKubeJS
    Also scan the KubeJS data folder.

.PARAMETER ScanUsage
    Additionally scan every non-tag JSON in every source for tag references
    (recipes, loot tables, advancements, etc.) to produce unused_tags.csv.
    SLOW - reads every JSON in every jar. Expect several minutes on 486 mods.

.PARAMETER SecretsFile
    Override the settings file. Defaults to secrets.local.env beside the
    scripts, or $env:FORGE_EVERYTHING_SECRETS.

.EXAMPLE
    .\Export-TagInventory.ps1 -IncludeKubeJS

.EXAMPLE
    .\Export-TagInventory.ps1 -IncludeNestedJars -ScanUsage

.NOTES
    PowerShell 5.1 compatible. No -AsHashtable, no ternaries, -LiteralPath throughout.
    Shared IO helpers come from PackConfig.ps1.

    CONFIG KEYS READ
      INSTANCE_ROOT                    instance root
      INSTANCE_MODS_FOLDER             overrides INSTANCE_ROOT\mods
      INSTANCE_PAXI_DATAPACKS_FOLDER   overrides INSTANCE_ROOT\paxi\datapacks
      INSTANCE_DATAPACKS_FOLDER        overrides INSTANCE_ROOT\datapacks
      INSTANCE_KUBEJS_FOLDER           overrides INSTANCE_ROOT\kubejs
      TAG_AUDIT_DIR                    output folder
      OUTPUT_DIR                       fallback parent for the output folder
      MODPACK_VERSION                  stamped into summary.txt and tags_master.json
#>

[CmdletBinding()]
param(
    [string]   $InstanceRoot,
    [string]   $ModsFolder,
    [string]   $PaxiDatapacksFolder,
    [string]   $DatapacksFolder,
    [string]   $KubeJsFolder,
    [string]   $OutputDir,
    [string[]] $ExtraDataDirs,
    [switch]   $IncludeNestedJars,
    [switch]   $IncludeKubeJS,
    [switch]   $ScanUsage,
    [string]   $SecretsFile
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

. (Join-Path $PSScriptRoot "PackConfig.ps1")
Initialize-PackConfig -SecretsFile $SecretsFile -ScriptRoot $PSScriptRoot

# ContainsKey guards keep a typed flag from being overridden by the env file.
if (-not $PSBoundParameters.ContainsKey('InstanceRoot')) {
    $InstanceRoot = Get-PackSetting -Name 'INSTANCE_ROOT' -AsPath
}
if (-not $PSBoundParameters.ContainsKey('ModsFolder')) {
    $ModsFolder = Get-PackFolderSetting -Name 'INSTANCE_MODS_FOLDER' -ParentName 'INSTANCE_ROOT' -ChildFolder 'mods'
}
if (-not $PSBoundParameters.ContainsKey('PaxiDatapacksFolder')) {
    $PaxiDatapacksFolder = Get-PackFolderSetting -Name 'INSTANCE_PAXI_DATAPACKS_FOLDER' -ParentName 'INSTANCE_ROOT' -ChildFolder 'paxi\datapacks'
}
if (-not $PSBoundParameters.ContainsKey('DatapacksFolder')) {
    $DatapacksFolder = Get-PackFolderSetting -Name 'INSTANCE_DATAPACKS_FOLDER' -ParentName 'INSTANCE_ROOT' -ChildFolder 'datapacks'
}
if (-not $PSBoundParameters.ContainsKey('KubeJsFolder')) {
    $KubeJsFolder = Get-PackFolderSetting -Name 'INSTANCE_KUBEJS_FOLDER' -ParentName 'INSTANCE_ROOT' -ChildFolder 'kubejs'
}

# A parameter still wins over the config key; only fall back when neither gave
# us a folder.
if (-not $ModsFolder -and $InstanceRoot) { $ModsFolder = Join-Path $InstanceRoot 'mods' }

if (-not $ModsFolder) {
    throw "No mods folder resolved. Set INSTANCE_ROOT (or INSTANCE_MODS_FOLDER) in secrets.local.env, or pass -InstanceRoot / -ModsFolder."
}

if ($PSBoundParameters.ContainsKey('OutputDir')) {
    if (-not [System.IO.Path]::IsPathRooted($OutputDir)) {
        $OutputDir = Join-Path (Get-Location).ProviderPath $OutputDir
    }
    if (-not (Test-Path -LiteralPath $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }
}
else {
    $OutputDir = Get-PackOutputFolder -Name 'TAG_AUDIT_DIR' -DefaultFolderName 'tag_audit'
}

$ModpackVersion = Get-PackSetting -Name 'MODPACK_VERSION' -Default 'unversioned'

Show-PackConfigSummary -Title "Export-TagInventory" -Values @{
    'Instance root'    = $InstanceRoot
    'Mods folder'      = $ModsFolder
    'Paxi datapacks'   = $PaxiDatapacksFolder
    'Datapacks folder' = $DatapacksFolder
    'KubeJS folder'    = $KubeJsFolder
    'Output folder'    = $OutputDir
    'Modpack version'  = $ModpackVersion
}

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Registry folder aliases. 1.21 singularised the tag directories (tags/items ->
# tags/item). Mods ported from 1.20.x sometimes still ship the plural form, which
# silently does nothing. We normalise for grouping but keep the raw value so you
# can spot the stragglers.
$RegistryAliases = @{
    'items'         = 'item'
    'blocks'        = 'block'
    'fluids'        = 'fluid'
    'entity_types'  = 'entity_type'
    'functions'     = 'function'
    'structures'    = 'structure'
    'enchantments'  = 'enchantment'
    'biomes'        = 'biome'
    'game_events'   = 'game_event'
    'instruments'   = 'instrument'
    'paintings'     = 'painting_variant'
    'poi_types'     = 'point_of_interest_type'
    'damage_types'  = 'damage_type'
    'banner_patterns' = 'banner_pattern'
    'cat_variants'  = 'cat_variant'
}

# Namespaces that always exist regardless of what's installed.
$IntrinsicNamespaces = @('minecraft', 'c', 'neoforge', 'forge', 'common', 'fabric')

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
# Write-PackTextFile / Write-PackCsvFile / ConvertTo-PackCsvField come from
# PackConfig.ps1. Nothing here writes a file any other way.


function Split-TagPath {
    <#
        data/<ns>/tags/<registryDir>/<tagPath>.json
        Tag paths themselves can be nested (tags/item/ingots/copper.json -> c:ingots/copper),
        so registry vs tag path is ambiguous by depth alone. 'worldgen' is the only vanilla
        registry directory with a nested name, so treat it as a two-segment special case.
    #>
    param([string]$RelativePath)

    $norm = $RelativePath -replace '\\', '/'
    if ($norm -notmatch '^data/([^/]+)/tags/(.+)\.json$') { return $null }

    $ns        = $Matches[1]
    $remainder = $Matches[2]
    $segments  = $remainder -split '/'
    if ($segments.Count -lt 2) { return $null }

    if ($segments[0] -eq 'worldgen' -and $segments.Count -ge 3) {
        $registryDir = $segments[0] + '/' + $segments[1]
        $tagPath     = ($segments[2..($segments.Count - 1)]) -join '/'
    }
    else {
        $registryDir = $segments[0]
        $tagPath     = ($segments[1..($segments.Count - 1)]) -join '/'
    }

    $normalised = $registryDir
    if ($RegistryAliases.ContainsKey($registryDir)) { $normalised = $RegistryAliases[$registryDir] }

    return [PSCustomObject]@{
        Namespace       = $ns
        RegistryDir     = $registryDir
        Registry        = $normalised
        LegacyDirName   = ($registryDir -ne $normalised)
        TagPath         = $tagPath
        TagId           = "${ns}:$tagPath"
    }
}

function ConvertTo-TagEntryList {
    <#
        Normalises a values/remove array into flat entry records.
        Handles: "minecraft:stone", "#c:ores", {"id":"...","required":false}
    #>
    param($Array, [string]$Action)

    $out = @()
    if ($null -eq $Array) { return $out }

    foreach ($v in $Array) {
        $id       = $null
        $required = $true

        if ($v -is [string]) {
            $id = $v
        }
        elseif ($null -ne $v -and $null -ne $v.PSObject) {
            if ($v.PSObject.Properties['id'])       { $id = [string]$v.id }
            if ($v.PSObject.Properties['required']) { $required = [bool]$v.required }
        }

        if ([string]::IsNullOrWhiteSpace($id)) { continue }

        $isTagRef = $id.StartsWith('#')
        $bare     = $id.TrimStart('#')
        if ($bare -notmatch ':') { $bare = "minecraft:$bare" }
        $entryNs  = ($bare -split ':')[0]

        $out += [PSCustomObject]@{
            Action    = $Action
            EntryType = $(if ($isTagRef) { 'tagref' } else { 'direct' })
            EntryId   = $bare
            EntryNs   = $entryNs
            Required  = $required
            Raw       = $id
        }
    }
    return $out
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

$script:TagFiles       = New-Object System.Collections.ArrayList
$script:EntryRows      = New-Object System.Collections.ArrayList
$script:ParseErrors    = New-Object System.Collections.ArrayList
$script:KnownNs        = New-Object 'System.Collections.Generic.HashSet[string]'
$script:ReferencedTags = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($n in $IntrinsicNamespaces) { [void]$script:KnownNs.Add($n) }

# ---------------------------------------------------------------------------
# Core ingestion
# ---------------------------------------------------------------------------

function Add-TagDocument {
    param(
        [string]$SourceName,
        [string]$SourceType,
        [string]$SourcePath,
        [string]$RelativePath,
        [string]$Json
    )

    $meta = Split-TagPath -RelativePath $RelativePath
    if ($null -eq $meta) { return }

    $parsed = $null
    try {
        $parsed = $Json | ConvertFrom-Json
    }
    catch {
        [void]$script:ParseErrors.Add([PSCustomObject]@{
            SourceName = $SourceName
            SourceType = $SourceType
            File       = $RelativePath
            TagId      = $meta.TagId
            Error      = $_.Exception.Message
        })
        return
    }

    # ConvertFrom-Json does not always hand back an object. A file containing
    # `null`, `[]`, or a bare scalar parses cleanly and yields $null or a value
    # with no PSObject to index - which is what "Cannot index into a null array"
    # was. Treat any of those as a malformed tag rather than trusting the shape.
    if ($null -eq $parsed -or $null -eq $parsed.PSObject -or $null -eq $parsed.PSObject.Properties) {
        [void]$script:ParseErrors.Add([PSCustomObject]@{
            SourceName = $SourceName
            SourceType = $SourceType
            File       = $RelativePath
            TagId      = $meta.TagId
            Error      = 'Parsed to null or a non-object (empty file, literal null, bare array, or scalar)'
        })
        return
    }

    $replace = $false
    if ($parsed.PSObject.Properties['replace']) { $replace = [bool]$parsed.replace }

    $values  = $null
    $removes = $null
    if ($parsed.PSObject.Properties['values']) { $values  = $parsed.values }
    if ($parsed.PSObject.Properties['remove']) { $removes = $parsed.remove }

    $entries = @()
    $entries += (ConvertTo-TagEntryList -Array $values  -Action 'add')
    $entries += (ConvertTo-TagEntryList -Array $removes -Action 'remove')

    $optionalCount = 0
    $tagRefCount   = 0
    foreach ($e in $entries) {
        if (-not $e.Required)          { $optionalCount++ }
        if ($e.EntryType -eq 'tagref') { $tagRefCount++ }

        [void]$script:EntryRows.Add([PSCustomObject]@{
            TagId       = $meta.TagId
            Registry    = $meta.Registry
            SourceName  = $SourceName
            SourceType  = $SourceType
            Action      = $e.Action
            EntryType   = $e.EntryType
            EntryId     = $e.EntryId
            EntryNs     = $e.EntryNs
            Required    = $e.Required
            File        = $RelativePath
        })
    }

    $preview = ($entries | Select-Object -First 20 | ForEach-Object { $_.Raw }) -join '; '
    if ($entries.Count -gt 20) { $preview += ' ...' }

    [void]$script:TagFiles.Add([PSCustomObject]@{
        TagId          = $meta.TagId
        Registry       = $meta.Registry
        RegistryDir    = $meta.RegistryDir
        LegacyDirName  = $meta.LegacyDirName
        Namespace      = $meta.Namespace
        TagPath        = $meta.TagPath
        SourceName     = $SourceName
        SourceType     = $SourceType
        SourcePath     = $SourcePath
        File           = $RelativePath
        Replace        = $replace
        EntryCount     = $entries.Count
        OptionalCount  = $optionalCount
        TagRefCount    = $tagRefCount
        RemoveCount    = (@($entries | Where-Object { $_.Action -eq 'remove' })).Count
        Preview        = $preview
    })
}

function Add-UsageReferences {
    <#
        Harvests tag references out of non-tag data JSON (recipes, loot tables,
        advancements, worldgen...). Deliberately crude: two regexes over raw text,
        because every mod nests "tag" differently.
    #>
    param([string]$Json)

    foreach ($m in [regex]::Matches($Json, '"tag"\s*:\s*"([^"]+)"')) {
        $id = $m.Groups[1].Value.TrimStart('#')
        if ($id -notmatch ':') { $id = "minecraft:$id" }
        [void]$script:ReferencedTags.Add($id)
    }
    foreach ($m in [regex]::Matches($Json, '"#([a-z0-9_.\-]+:[a-z0-9_./\-]+)"')) {
        [void]$script:ReferencedTags.Add($m.Groups[1].Value)
    }
}

function Read-JarSource {
    param([string]$JarPath, [string]$SourceType = 'jar', [string]$DisplayName)

    if ([string]::IsNullOrWhiteSpace($DisplayName)) {
        $DisplayName = [System.IO.Path]::GetFileName($JarPath)
    }

    $zip = $null
    $nested = @()
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    }
    catch {
        [void]$script:ParseErrors.Add([PSCustomObject]@{
            SourceName = $DisplayName
            SourceType = $SourceType
            File       = '<archive>'
            TagId      = ''
            Error      = "Could not open archive: $($_.Exception.Message)"
        })
        return
    }

    try {
        foreach ($entry in $zip.Entries) {
            $name = $entry.FullName -replace '\\', '/'

            # Namespace harvesting - anything with an assets/ or data/ folder is a
            # namespace this pack can resolve.
            if ($name -match '^(?:assets|data)/([^/]+)/') {
                [void]$script:KnownNs.Add($Matches[1])
            }

            if ($IncludeNestedJars -and $name -match '^META-INF/jarjar/.+\.jar$') {
                $nested += $entry
                continue
            }

            $isTag = ($name -match '^data/[^/]+/tags/.+\.json$')
            $isOtherJson = ($ScanUsage -and $name -match '^data/.+\.json$' -and -not $isTag)
            if (-not $isTag -and -not $isOtherJson) { continue }

            # Per-entry isolation. With $ErrorActionPreference = 'Stop', one
            # unreadable file inside one jar would otherwise throw away an
            # entire multi-minute scan. Record it and keep going; parse_errors.csv
            # is the report for exactly this.
            try {
                $stream = $null; $reader = $null
                try {
                    $stream = $entry.Open()
                    $reader = New-Object System.IO.StreamReader($stream)
                    $text = $reader.ReadToEnd()
                }
                finally {
                    if ($null -ne $reader) { $reader.Dispose() }
                    if ($null -ne $stream) { $stream.Dispose() }
                }

                if ($isTag) {
                    Add-TagDocument -SourceName $DisplayName -SourceType $SourceType `
                                    -SourcePath $JarPath -RelativePath $name -Json $text
                }
                else {
                    Add-UsageReferences -Json $text
                }
            }
            catch {
                [void]$script:ParseErrors.Add([PSCustomObject]@{
                    SourceName = $DisplayName
                    SourceType = $SourceType
                    File       = $name
                    TagId      = ''
                    Error      = $_.Exception.Message
                })
            }
        }

        # Extract and recurse into jar-in-jar payloads.
        foreach ($entry in $nested) {
            $tmp = Join-Path -Path ([System.IO.Path]::GetTempPath()) -ChildPath ([System.Guid]::NewGuid().ToString() + '.jar')
            try {
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $tmp, $true)
                Read-JarSource -JarPath $tmp -SourceType 'jarjar' `
                               -DisplayName ("$DisplayName > " + [System.IO.Path]::GetFileName($entry.FullName))
            }
            catch {
                [void]$script:ParseErrors.Add([PSCustomObject]@{
                    SourceName = $DisplayName
                    SourceType = 'jarjar'
                    File       = $entry.FullName
                    TagId      = ''
                    Error      = $_.Exception.Message
                })
            }
            finally {
                if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
            }
        }
    }
    finally {
        if ($null -ne $zip) { $zip.Dispose() }
    }
}

function Read-FolderSource {
    param([string]$RootPath, [string]$SourceType, [string]$DisplayName)

    $dataDir = Join-Path -Path $RootPath -ChildPath 'data'
    if (-not (Test-Path -LiteralPath $dataDir)) { return }

    $rootLen = $RootPath.TrimEnd('\', '/').Length + 1

    $files = @(Get-ChildItem -LiteralPath $dataDir -Recurse -File -Filter '*.json' -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
        $rel = $f.FullName.Substring($rootLen) -replace '\\', '/'

        if ($rel -match '^data/([^/]+)/') { [void]$script:KnownNs.Add($Matches[1]) }

        $isTag = ($rel -match '^data/[^/]+/tags/.+\.json$')
        if (-not $isTag -and -not $ScanUsage) { continue }

        try {
            $text = [System.IO.File]::ReadAllText($f.FullName)
            if ($isTag) {
                Add-TagDocument -SourceName $DisplayName -SourceType $SourceType `
                                -SourcePath $f.FullName -RelativePath $rel -Json $text
            }
            else {
                Add-UsageReferences -Json $text
            }
        }
        catch {
            [void]$script:ParseErrors.Add([PSCustomObject]@{
                SourceName = $DisplayName
                SourceType = $SourceType
                File       = $rel
                TagId      = ''
                Error      = $_.Exception.Message
            })
        }
    }
}

# ---------------------------------------------------------------------------
# Source discovery
# ---------------------------------------------------------------------------

function Get-DatapackRoots {
    param([string]$Base)

    $roots = @()
    if (-not (Test-Path -LiteralPath $Base)) { return $roots }

    # A folder that directly contains data/ is itself a datapack.
    if (Test-Path -LiteralPath (Join-Path -Path $Base -ChildPath 'data')) {
        $roots += [PSCustomObject]@{ Path = $Base; Kind = 'folder'; Name = (Split-Path -LiteralPath $Base -Leaf) }
        return $roots
    }

    # Otherwise treat it as a container of datapacks.
    foreach ($child in @(Get-ChildItem -LiteralPath $Base -ErrorAction SilentlyContinue)) {
        if ($child.PSIsContainer) {
            if (Test-Path -LiteralPath (Join-Path -Path $child.FullName -ChildPath 'data')) {
                $roots += [PSCustomObject]@{ Path = $child.FullName; Kind = 'folder'; Name = $child.Name }
            }
        }
        elseif ($child.Extension -eq '.zip') {
            $roots += [PSCustomObject]@{ Path = $child.FullName; Kind = 'zip'; Name = $child.Name }
        }
    }
    return $roots
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $ModsFolder)) {
    throw "Mods folder not found: $ModsFolder"
}

Write-Host ""
Write-Host "Tag inventory" -ForegroundColor Cyan
if ($ScanUsage) { Write-Host "  Usage scan enabled - this will take a while." -ForegroundColor Yellow }
Write-Host ""

# --- mods ---
$jars = @(Get-ChildItem -LiteralPath $ModsFolder -Filter '*.jar' -File -ErrorAction SilentlyContinue)
Write-Host "Scanning $($jars.Count) mod jars..."

$i = 0
$failedJars = 0
foreach ($jar in $jars) {
    $i++
    Write-Progress -Activity 'Scanning mod jars' -Status $jar.Name -PercentComplete (($i / [Math]::Max($jars.Count,1)) * 100)
    try {
        Read-JarSource -JarPath $jar.FullName -SourceType 'mod' -DisplayName $jar.Name
    }
    catch {
        $failedJars++
        [void]$script:ParseErrors.Add([PSCustomObject]@{
            SourceName = $jar.Name
            SourceType = 'mod'
            File       = '<jar>'
            TagId      = ''
            Error      = $_.Exception.Message
        })
        Write-Host "  ! $($jar.Name): $($_.Exception.Message)" -ForegroundColor Red
    }
}
Write-Progress -Activity 'Scanning mod jars' -Completed
if ($failedJars -gt 0) {
    Write-Host "  $failedJars jar(s) failed outright - see parse_errors.csv" -ForegroundColor Yellow
}

# --- datapack roots ---
# The configured Paxi/datapack folders first, then the other conventional
# locations as a safety net. Get-DatapackRoots ignores anything absent, so
# probing costs nothing.
$packBases = @()
if ($PaxiDatapacksFolder) { $packBases += $PaxiDatapacksFolder }
if ($DatapacksFolder)     { $packBases += $DatapacksFolder }
if ($InstanceRoot) {
    $packBases += (Join-Path -Path $InstanceRoot -ChildPath 'config\paxi\datapacks')
    $packBases += (Join-Path -Path $InstanceRoot -ChildPath 'openloader\data')
    $packBases += (Join-Path -Path $InstanceRoot -ChildPath 'global_packs\required_data')
}
if ($ExtraDataDirs) { $packBases += $ExtraDataDirs }

# De-duplicate: INSTANCE_DATAPACKS_FOLDER and a hand-passed -ExtraDataDirs
# pointing at the same place would otherwise scan and report it twice.
$seenBase = New-Object 'System.Collections.Generic.HashSet[string]'
$uniqueBases = New-Object System.Collections.ArrayList
foreach ($b in $packBases) {
    if (-not $b) { continue }
    $normB = $b.TrimEnd('\', '/').ToLowerInvariant()
    if ($seenBase.Add($normB)) { [void]$uniqueBases.Add($b) }
}
$packBases = @($uniqueBases)

$packRoots = @()
foreach ($base in $packBases) { $packRoots += (Get-DatapackRoots -Base $base) }

if ($packRoots.Count -gt 0) {
    Write-Host "Scanning $($packRoots.Count) datapack(s)..."
    foreach ($p in $packRoots) {
        Write-Host "  - $($p.Name)  [$($p.Kind)]"
        try {
            if ($p.Kind -eq 'zip') {
                Read-JarSource -JarPath $p.Path -SourceType 'datapack' -DisplayName $p.Name
            }
            else {
                Read-FolderSource -RootPath $p.Path -SourceType 'datapack' -DisplayName $p.Name
            }
        }
        catch {
            [void]$script:ParseErrors.Add([PSCustomObject]@{
                SourceName = $p.Name
                SourceType = 'datapack'
                File       = '<pack>'
                TagId      = ''
                Error      = $_.Exception.Message
            })
            Write-Host "    ! $($_.Exception.Message)" -ForegroundColor Red
        }
    }
}
else {
    Write-Host "No datapacks found in any configured or conventional location." -ForegroundColor Yellow
    Write-Host "  Set INSTANCE_PAXI_DATAPACKS_FOLDER in secrets.local.env, or pass -ExtraDataDirs," -ForegroundColor Yellow
    Write-Host "  if forgeeverything_datapack lives somewhere else." -ForegroundColor Yellow
}

# --- kubejs ---
if ($IncludeKubeJS) {
    if ($KubeJsFolder -and (Test-Path -LiteralPath (Join-Path -Path $KubeJsFolder -ChildPath 'data'))) {
        Write-Host "Scanning KubeJS data folder..."
        Read-FolderSource -RootPath $KubeJsFolder -SourceType 'kubejs' -DisplayName 'kubejs'
    }
    else {
        Write-Host "KubeJS data folder not present; skipping." -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Host "Building analyses..." -ForegroundColor Cyan

$tagFiles  = @($script:TagFiles)
$entryRows = @($script:EntryRows)

# --- merged view ---
$declaredIds = New-Object 'System.Collections.Generic.HashSet[string]'
$mergedList = New-Object System.Collections.ArrayList
foreach ($grp in ($tagFiles | Group-Object -Property TagId)) {
    [void]$declaredIds.Add($grp.Name)
    $rows = $grp.Group
    $srcs = @($rows | Select-Object -ExpandProperty SourceName -Unique)
    [void]$mergedList.Add([PSCustomObject]@{
        TagId           = $grp.Name
        Registry        = ($rows | Select-Object -First 1).Registry
        Namespace       = ($rows | Select-Object -First 1).Namespace
        DeclaringCount  = $srcs.Count
        DeclaredBy      = ($srcs -join '; ')
        TotalEntries    = ($rows | Measure-Object -Property EntryCount -Sum).Sum
        HasReplace      = (@($rows | Where-Object { $_.Replace }).Count -gt 0)
        HasRemove       = ((($rows | Measure-Object -Property RemoveCount -Sum).Sum) -gt 0)
        LegacyDirUsed   = (@($rows | Where-Object { $_.LegacyDirName }).Count -gt 0)
    })
}
$merged = @($mergedList)

# --- dangling tag references ---
$danglingList = New-Object System.Collections.ArrayList
foreach ($e in ($entryRows | Where-Object { $_.EntryType -eq 'tagref' -and $_.Action -eq 'add' })) {
    if (-not $declaredIds.Contains($e.EntryId)) {
        [void]$danglingList.Add([PSCustomObject]@{
            Severity       = $(if ($e.Required) { 'HARD' } else { 'soft' })
            ReferencingTag = $e.TagId
            MissingTag     = $e.EntryId
            Registry       = $e.Registry
            SourceName     = $e.SourceName
            File           = $e.File
        })
    }
}
$dangling = @($danglingList)

# --- unknown namespace entries ---
$unknownNsList = New-Object System.Collections.ArrayList
foreach ($e in ($entryRows | Where-Object { $_.EntryType -eq 'direct' -and $_.Action -eq 'add' })) {
    if (-not $script:KnownNs.Contains($e.EntryNs)) {
        [void]$unknownNsList.Add([PSCustomObject]@{
            Severity   = $(if ($e.Required) { 'HARD' } else { 'soft' })
            TagId      = $e.TagId
            EntryId    = $e.EntryId
            EntryNs    = $e.EntryNs
            Registry   = $e.Registry
            SourceName = $e.SourceName
            File       = $e.File
        })
    }
}
$unknownNs = @($unknownNsList)

# --- conflicts worth eyeballing ---
$conflicts = @($merged | Where-Object { $_.DeclaringCount -ge 3 -or $_.HasReplace -or $_.LegacyDirUsed } |
    Sort-Object -Property @{Expression='HasReplace';Descending=$true}, @{Expression='DeclaringCount';Descending=$true})

# --- unused candidates ---
$unused = @()
if ($ScanUsage) {
    # A tag referenced by another tag counts as used.
    foreach ($e in ($entryRows | Where-Object { $_.EntryType -eq 'tagref' })) {
        [void]$script:ReferencedTags.Add($e.EntryId)
    }
    $unusedList = New-Object System.Collections.ArrayList
    foreach ($m in $merged) {
        if (-not $script:ReferencedTags.Contains($m.TagId)) {
            [void]$unusedList.Add([PSCustomObject]@{
                TagId          = $m.TagId
                Registry       = $m.Registry
                DeclaringCount = $m.DeclaringCount
                DeclaredBy     = $m.DeclaredBy
                TotalEntries   = $m.TotalEntries
            })
        }
    }
    $unused = @($unusedList)
}

# ---------------------------------------------------------------------------
# Write outputs
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Writing to $OutputDir" -ForegroundColor Cyan

# Columns are declared explicitly rather than inferred from the first row, so a
# differently-shaped row later in the set cannot silently drop a column.
[void](Write-PackCsvFile -Rows $tagFiles -Path (Join-Path $OutputDir 'tags_raw.csv') -Columns @(
    'TagId','Registry','RegistryDir','LegacyDirName','Namespace','TagPath',
    'SourceName','SourceType','SourcePath','File','Replace',
    'EntryCount','OptionalCount','TagRefCount','RemoveCount','Preview'))

[void](Write-PackCsvFile -Rows $entryRows -Path (Join-Path $OutputDir 'tag_entries.csv') -Columns @(
    'TagId','Registry','SourceName','SourceType','Action','EntryType',
    'EntryId','EntryNs','Required','File'))

[void](Write-PackCsvFile -Rows $merged -Path (Join-Path $OutputDir 'tags_merged.csv') -Columns @(
    'TagId','Registry','Namespace','DeclaringCount','DeclaredBy','TotalEntries',
    'HasReplace','HasRemove','LegacyDirUsed'))

[void](Write-PackCsvFile -Rows $dangling -Path (Join-Path $OutputDir 'dangling_tag_refs.csv') -Columns @(
    'Severity','ReferencingTag','MissingTag','Registry','SourceName','File'))

[void](Write-PackCsvFile -Rows $unknownNs -Path (Join-Path $OutputDir 'unknown_namespace_entries.csv') -Columns @(
    'Severity','TagId','EntryId','EntryNs','Registry','SourceName','File'))

[void](Write-PackCsvFile -Rows $conflicts -Path (Join-Path $OutputDir 'declaring_conflicts.csv') -Columns @(
    'TagId','Registry','Namespace','DeclaringCount','DeclaredBy','TotalEntries',
    'HasReplace','HasRemove','LegacyDirUsed'))

[void](Write-PackCsvFile -Rows @($script:ParseErrors) -Path (Join-Path $OutputDir 'parse_errors.csv') -Columns @(
    'SourceName','SourceType','File','TagId','Error'))

if ($ScanUsage) {
    [void](Write-PackCsvFile -Rows $unused -Path (Join-Path $OutputDir 'unused_tags.csv') -Columns @(
        'TagId','Registry','DeclaringCount','DeclaredBy','TotalEntries'))
}

$masterJson = [PSCustomObject]@{
    generated        = (Get-Date).ToString('o')
    modpackVersion   = $ModpackVersion
    instanceRoot     = $InstanceRoot
    modsFolder       = $ModsFolder
    sourceJarCount   = $jars.Count
    datapackCount    = $packRoots.Count
    knownNamespaces  = (@($script:KnownNs) | Sort-Object)
    tags             = $merged
    files            = $tagFiles
} | ConvertTo-Json -Depth 6 -Compress
Write-PackTextFile -Path (Join-Path $OutputDir 'tags_master.json') -Content $masterJson
Write-Host ("  {0,-34} written" -f 'tags_master.json') -ForegroundColor DarkGray

# --- summary ---
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("Tag inventory - $((Get-Date).ToString('yyyy-MM-dd HH:mm:ss'))")
[void]$sb.AppendLine("Modpack version: $ModpackVersion")
[void]$sb.AppendLine("Mods folder: $ModsFolder")
[void]$sb.AppendLine('')
[void]$sb.AppendLine("Mod jars scanned          : $($jars.Count)")
[void]$sb.AppendLine("Datapacks scanned         : $($packRoots.Count)")
[void]$sb.AppendLine("Namespaces discovered     : $($script:KnownNs.Count)")
[void]$sb.AppendLine("Tag files found           : $($tagFiles.Count)")
[void]$sb.AppendLine("Unique tag IDs            : $($merged.Count)")
[void]$sb.AppendLine("Total entries             : $($entryRows.Count)")
[void]$sb.AppendLine('')
[void]$sb.AppendLine('FINDINGS')
[void]$sb.AppendLine("  Dangling tag refs (HARD): $(@($dangling | Where-Object { $_.Severity -eq 'HARD' }).Count)")
[void]$sb.AppendLine("  Dangling tag refs (soft): $(@($dangling | Where-Object { $_.Severity -eq 'soft' }).Count)")
[void]$sb.AppendLine("  Unknown-namespace (HARD): $(@($unknownNs | Where-Object { $_.Severity -eq 'HARD' }).Count)")
[void]$sb.AppendLine("  Unknown-namespace (soft): $(@($unknownNs | Where-Object { $_.Severity -eq 'soft' }).Count)")
[void]$sb.AppendLine("  Tags using replace=true : $(@($merged | Where-Object { $_.HasReplace }).Count)")
[void]$sb.AppendLine("  Legacy plural tag dirs  : $(@($merged | Where-Object { $_.LegacyDirUsed }).Count)")
[void]$sb.AppendLine("  Parse errors            : $($script:ParseErrors.Count)")
if ($ScanUsage) { [void]$sb.AppendLine("  Unused tag candidates   : $($unused.Count)") }
[void]$sb.AppendLine('')
[void]$sb.AppendLine('TOP TAGS BY DECLARING SOURCE COUNT')
foreach ($m in ($merged | Sort-Object -Property DeclaringCount -Descending | Select-Object -First 25)) {
    [void]$sb.AppendLine(("  {0,3}  {1}" -f $m.DeclaringCount, $m.TagId))
}
[void]$sb.AppendLine('')
[void]$sb.AppendLine('NOTE: static scan. Reports declarations, not the merged runtime result.')
[void]$sb.AppendLine('      "unused" ignores KubeJS scripts, Java code, and Almost Unified configs.')

Write-PackTextFile -Path (Join-Path $OutputDir 'summary.txt') -Content $sb.ToString()
Write-Host ("  {0,-34} written" -f 'summary.txt') -ForegroundColor DarkGray

Write-Host ""
Write-Host $sb.ToString()

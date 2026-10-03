<#
.SYNOPSIS
    Second-stage analysis of ore_item_scan.csv. Classifies every item/block
    entry into (Material, Form, Variant), then reports every combination that
    is provided by two or more mods.

.DESCRIPTION
    Stage 1 (scan_ore_items.ps1) casts a wide net and produces a lot of noise:
    GUI strings, book pages, food, decoration blocks. This script filters that
    down and answers the actual question -- "which mods are stepping on each
    other?" -- for ores, raw materials, raw blocks, storage blocks, ingots,
    dusts, nuggets, plates, gears, rods, wires, sheets, armor, tools and
    weapons.

    Noise rejection uses a two-pass vocabulary gate rather than a hardcoded
    mineral whitelist, so genuinely new materials still get caught:

      Pass 1 - parse every display name into Material + Form + Variant.
      Pass 2 - a Material only qualifies if it appears at least once in an
               UNAMBIGUOUS metallurgical form (Ingot / Dust / Nugget / Plate /
               Gear / Ore / Wire / Sheet).

    That is what kills "Raw Apple Pie" (RawMaterial, but "Apple Pie Ingot"
    never exists) while keeping "Raw Bauxite" (because "Bauxite Ore" does).

.PARAMETER InputFile
    The ore item scan CSV. Config key: ORE_SCAN_CSV.

.PARAMETER OutputFolder
    Where the output files are written when no per-file key is set.
    Config key: OUTPUT_DIR.

.PARAMETER ObsidianFolder
    Where Ore_Duplicate_Report.md goes. Config key: OBSIDIAN_VAULT_DIR. When
    unset the markdown lands alongside the CSVs. Set it and the report drops
    straight into the vault, wikilinks already resolving.

.PARAMETER MinModCount
    Minimum distinct mods providing a (Material, Form, Variant) combo before it
    counts as a duplicate. Default 2.

.PARAMETER IncludeSingles
    Also emit ore_classified_all.csv containing every parsed entry, including
    single-source ones. Useful for spotting materials the gate rejected.

.PARAMETER SecretsFile
    Override the settings file. Defaults to secrets.local.env beside the
    scripts, or $env:FORGE_EVERYTHING_SECRETS.

.NOTES
    - PS 5.1 compatible throughout. No -AsHashtable, no ternary, no ??.
    - Shared IO helpers come from PackConfig.ps1 (Write-PackTextFile,
      Write-PackCsvFile) rather than being redefined here.
    - Hashtables instead of Group-Object.
    - Uses -LiteralPath for all file reads.

    CONFIG KEYS READ
      ORE_SCAN_CSV                 input CSV
      OUTPUT_DIR                   default output folder
      OBSIDIAN_VAULT_DIR           destination for the markdown report
      ORE_DUPLICATES_DETAIL_CSV    per-file override
      ORE_DUPLICATES_SUMMARY_CSV   per-file override
      ORE_DUPLICATE_REPORT_MD      per-file override
      ORE_CLASSIFIED_ALL_CSV       per-file override
      MODPACK_VERSION              stamped into the report frontmatter
#>

param(
    [string]$InputFile,
    [string]$OutputFolder,
    [string]$ObsidianFolder,
    [int]   $MinModCount  = 2,
    [switch]$IncludeSingles,
    [string]$SecretsFile
)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

. (Join-Path $PSScriptRoot "PackConfig.ps1")
Initialize-PackConfig -SecretsFile $SecretsFile -ScriptRoot $PSScriptRoot

# ContainsKey guards: without them a value typed on the command line would be
# indistinguishable from a default, and the secrets file would quietly win.
if (-not $PSBoundParameters.ContainsKey('InputFile')) {
    $InputFile = Get-PackSetting -Name 'ORE_SCAN_CSV' -AsPath -Default (Join-Path $PSScriptRoot 'ore_item_scan.csv')
}
if (-not $PSBoundParameters.ContainsKey('OutputFolder')) {
    $OutputFolder = Get-PackSetting -Name 'OUTPUT_DIR' -AsPath -Default $PSScriptRoot
}
if (-not $PSBoundParameters.ContainsKey('ObsidianFolder')) {
    $ObsidianFolder = Get-PackSetting -Name 'OBSIDIAN_VAULT_DIR' -AsPath
}

$ModpackVersion = Get-PackSetting -Name 'MODPACK_VERSION' -Default 'unversioned'

# A typed -OutputFolder has to beat OUTPUT_DIR from the env file, so the
# per-file key lookup only runs when the folder was NOT given on the command
# line. Calling Get-PackOutputPath unconditionally would quietly send output to
# OUTPUT_DIR even though you just said otherwise.
$outputFolderWasTyped = $PSBoundParameters.ContainsKey('OutputFolder')

function Resolve-OreOutput {
    param([string]$Key, [string]$FileName)
    if ($outputFolderWasTyped) { return (Join-Path $OutputFolder $FileName) }
    return (Get-PackOutputPath -Name $Key -DefaultFileName $FileName -Default (Join-Path $OutputFolder $FileName))
}

$DetailPath  = Resolve-OreOutput -Key 'ORE_DUPLICATES_DETAIL_CSV'  -FileName 'ore_duplicates_detail.csv'
$SummaryPath = Resolve-OreOutput -Key 'ORE_DUPLICATES_SUMMARY_CSV' -FileName 'ore_duplicates_summary.csv'
$AllPath     = Resolve-OreOutput -Key 'ORE_CLASSIFIED_ALL_CSV'     -FileName 'ore_classified_all.csv'

# The markdown is the one output that wants to live somewhere else, because a
# report full of [[wikilinks]] is only useful inside the vault.
$MdPath = $null
if ($PSBoundParameters.ContainsKey('ObsidianFolder')) {
    $MdPath = Join-Path $ObsidianFolder 'Ore_Duplicate_Report.md'
}
elseif ($outputFolderWasTyped) {
    $MdPath = Join-Path $OutputFolder 'Ore_Duplicate_Report.md'
}
else {
    $MdPath = Get-PackSetting -Name 'ORE_DUPLICATE_REPORT_MD' -AsPath
    if (-not $MdPath) {
        if ($ObsidianFolder) { $MdPath = Join-Path $ObsidianFolder 'Ore_Duplicate_Report.md' }
        else                 { $MdPath = Join-Path $OutputFolder   'Ore_Duplicate_Report.md' }
    }
}

Show-PackConfigSummary -Title "Find-OreDuplicates" -Values @{
    'Input CSV'       = $InputFile
    'Output folder'   = $OutputFolder
    'Obsidian vault'  = $ObsidianFolder
    'Detail CSV'      = $DetailPath
    'Summary CSV'     = $SummaryPath
    'Markdown report' = $MdPath
    'Modpack version' = $ModpackVersion
    'Min mod count'   = $MinModCount
}

# ---------------------------------------------------------------------------
# Classification tables
# ---------------------------------------------------------------------------

# Suffix forms. ORDER MATTERS: longest / most specific first, because
# "Aluminum Double Ingot" must resolve to DoubleIngot, not Ingot.
$SuffixForms = @(
    @('Double Ingot','DoubleIngot','Intermediate'),
    @('Hot Ingot','HotIngot','Intermediate'),
    @('Ingot','Ingot','Intermediate'),
    @('Tiny Dust','TinyDust','Intermediate'),
    @('Small Dust','SmallDust','Intermediate'),
    @('Dirty Dust','DirtyDust','Intermediate'),
    @('Dust','Dust','Intermediate'),
    @('Nugget','Nugget','Intermediate'),
    @('Double Plate','DoublePlate','Intermediate'),
    @('Curved Plate','CurvedPlate','Intermediate'),
    @('Large Plate','LargePlate','Intermediate'),
    @('Plate','Plate','Intermediate'),
    @('Gear','Gear','Intermediate'),
    @('Wire','Wire','Intermediate'),
    @('Sheet','Sheet','Intermediate'),
    @('Rod','Rod','Intermediate'),
    @('Coin','Coin','Intermediate'),
    @('Ore','Ore','Worldgen'),
    @('Cluster','Cluster','Worldgen'),
    @('Chunk','Chunk','Worldgen'),
    @('Crystal','Crystal','Worldgen'),
    @('Shard','Shard','Intermediate'),
    @('Block','StorageBlock','Storage'),
    @('Helmet','Helmet','Armor'),
    @('Chestplate','Chestplate','Armor'),
    @('Leggings','Leggings','Armor'),
    @('Boots','Boots','Armor'),
    @('Pickaxe','Pickaxe','Tool'),
    @('Shovel','Shovel','Tool'),
    @('Hoe','Hoe','Tool'),
    @('Paxel','Paxel','Tool'),
    @('Shears','Shears','Tool'),
    @('Hammer','Hammer','Tool'),
    @('Excavator','Excavator','Tool'),
    @('Drill','Drill','Tool'),
    @('Sword','Sword','Weapon'),
    @('Greatsword','Greatsword','Weapon'),
    @('Battleaxe','Battleaxe','Weapon'),
    @('Dagger','Dagger','Weapon'),
    @('Spear','Spear','Weapon'),
    @('Scythe','Scythe','Weapon'),
    @('Halberd','Halberd','Weapon'),
    @('Crossbow','Crossbow','Weapon'),
    @('Bow','Bow','Weapon'),
    @('Shield','Shield','Weapon'),
    @('Axe','Axe','Tool')   # after Battleaxe/Greatsword so it doesn't steal them
)

# Host-stone / weathering prefixes. Stripped into a Variant column so
# "Deepslate Copper Ore" and "Copper Ore" are compared as separate blocks
# but still roll up under the material Copper.
$VariantPrefixes = @(
    'Deepslate','Blackslag','Nether','End Stone','Granite','Andesite',
    'Diorite','Tuff','Basalt','Sandstone','Gravel','Slate','Marble',
    'Limestone','Holystone','Depthrock','Shiverstone','Aether','Undergarden',
    'Exposed','Weathered','Oxidized','Waxed','Dark','Dense','Poor','Rich'
)

# Forms that prove a material is genuinely metallurgical.
$UnambiguousForms = @(
    'Ingot','DoubleIngot','HotIngot','Dust','TinyDust','SmallDust',
    'Nugget','Plate','DoublePlate','CurvedPlate','LargePlate',
    'Gear','Ore','Wire','Sheet'
)

# Phrases that hijack a suffix match. "Acacia Pressure Plate" would otherwise
# register the material "Acacia Pressure" in form Plate.
$ExcludePhrases = @(
    'Pressure Plate','Curtain Rod','Fishing Rod','Lightning Rod','Blaze Rod',
    'End Rod','Name Plate','License Plate','Hot Plate','Chiseled','Cracked',
    'Polished','Waxed Cut','Cut Copper'
)

# ---------------------------------------------------------------------------
# Load
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $InputFile)) {
    Write-Error "Input CSV not found: $InputFile"
    exit 1
}

Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Host "Reading $InputFile ..."

$rows = Import-Csv -LiteralPath $InputFile
Write-Host "  $($rows.Count) raw rows"

# ---------------------------------------------------------------------------
# Pass 1: parse
# ---------------------------------------------------------------------------

function Get-Classification {
    param([string]$Name)

    $n = $Name.Trim()

    foreach ($ex in $script:ExcludePhrases) {
        if ($n.IndexOf($ex, [StringComparison]::OrdinalIgnoreCase) -ge 0) { return $null }
    }

    $material = $null; $form = $null; $category = $null

    if ($n.StartsWith('Block of Raw ', [StringComparison]::Ordinal)) {
        $material = $n.Substring(13); $form = 'RawBlock'; $category = 'Storage'
    }
    elseif ($n.StartsWith('Block of ', [StringComparison]::Ordinal)) {
        $material = $n.Substring(9); $form = 'StorageBlock'; $category = 'Storage'
    }
    elseif ($n.StartsWith('Raw ', [StringComparison]::Ordinal) -and
            $n.EndsWith(' Block', [StringComparison]::Ordinal)) {
        $material = $n.Substring(4, $n.Length - 10); $form = 'RawBlock'; $category = 'Storage'
    }
    elseif ($n.StartsWith('Raw ', [StringComparison]::Ordinal)) {
        $material = $n.Substring(4); $form = 'RawMaterial'; $category = 'Worldgen'
    }
    else {
        foreach ($sf in $script:SuffixForms) {
            $suffix = ' ' + $sf[0]
            if ($n.EndsWith($suffix, [StringComparison]::Ordinal)) {
                $material = $n.Substring(0, $n.Length - $suffix.Length)
                $form     = $sf[1]
                $category = $sf[2]
                break
            }
        }
    }

    if ([string]::IsNullOrWhiteSpace($material)) { return $null }

    $variant = ''
    foreach ($vp in $script:VariantPrefixes) {
        $pfx = $vp + ' '
        if ($material.StartsWith($pfx, [StringComparison]::Ordinal) -and
            $material.Length -gt $pfx.Length) {
            $variant  = $vp
            $material = $material.Substring($pfx.Length)
            break
        }
    }

    $material = $material.Trim()
    if ([string]::IsNullOrWhiteSpace($material)) { return $null }

    return [PSCustomObject]@{
        Material = $material
        Form     = $form
        Category = $category
        Variant  = $variant
    }
}

$parsed = New-Object System.Collections.Generic.List[PSObject]
$skipped = 0

foreach ($r in $rows) {

    # Only real registry entries: item.<modid>.x / block.<modid>.x
    if ($r.RegistryKey -notmatch '^(item|block)\.[a-z0-9_]+\.') { $skipped++; continue }

    $dn = $r.DisplayName
    if ([string]::IsNullOrWhiteSpace($dn)) { $skipped++; continue }

    # Format strings, colour codes, multi-line tooltips, sentence fragments
    if ($dn.Contains('%') -or $dn.Contains([char]0x00A7) -or
        $dn.Contains("`n") -or $dn.Length -gt 45) { $skipped++; continue }

    $c = Get-Classification -Name $dn
    if ($null -eq $c) { $skipped++; continue }

    $parsed.Add([PSCustomObject]@{
        Material    = $c.Material
        Form        = $c.Form
        Category    = $c.Category
        Variant     = $c.Variant
        ModId       = $r.ModId
        Jar         = $r.Jar
        RegistryKey = $r.RegistryKey
        DisplayName = $dn
    })
}

Write-Host "  $($parsed.Count) entries classified, $skipped skipped as noise"

# ---------------------------------------------------------------------------
# Pass 2: vocabulary gate
# ---------------------------------------------------------------------------

$materialForms = @{}
foreach ($p in $parsed) {
    if (-not $materialForms.ContainsKey($p.Material)) { $materialForms[$p.Material] = @{} }
    $materialForms[$p.Material][$p.Form] = $true
}

$qualified = @{}
foreach ($mat in $materialForms.Keys) {
    foreach ($f in $UnambiguousForms) {
        if ($materialForms[$mat].ContainsKey($f)) { $qualified[$mat] = $true; break }
    }
}

Write-Host "  $($materialForms.Count) candidate materials, $($qualified.Count) passed the vocabulary gate"

# ---------------------------------------------------------------------------
# Group by Material + Form + Variant
# ---------------------------------------------------------------------------

$groups = @{}
foreach ($p in $parsed) {
    if (-not $qualified.ContainsKey($p.Material)) { continue }

    $key = $p.Material + '|' + $p.Form + '|' + $p.Variant
    if (-not $groups.ContainsKey($key)) {
        $groups[$key] = [PSCustomObject]@{
            Material = $p.Material
            Form     = $p.Form
            Category = $p.Category
            Variant  = $p.Variant
            Mods     = @{}
            Entries  = New-Object System.Collections.Generic.List[PSObject]
        }
    }
    $groups[$key].Mods[$p.ModId] = $true
    $groups[$key].Entries.Add($p)
}

$dupeKeys = New-Object System.Collections.Generic.List[string]
foreach ($k in $groups.Keys) {
    if ($groups[$k].Mods.Count -ge $MinModCount) { $dupeKeys.Add($k) }
}

$dupeMaterials = @{}
foreach ($k in $dupeKeys) { $dupeMaterials[$groups[$k].Material] = $true }

Write-Host ""
Write-Host "--- Results ---"
Write-Host "Duplicate groups (>= $MinModCount mods): $($dupeKeys.Count)"
Write-Host "Materials affected: $($dupeMaterials.Count)"
Write-Host "---------------"

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
# ConvertTo-PackCsvField / Write-PackTextFile now live in PackConfig.ps1 so
# every script in this folder writes files the same way.

# Sort keys: material, then category, then form, then variant
$sortedDupes = $dupeKeys | Sort-Object {
    $g = $groups[$_]
    '{0}|{1}|{2}|{3}' -f $g.Material, $g.Category, $g.Form, $g.Variant
}

# ---------------------------------------------------------------------------
# 1. Detail CSV - every duplicate item, one row each
# ---------------------------------------------------------------------------

$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('Material,Category,Form,Variant,ModCount,ModId,Jar,RegistryKey,DisplayName')

foreach ($k in $sortedDupes) {
    $g = $groups[$k]
    foreach ($e in ($g.Entries | Sort-Object ModId, DisplayName)) {
        $line = @(
            (ConvertTo-PackCsvField $g.Material)
            (ConvertTo-PackCsvField $g.Category)
            (ConvertTo-PackCsvField $g.Form)
            (ConvertTo-PackCsvField $g.Variant)
            $g.Mods.Count
            (ConvertTo-PackCsvField $e.ModId)
            (ConvertTo-PackCsvField $e.Jar)
            (ConvertTo-PackCsvField $e.RegistryKey)
            (ConvertTo-PackCsvField $e.DisplayName)
        ) -join ','
        [void]$sb.AppendLine($line)
    }
}

Write-PackTextFile -Path $DetailPath -Content $sb.ToString()
Write-Host "Wrote: $DetailPath"

# ---------------------------------------------------------------------------
# 2. Summary CSV - one row per duplicate group
# ---------------------------------------------------------------------------

$sb2 = New-Object System.Text.StringBuilder
[void]$sb2.AppendLine('Material,Category,Form,Variant,ModCount,EntryCount,Mods')

foreach ($k in $sortedDupes) {
    $g = $groups[$k]
    $modList = ($g.Mods.Keys | Sort-Object) -join '; '
    $line = @(
        (ConvertTo-PackCsvField $g.Material)
        (ConvertTo-PackCsvField $g.Category)
        (ConvertTo-PackCsvField $g.Form)
        (ConvertTo-PackCsvField $g.Variant)
        $g.Mods.Count
        $g.Entries.Count
        (ConvertTo-PackCsvField $modList)
    ) -join ','
    [void]$sb2.AppendLine($line)
}

Write-PackTextFile -Path $SummaryPath -Content $sb2.ToString()
Write-Host "Wrote: $SummaryPath"

# ---------------------------------------------------------------------------
# 3. Obsidian-ready markdown, grouped by material
# ---------------------------------------------------------------------------

$sb3 = New-Object System.Text.StringBuilder
[void]$sb3.AppendLine('---')
[void]$sb3.AppendLine('status: generated')
[void]$sb3.AppendLine('priority: high')
[void]$sb3.AppendLine("generated: $(Get-Date -Format 'yyyy-MM-dd')")
[void]$sb3.AppendLine('source: Find-OreDuplicates.ps1')
[void]$sb3.AppendLine("modpack_version: $ModpackVersion")
[void]$sb3.AppendLine('---')
[void]$sb3.AppendLine('')
[void]$sb3.AppendLine('# Ore Duplicate Report')
[void]$sb3.AppendLine('')
[void]$sb3.AppendLine("Cross-reference: [[Everything_Ores]] | [[Ore_Audit_Checklist]] | [[World_Gen_Config_Log]]")
[void]$sb3.AppendLine('')
[void]$sb3.AppendLine("**$($dupeKeys.Count)** duplicate groups across **$($dupeMaterials.Count)** materials, from $($rows.Count) scanned entries.")
[void]$sb3.AppendLine('')
[void]$sb3.AppendLine("Generated from modpack version **$ModpackVersion**. Regenerate after any mod list change - a stale table here is worse than no table.")
[void]$sb3.AppendLine('')

# Per-material mod counts for the overview table
$matModCounts = @{}
$matGroupCounts = @{}
foreach ($k in $dupeKeys) {
    $g = $groups[$k]
    if (-not $matModCounts.ContainsKey($g.Material)) { $matModCounts[$g.Material] = @{} }
    foreach ($m in $g.Mods.Keys) { $matModCounts[$g.Material][$m] = $true }
    if ($matGroupCounts.ContainsKey($g.Material)) { $matGroupCounts[$g.Material]++ }
    else { $matGroupCounts[$g.Material] = 1 }
}

$matOrder = $matModCounts.Keys | Sort-Object { -$matModCounts[$_].Count }, { $_ }

[void]$sb3.AppendLine('## Overview')
[void]$sb3.AppendLine('')
[void]$sb3.AppendLine('| Material | Mods | Dupe Forms | Unified? |')
[void]$sb3.AppendLine('| --- | --- | --- | --- |')
foreach ($mat in $matOrder) {
    [void]$sb3.AppendLine("| $mat | $($matModCounts[$mat].Count) | $($matGroupCounts[$mat]) | [ ] |")
}
[void]$sb3.AppendLine('')
[void]$sb3.AppendLine('## Detail')
[void]$sb3.AppendLine('')

foreach ($mat in $matOrder) {
    [void]$sb3.AppendLine("### $mat")
    [void]$sb3.AppendLine('')
    [void]$sb3.AppendLine('| Category | Form | Variant | Mods | Providers |')
    [void]$sb3.AppendLine('| --- | --- | --- | --- | --- |')

    $matKeys = $sortedDupes | Where-Object { $groups[$_].Material -eq $mat }
    foreach ($k in $matKeys) {
        $g = $groups[$k]
        $v = $g.Variant
        if ([string]::IsNullOrWhiteSpace($v)) { $v = '-' }
        $modList = ($g.Mods.Keys | Sort-Object) -join ', '
        [void]$sb3.AppendLine("| $($g.Category) | $($g.Form) | $v | $($g.Mods.Count) | ``$modList`` |")
    }
    [void]$sb3.AppendLine('')
}

Write-PackTextFile -Path $MdPath -Content $sb3.ToString()
Write-Host "Wrote: $MdPath"

# ---------------------------------------------------------------------------
# 4. Optional: everything classified, including single-source
# ---------------------------------------------------------------------------

if ($IncludeSingles) {
    $sb4 = New-Object System.Text.StringBuilder
    [void]$sb4.AppendLine('Material,Category,Form,Variant,Qualified,ModId,Jar,RegistryKey,DisplayName')
    foreach ($p in ($parsed | Sort-Object Material, Form, ModId)) {
        $q = 'no'
        if ($qualified.ContainsKey($p.Material)) { $q = 'yes' }
        $line = @(
            (ConvertTo-PackCsvField $p.Material)
            (ConvertTo-PackCsvField $p.Category)
            (ConvertTo-PackCsvField $p.Form)
            (ConvertTo-PackCsvField $p.Variant)
            $q
            (ConvertTo-PackCsvField $p.ModId)
            (ConvertTo-PackCsvField $p.Jar)
            (ConvertTo-PackCsvField $p.RegistryKey)
            (ConvertTo-PackCsvField $p.DisplayName)
        ) -join ','
        [void]$sb4.AppendLine($line)
    }
    Write-PackTextFile -Path $AllPath -Content $sb4.ToString()
    Write-Host "Wrote: $AllPath"
}

# ---------------------------------------------------------------------------
# Console summary
# ---------------------------------------------------------------------------

Write-Host ""
Write-Host "Top materials by provider count:"
$shown = 0
foreach ($mat in $matOrder) {
    if ($shown -ge 20) { break }
    $modsStr = ($matModCounts[$mat].Keys | Sort-Object) -join ', '
    Write-Host ("  {0,-16} {1,2} mods  {2}" -f $mat, $matModCounts[$mat].Count, $modsStr)
    $shown++
}

$catCounts = @{}
foreach ($k in $dupeKeys) {
    $c = $groups[$k].Category
    if ($catCounts.ContainsKey($c)) { $catCounts[$c]++ } else { $catCounts[$c] = 1 }
}
Write-Host ""
Write-Host "Duplicate groups by category:"
foreach ($c in ($catCounts.Keys | Sort-Object { -$catCounts[$_] })) {
    Write-Host ("  {0,-14} {1}" -f $c, $catCounts[$c])
}
Write-Host ""
Write-Host "Done."

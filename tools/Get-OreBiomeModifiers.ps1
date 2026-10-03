<#
.SYNOPSIS
  Get-OreBiomeModifiers.ps1 — scans mod jars for biome modifiers and writes
  no-op suppression overrides for a REVIEWED allowlist of them.

.DESCRIPTION
  v1.1.0 change: -WriteOverrides no longer writes every keyword match. The
  keyword filter is a discovery aid and over-matches by design — it flagged
  Electrodynamics thorium/vanadium/molybdenum/sylvite, MI antimony and lignite
  coal, Occultism iesnium, and XyCraft's xychorium as "ore", none of which
  everythingores owns. Writing those would delete single-source materials from
  world generation.

  So the script now carries $SuppressList: an explicit modid -> modifier map,
  verified against the v1.0.0 jar scan of the pack. Only those are written.
  Everything else is reported in one of two review buckets:

    CANDIDATE — keyword match, not on the allowlist. Review before adding.
    OTHER     — no keyword match (structures, springs, non-ore features).

.EXAMPLE
  .\Get-OreBiomeModifiers.ps1
      Report only. Shows SUPPRESS / CANDIDATE / OTHER classification.

.EXAMPLE
  .\Get-OreBiomeModifiers.ps1 -WriteOverrides
      Writes no-op overrides for the allowlist only.

.EXAMPLE
  .\Get-OreBiomeModifiers.ps1 -ShowCandidates
      Lists only the keyword matches that are NOT on the allowlist, to review
      after a mod update adds new ores.
#>
[CmdletBinding()]
param(
    [string]$ModsDir,
    [string]$DatapackDir,
    [switch]$WriteOverrides,
    [switch]$ShowCandidates,
    # v1.3.0: read each modifier's JSON and record which mod namespaces its
    # features reference. A jar can ship modifiers under ANOTHER namespace
    # (Witchery ships its two under 'neoforge'), so path-namespace alone
    # misattributes them - and a mod whose ore gen lives in someone else's
    # file is invisible to a namespace-keyed scan.
    [bool]$Deep = $true,
    # Report every modifier whose features reference this material, in any
    # namespace or file. Use when a mod's ore generates but no modifier of
    # its own turns up - e.g. .\Get-OreBiomeModifiers.ps1 -FindMaterial silver
    [string]$FindMaterial,
    # v1.4.0: list EVERY worldgen entry a mod ships - biome modifiers,
    # configured features, placed features. Use when a mod's ore generates
    # but it ships no biome modifier, to find out what mechanism it uses.
    #   .\Get-OreBiomeModifiers.ps1 -InspectMod werewolves
    [string]$InspectMod,
    # v1.4.0: print the full JSON body of matching modifiers, so a bundle
    # name like 'add_overworld_ores' can be read for what it actually places.
    #   .\Get-OreBiomeModifiers.ps1 -Expand stellaris:add_overworld_ores
    #   .\Get-OreBiomeModifiers.ps1 -Expand 'silentgear:*ores*'
    [string]$Expand,
    # v1.2.0: empty = scan EVERY mod. The v1.1.0 hand-curated list silently
    # hid Create, Ice and Fire, and Werewolves - all three ship duplicate ores.
    # Only pass this to narrow a noisy run; never rely on it for coverage.
    [string[]]$TargetMods = @(),
    [string[]]$OreKeywords = @(
        'ore','tin','lead','nickel','aluminum','bauxite','zinc','silver','uranium',
        'uraninite','platinum','sulfur','saltpeter','niter','salt','monazite',
        'lithium','chromium','chromite','fluorite','titanium','tungsten','iridium'
    )
)

$Version = '1.5.0'
Write-Output "Get-OreBiomeModifiers.ps1 v$Version"

# ---------------------------------------------------------------------------
# REVIEWED ALLOWLIST — materials everythingores owns. Verified against jars.
# Add here only after confirming EO registers a canonical for that material.
# ---------------------------------------------------------------------------
$SuppressList = @{
    'createnuclear'            = @('lead_ore','uranium_ore')
    'electrodynamics'          = @('ore_aluminum','ore_chromium','ore_fluorite','ore_lead',
                                   'ore_lithium','ore_monazite','ore_niter','ore_salt',
                                   'ore_silver','ore_sulfur','ore_tin','ore_titanium','ore_uranium')
    'immersiveengineering'     = @('silver','bauxite','lead','nickel','deep_nickel','uranium')
    'mekanism'                 = @('tin','lead','uranium','fluorite','salt')
    'modern_industrialization' = @('ore_generator_bauxite','deepslate_ore_generator_bauxite',
                                   'ore_generator_lead','deepslate_ore_generator_lead',
                                   'ore_generator_monazite','deepslate_ore_generator_monazite',
                                   'ore_generator_nickel','deepslate_ore_generator_nickel',
                                   'ore_generator_salt','deepslate_ore_generator_salt',
                                   'ore_generator_tin','deepslate_ore_generator_tin',
                                   'ore_generator_tungsten','deepslate_ore_generator_tungsten',
                                   'ore_generator_uranium','deepslate_ore_generator_uranium')
    'occultism'                = @('add_ore_silver','add_ore_silver_deepslate')
    # Wildcards below resolve against actual jar contents - no guessed names.
    # Verify what they matched in the SUPPRESS rows before -WriteOverrides.
    'create'                   = @('zinc_ore')
    'iceandfire'               = @('silver_ore')
    # Nested path - v1.2.0's '*silver*' matched nothing only because the scan
    # regex could not see into subdirectories. Fixed in v1.5.0.
    'werewolves'               = @('gen/silver_ore')
    'xycraft_world'            = @('ore_aluminum')
    'oritech'                  = @('ore_nickel','ore_platinum','uranium_patch')
    'tfmg'                     = @('lead_ore','lithium_ore','nickel_ore')
}

# Deliberately excluded — single-source materials or non-ore features.
# Kept as documentation so a future reader knows these were considered.
$ExcludedNotes = @{
    'electrodynamics:ore_thorium'          = 'single-source material'
    'electrodynamics:ore_vanadium'         = 'single-source material'
    'electrodynamics:ore_molybdenum'       = 'single-source material'
    'electrodynamics:ore_sylvite'          = 'distinct mineral, single-source'
    'modern_industrialization:*antimony*'  = 'single-source material'
    'modern_industrialization:*lignite*'   = 'single-source material'
    'immersiveengineering:mineral_veins'   = 'excavator system, not ore blocks'
    'mekanism:osmium'                      = 'handoff 3.3 single-source - see notes'
    'occultism:add_ore_iesnium'            = 'single-source material'
    'oritech:ore_platinum_end'             = 'End dimension, EO worldgen is overworld'
    'powah:uraninite_ore*'                 = 'uraninite is a distinct material - deferred, see notes'
    'createnuclear:striated_ores_overworld' = 'Create ore-bearing stone (autunite), not ore blocks'
    'tfmg:tfmg_striated_ores_*'            = 'Create ore-bearing stone (galena, bauxite), not ore blocks'
    'xycraft_world:ore_kivi / ore_xy_*'    = 'XyCraft-exclusive materials'
}

Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

if (-not $PSBoundParameters.ContainsKey('ModsDir') -or [string]::IsNullOrEmpty($ModsDir)) {
    if ($env:FE_MODS_DIR) { $ModsDir = $env:FE_MODS_DIR }
    else { $ModsDir = Join-Path $env:APPDATA 'ModrinthApp\profiles\Forge Everything\mods' }
}
if (-not $PSBoundParameters.ContainsKey('DatapackDir') -or [string]::IsNullOrEmpty($DatapackDir)) {
    if ($env:FE_DATAPACK_DIR) { $DatapackDir = $env:FE_DATAPACK_DIR }
    else { $DatapackDir = Join-Path $env:APPDATA 'ModrinthApp\profiles\Forge Everything\datapacks\forgeeverything_datapack' }
}

if (-not (Test-Path -LiteralPath $ModsDir)) { Write-Error "Mods directory not found: $ModsDir"; exit 1 }
Write-Output "Mods dir     : $ModsDir"
Write-Output "Datapack dir : $DatapackDir"
Write-Output ""

# ---------------------------------------------------------------------------
# -InspectMod : every worldgen entry a namespace ships, in any jar
# ---------------------------------------------------------------------------
if ($InspectMod) {
    $wrx = "^data/$([regex]::Escape($InspectMod))/(neoforge/biome_modifier|worldgen/[^/]+)/(?<name>.+)\.json$"
    $rows = New-Object System.Collections.Generic.List[object]
    Get-ChildItem -LiteralPath $ModsDir -Filter '*.jar' | ForEach-Object {
        $zip = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($_.FullName)
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName -match $wrx) {
                    $kind = ($entry.FullName -split '/')[2..3] -join '/'
                    $rows.Add([pscustomobject]@{ Jar = $_.Name; Kind = $kind; Name = $Matches['name'] })
                }
            }
        } catch { Write-Warning ("Could not read {0}" -f $_.FullName) }
        finally { if ($zip) { $zip.Dispose() } }
    }
    if (-not $rows) {
        Write-Output ("'{0}' ships no worldgen data files at all - no biome modifiers, no configured or placed features." -f $InspectMod)
        Write-Output "Its world generation is therefore config-driven or code-registered."
        Write-Output "  - Config: look in config\ for a toggle. This is the preferred fix (handoff 5.5)."
        Write-Output "  - Code-registered: a datapack override cannot reach it. Options are a mixin"
        Write-Output "    in everythingbugs, or accepting the duplicate and relying on Almost Unified"
        Write-Output "    to unify the items it drops."
    } else {
        $rows | Sort-Object Kind, Name | Format-Table -AutoSize | Out-String | Write-Output
        Write-Output "A placed/configured feature with NO biome modifier means something else injects it."
    }
    return
}

# ---------------------------------------------------------------------------
# -Expand : print the JSON body of matching modifiers
# ---------------------------------------------------------------------------
if ($Expand) {
    $parts = $Expand -split ':', 2
    $wantMod = $parts[0]; $wantName = if ($parts.Count -gt 1) { $parts[1] } else { '*' }
    $erx = '^data/(?<mod>[^/]+)/neoforge/biome_modifier/(?<name>.+)\.json$'
    Get-ChildItem -LiteralPath $ModsDir -Filter '*.jar' | ForEach-Object {
        $zip = $null
        try {
            $zip = [System.IO.Compression.ZipFile]::OpenRead($_.FullName)
            foreach ($entry in $zip.Entries) {
                if ($entry.FullName -match $erx) {
                    if ($Matches['mod'] -like $wantMod -and $Matches['name'] -like $wantName) {
                        $sr = New-Object System.IO.StreamReader($entry.Open())
                        $body = $sr.ReadToEnd(); $sr.Close()
                        Write-Output ("===== {0}:{1}   ({2})" -f $Matches['mod'], $Matches['name'], $_.Name)
                        Write-Output $body
                        Write-Output ""
                    }
                }
            }
        } catch { Write-Warning ("Could not read {0}" -f $_.FullName) }
        finally { if ($zip) { $zip.Dispose() } }
    }
    return
}

$found = New-Object System.Collections.Generic.List[object]
# v1.5.0 BUG FIX: the name group was [^/]+, which cannot match a slash, so
# every modifier nested in a subdirectory was silently invisible to the scan.
# Werewolves files its as gen/silver_ore. Now .+ so nested paths are found.
$rx = '^data/(?<mod>[^/]+)/neoforge/biome_modifier/(?<name>.+)\.json$'

Get-ChildItem -LiteralPath $ModsDir -Filter '*.jar' | ForEach-Object {
    $zip = $null
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($_.FullName)
        foreach ($entry in $zip.Entries) {
            if ($entry.FullName -match $rx) {
                $mod = $Matches['mod']; $name = $Matches['name']
                if ($TargetMods.Count -eq 0 -or $TargetMods -contains $mod) {
                    $onList = $false
                    if ($SuppressList.ContainsKey($mod)) {
                        foreach ($pat in $SuppressList[$mod]) {
                            # exact match, or wildcard pattern resolved against the real name
                            if ($name -eq $pat -or ($pat -match '[\*\?]' -and $name -like $pat)) { $onList = $true; break }
                        }
                    }
                    $kw     = [bool]($OreKeywords | Where-Object { $name -like "*$_*" })
                    $status = if ($onList) { 'SUPPRESS' } elseif ($kw) { 'CANDIDATE' } else { 'OTHER' }
                    $refs = ''
                    if ($Deep) {
                        try {
                            $sr = New-Object System.IO.StreamReader($entry.Open())
                            $json = $sr.ReadToEnd(); $sr.Close()
                            $ns = [regex]::Matches($json, '"([a-z0-9_.-]+):[a-z0-9_./-]+"') |
                                  ForEach-Object { $_.Groups[1].Value } |
                                  Where-Object { $_ -notin @('minecraft','neoforge','c') } |
                                  Sort-Object -Unique
                            $refs = ($ns -join ',')
                        } catch {
                            Write-Warning ("Could not read modifier body {0}!{1}" -f $_.Name, $entry.FullName)
                        }
                    }
                    $found.Add([pscustomobject]@{
                        Jar = $_.Name; ModId = $mod; Modifier = $name; Status = $status; Refs = $refs
                    })
                }
            }
        }
    } catch {
        Write-Warning ("Could not read {0}: {1}" -f $_.FullName, $_.Exception.Message)
    } finally { if ($zip) { $zip.Dispose() } }
}

if ($FindMaterial) {
    $hits = $found | Where-Object { $_.Refs -match $FindMaterial -or $_.Modifier -match $FindMaterial }
    if (-not $hits) {
        Write-Output ("No biome modifier in any jar references '{0}'." -f $FindMaterial)
        Write-Output "That ore is generated some other way. Check, in order:"
        Write-Output "  1. the mod's config (worldgen / ore generation toggles) - preferred fix per handoff 5.5"
        Write-Output "  2. a built-in datapack outside data/<mod>/neoforge/biome_modifier/"
        Write-Output "  3. code-registered worldgen, which a datapack cannot suppress at all"
    } else {
        $hits | Sort-Object ModId, Modifier | Format-Table ModId, Modifier, Refs, Jar -AutoSize | Out-String | Write-Output
    }
    return
}

if ($ShowCandidates) {
    $found | Where-Object { $_.Status -eq 'CANDIDATE' } | Sort-Object ModId, Modifier |
        Format-Table ModId, Modifier -AutoSize | Out-String | Write-Output
    Write-Output "These matched an ore keyword but are NOT on the allowlist. Add one to `$SuppressList only if everythingores registers a canonical for that material."
} else {
    $found | Sort-Object Status, ModId, Modifier |
        Format-Table Jar, ModId, Modifier, Status, Refs -AutoSize | Out-String | Write-Output

    # A modifier whose path namespace is not among its own references usually
    # means the shipping jar filed it under someone else's namespace.
    $odd = $found | Where-Object { $Deep -and $_.Refs -and ($_.Refs -split ',') -notcontains $_.ModId }
    if ($odd) {
        Write-Output "Modifiers filed under a namespace that differs from what they reference:"
        $odd | Format-Table Jar, ModId, Modifier, Refs -AutoSize | Out-String | Write-Output
    }
}

# Allowlist entries that no jar actually ships — stale or renamed by an update
foreach ($mod in $SuppressList.Keys) {
    foreach ($name in $SuppressList[$mod]) {
        if ($name -match '[\*\?]') {
            $hits = $found | Where-Object { $_.ModId -eq $mod -and $_.Modifier -like $name }
            if (-not $hits) { Write-Warning ("Allowlist pattern matched nothing: {0}:{1}" -f $mod, $name) }
            else { Write-Output ("Pattern {0}:{1} matched -> {2}" -f $mod, $name, (($hits | ForEach-Object { $_.Modifier }) -join ', ')) }
        } else {
            $hit = $found | Where-Object { $_.ModId -eq $mod -and $_.Modifier -eq $name }
            if (-not $hit) { Write-Warning ("Allowlist entry not present in any jar: {0}:{1} (mod removed, or renamed by an update)" -f $mod, $name) }
        }
    }
}

if ($WriteOverrides) {
    $written = 0
    foreach ($m in ($found | Where-Object { $_.Status -eq 'SUPPRESS' })) {
        # Modifier names can contain subdirectories (e.g. werewolves' gen/silver_ore),
        # so the override must be written at the identical nested path.
        $relative = ($m.Modifier -replace '/', '\') + '.json'
        $file = Join-Path $DatapackDir ("data\{0}\neoforge\biome_modifier\{1}" -f $m.ModId, $relative)
        $dir = Split-Path -Parent $file
        if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append('{ "type": "neoforge:none" }')
        [System.IO.File]::WriteAllText($file, $sb.ToString())
        $written++
    }
    Write-Output ""
    Write-Output "Wrote $written allowlisted override(s)."
    Write-Output "Verify in game with /neoforge dump (biome modifier registry) plus a fresh-chunk world test."
}

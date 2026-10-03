<#
.SYNOPSIS
    Scans all mod jars in a Modrinth/CurseForge mods folder for ore-related
    item/block registry entries (ores, raw materials, ingots, dusts, nuggets,
    plates, gears, storage blocks) by reading each jar's en_us.json lang file.

.NOTES
    - Follows known PowerShell pitfalls: uses StringBuilder + File.WriteAllText
      instead of Set-Content (which silently fails on large output), and a
      hashtable instead of Group-Object (which hangs on large datasets).
    - Does NOT extract jars to disk; reads zip entries in-memory via
      System.IO.Compression.
#>

param(
    [string]$ModsFolder = "C:\Users\Terra\AppData\Roaming\ModrinthApp\profiles\Forge Everything\mods",
    [string]$OutputFile = "$PSScriptRoot\ore_item_scan.csv"
)

Add-Type -AssemblyName System.IO.Compression.FileSystem

# Broad pattern match on the registry KEY (item.<modid>.xxx / block.<modid>.xxx)
# Catches raw ores, raw materials, ingots, dusts, nuggets, plates, gears, rods,
# storage blocks, and generic "_ore" blocks regardless of specific mineral name.
$keyPattern = '(?i)(_ore\b|^item\.[a-z0-9_]+\.raw_|^block\.[a-z0-9_]+\.raw_|_ingot\b|^item\.[a-z0-9_]+\.ingot_|_dust\b|^item\.[a-z0-9_]+\.dust_|_nugget\b|_plate\b|_gear\b|_rod\b|block_of_|storage_block|_cluster\b|_chunk\b|deepslate_.*_ore)'

# Known mineral / element keywords (confirmed dupes + likely dupes + common
# real-world ore-mineral names, so genuinely new finds get flagged too)
$mineralKeywords = @(
    'copper','tin','lead','nickel','aluminum','aluminium','bauxite','uranium',
    'zinc','silver','platinum','sulfur','sulphur','saltpeter','salt','halite',
    'monazite','chromium','chromite','fluorite','titanium','rutile','ilmenite',
    'osmium','draconium','yellorium','certus','zanite','ambrosium',
    'cobalt','cobaltite','iridium','tungsten','scheelite','molybdenum',
    'molybdenite','cassiterite','galena','sphalerite','pentlandite',
    'uraninite','pitchblende','cinnabar','mercury','argentite','pyrite',
    'chalcopyrite','bornite','magnetite','hematite','bismuth','antimony',
    'stibnite','thorium','lithium','rare_earth','niobium','tantalum'
)
$mineralPattern = ($mineralKeywords -join '|')

$results = New-Object System.Collections.Generic.List[PSObject]
$jarFiles = Get-ChildItem -Path $ModsFolder -Filter *.jar -File

Write-Host "PowerShell version: $($PSVersionTable.PSVersion)"
Write-Host "Scanning $($jarFiles.Count) jars in $ModsFolder ..."

$diag = @{
    JarOpenFailures   = 0
    LangEntriesFound  = 0
    JsonParseFailures = 0
    JarsWithNoLang    = 0
}
$firstErrorsShown = 0

$count = 0
foreach ($jar in $jarFiles) {
    $count++
    if ($count % 50 -eq 0) { Write-Host "  ...$count / $($jarFiles.Count)" }

    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($jar.FullName)
    } catch {
        $diag.JarOpenFailures++
        continue
    }

    try {
        $langEntries = $zip.Entries | Where-Object {
            $_.FullName -match '^assets/[^/]+/lang/en_us\.json$'
        }

        if ($langEntries.Count -eq 0) {
            $diag.JarsWithNoLang++
        }

        foreach ($entry in $langEntries) {
            $diag.LangEntriesFound++
            $modId = ($entry.FullName -split '/')[1]

            $stream = $entry.Open()
            $reader = New-Object System.IO.StreamReader($stream)
            $jsonText = $reader.ReadToEnd()
            $reader.Close()
            $stream.Close()

            # ConvertFrom-Json WITHOUT -AsHashtable: works on Windows PowerShell
            # 5.1 as well as PS7+. Returns a PSCustomObject; walk its properties
            # instead of hashtable keys.
            try {
                $langObj = $jsonText | ConvertFrom-Json -ErrorAction Stop
            } catch {
                $diag.JsonParseFailures++
                if ($firstErrorsShown -lt 5) {
                    Write-Host "  [PARSE FAIL] $($jar.Name) -> $($entry.FullName): $($_.Exception.Message)"
                    $firstErrorsShown++
                }
                continue
            }

            foreach ($prop in $langObj.PSObject.Properties) {
                $key = $prop.Name
                $displayName = [string]$prop.Value

                if ($key -match $keyPattern -or $displayName -match $mineralPattern) {
                    $results.Add([PSCustomObject]@{
                        Jar         = $jar.Name
                        ModId       = $modId
                        RegistryKey = $key
                        DisplayName = $displayName
                    })
                }
            }
        }
    } finally {
        $zip.Dispose()
    }
}

Write-Host ""
Write-Host "--- Diagnostics ---"
Write-Host "Jars that failed to open as zip: $($diag.JarOpenFailures)"
Write-Host "Jars with no assets/*/lang/en_us.json: $($diag.JarsWithNoLang)"
Write-Host "Total lang files found across all jars: $($diag.LangEntriesFound)"
Write-Host "Lang files that failed JSON parsing: $($diag.JsonParseFailures)"
Write-Host "-------------------"

Write-Host "Found $($results.Count) matching entries. Writing CSV..."

# StringBuilder + File.WriteAllText per known Set-Content pitfall
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine('Jar,ModId,RegistryKey,DisplayName')
foreach ($r in $results) {
    $jarEsc  = '"' + ($r.Jar -replace '"','""') + '"'
    $modEsc  = '"' + ($r.ModId -replace '"','""') + '"'
    $keyEsc  = '"' + ($r.RegistryKey -replace '"','""') + '"'
    $nameEsc = '"' + ($r.DisplayName -replace '"','""') + '"'
    [void]$sb.AppendLine("$jarEsc,$modEsc,$keyEsc,$nameEsc")
}

[System.IO.File]::WriteAllText($OutputFile, $sb.ToString())

Write-Host "Done. Output written to: $OutputFile"
Write-Host "Total matching entries: $($results.Count)"

# Quick summary: unique mod IDs that had matches (hashtable approach, not Group-Object)
$modCounts = @{}
foreach ($r in $results) {
    if ($modCounts.ContainsKey($r.ModId)) {
        $modCounts[$r.ModId]++
    } else {
        $modCounts[$r.ModId] = 1
    }
}
Write-Host ""
Write-Host "Mods with ore-related entries: $($modCounts.Count)"

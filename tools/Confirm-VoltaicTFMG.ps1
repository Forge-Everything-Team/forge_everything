<#
.SYNOPSIS
    Gathers confirmation evidence for the Voltaic / TFMG ("Path B") portion of the
    ATL Dedupe Investigation Report before mixins are written against them.

.DESCRIPTION
    Per report section 6 ("Residual risks"):
        - Voltaic (voltaic-1.21.1-1.0.11.jar) and TFMG (tfmg-1.2.0.jar) were never
          supplied as jars for this investigation. Their mutation sites
          (CountableIngredient#getItemsArray/#getItems, WindingCategory(.AssemblyWinding)#setRecipe)
          come only from stack traces, not bytecode.
        - Before writing mixins 2 and 3 (section 4), those two classes need to be
          pulled out of the mods folder and disassembled/decompiled to confirm the
          exact expressions to wrap.
        - The Path B error breakdown (229 CountableIngredient#getItemsArray / 1
          #getItems / 6 WindingCategory) should be re-confirmed against a fresh
          log before trusting it as a target list.

    This script does three things:
        1. Locates the Voltaic and TFMG jars in the mods folder.
        2. Extracts the relevant .class files (CountableIngredient from Voltaic;
           WindingCategory + WindingCategory$AssemblyWinding from TFMG, whose
           package path isn't known in advance so it's discovered by scanning
           jar entries) and runs `javap -p -c -l` against each for a line-numbered
           bytecode disassembly. Optionally also runs an external decompiler jar
           (CFR / Vineflower) if you point -DecompilerJar at one, for readable
           source instead of just bytecode.
        3. Re-scans a log file for the Path B signatures and reproduces the
           per-mutation-site / per-namespace breakdown table from report section
           1.1, so you can confirm counts still line up (or see what's changed)
           before/after applying a fix.

.PARAMETER ModsDir
    Folder containing the mod jars. Defaults to the Forge Everything modpack
    instance's mods folder.

.PARAMETER LogPath
    Path to the log to re-scan for Path B signatures. Defaults to latest.log
    next to ModsDir's parent (…/logs/latest.log), overridable.

.PARAMETER OutDir
    Where extracted class files, javap output, and the summary report are written.

.PARAMETER DecompilerJar
    Optional path to a CFR or Vineflower jar. If supplied, each extracted class
    is also run through it for readable Java source (falls back to javap-only
    if omitted or if java/the jar isn't found).

.EXAMPLE
    .\Confirm-VoltaicTFMG.ps1

.EXAMPLE
    .\Confirm-VoltaicTFMG.ps1 -ModsDir "C:\Users\Terra\AppData\Roaming\ModrinthApp\profiles\NeoForge 1.21.1\mods" `
                               -LogPath "C:\Users\Terra\AppData\Roaming\ModrinthApp\profiles\NeoForge 1.21.1\logs\latest.log" `
                               -DecompilerJar "C:\tools\cfr-0.152.jar"
#>

[CmdletBinding()]
param(
    [string]$ModsDir = "$env:APPDATA\ModrinthApp\profiles\Forge Everything\mods",
    [string]$LogPath,
    [string]$OutDir = ".\atl-voltaic-tfmg-confirmation",
    [string]$DecompilerJar,
    [string]$JavapPath
)

$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

if (-not (Test-Path $ModsDir)) {
    throw "Mods directory not found: $ModsDir. Pass -ModsDir explicitly."
}

if (-not $LogPath) {
    $instanceRoot = Split-Path $ModsDir -Parent
    $LogPath = Join-Path $instanceRoot "logs\latest.log"
}

New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
$classDir  = Join-Path $OutDir "extracted-classes"
$javapDir  = Join-Path $OutDir "javap"
$decompDir = Join-Path $OutDir "decompiled"
foreach ($d in @($classDir, $javapDir, $decompDir)) {
    New-Item -ItemType Directory -Path $d -Force | Out-Null
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-Section($title) {
    Write-Host ""
    Write-Host "=== $title ===" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Step 1: locate jars
# ---------------------------------------------------------------------------

function Find-ModJar {
    param([string]$NamePattern, [string]$FriendlyName)

    $matches = Get-ChildItem -Path $ModsDir -Filter "*.jar" -File |
        Where-Object { $_.Name -match $NamePattern }

    if ($matches.Count -eq 0) {
        Write-Warning "No jar matching pattern '$NamePattern' found in $ModsDir for $FriendlyName."
        return $null
    }
    if ($matches.Count -gt 1) {
        Write-Warning "Multiple candidates found for $FriendlyName; using the first. Review the list below:"
        $matches | ForEach-Object { Write-Host "  - $($_.Name)" }
    }
    return $matches[0].FullName
}

Write-Section "Locating jars"
$voltaicJar = Find-ModJar -NamePattern '^voltaic.*\.jar$' -FriendlyName "Voltaic"
$tfmgJar    = Find-ModJar -NamePattern '^tfmg.*\.jar$'    -FriendlyName "TFMG"

if ($voltaicJar) { Write-Host "Voltaic jar: $voltaicJar" }
if ($tfmgJar)    { Write-Host "TFMG jar:    $tfmgJar" }

# ---------------------------------------------------------------------------
# Step 2: extract target class files
# ---------------------------------------------------------------------------

function Get-ZipEntries {
    param([string]$JarPath)
    $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    try {
        return $zip.Entries | ForEach-Object { $_.FullName }
    }
    finally {
        $zip.Dispose()
    }
}

function Extract-ZipEntry {
    param([string]$JarPath, [string]$EntryFullName, [string]$DestDir)

    $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath)
    try {
        $entry = $zip.Entries | Where-Object { $_.FullName -eq $EntryFullName } | Select-Object -First 1
        if (-not $entry) {
            Write-Warning "Entry not found in jar: $EntryFullName"
            return $null
        }
        $destPath = Join-Path $DestDir ($entry.Name)
        [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destPath, $true)
        return $destPath
    }
    finally {
        $zip.Dispose()
    }
}

function ClassEntryToFqcn {
    param([string]$EntryFullName)
    return ($EntryFullName -replace '\.class$', '') -replace '/', '.'
}

$extracted = @()   # each item: @{ Fqcn = ...; ClassFile = ...; SourceJar = ...; Component = ... }

Write-Section "Extracting Voltaic: CountableIngredient"
if ($voltaicJar) {
    $voltaicEntries = Get-ZipEntries -JarPath $voltaicJar
    $ciEntries = $voltaicEntries | Where-Object { $_ -match 'CountableIngredient(\$.*)?\.class$' }

    if ($ciEntries.Count -eq 0) {
        Write-Warning "CountableIngredient.class not found under the expected package. Dumping any 'recipeutils' entries for manual inspection:"
        $voltaicEntries | Where-Object { $_ -match 'recipeutils' } | ForEach-Object { Write-Host "  - $_" }
    }
    else {
        foreach ($entry in $ciEntries) {
            $classFile = Extract-ZipEntry -JarPath $voltaicJar -EntryFullName $entry -DestDir $classDir
            if ($classFile) {
                $extracted += [pscustomobject]@{
                    Fqcn      = ClassEntryToFqcn $entry
                    ClassFile = $classFile
                    SourceJar = $voltaicJar
                    Component = "Voltaic"
                }
                Write-Host "Extracted: $entry -> $classFile"
            }
        }
    }
}

Write-Section "Extracting TFMG: WindingCategory (+ nested AssemblyWinding)"
if ($tfmgJar) {
    $tfmgEntries = Get-ZipEntries -JarPath $tfmgJar
    $wcEntries = $tfmgEntries | Where-Object { $_ -match 'WindingCategory(\$.*)?\.class$' }

    if ($wcEntries.Count -eq 0) {
        Write-Warning "WindingCategory.class not found. Dumping any 'winding' entries for manual inspection:"
        $tfmgEntries | Where-Object { $_ -match 'winding' -or $_ -match 'Winding' } | ForEach-Object { Write-Host "  - $_" }
    }
    else {
        foreach ($entry in $wcEntries) {
            $classFile = Extract-ZipEntry -JarPath $tfmgJar -EntryFullName $entry -DestDir $classDir
            if ($classFile) {
                $extracted += [pscustomobject]@{
                    Fqcn      = ClassEntryToFqcn $entry
                    ClassFile = $classFile
                    SourceJar = $tfmgJar
                    Component = "TFMG"
                }
                Write-Host "Extracted: $entry -> $classFile"
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Step 3: disassemble (javap) and optionally decompile
# ---------------------------------------------------------------------------

function Test-CommandExists {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Resolve-JavapPath {
    # 0. Explicit override
    if ($JavapPath -and (Test-Path $JavapPath)) { return $JavapPath }

    # 1. Already on PATH
    $onPath = Get-Command javap -ErrorAction SilentlyContinue
    if ($onPath) { return $onPath.Source }

    # 2. JAVA_HOME
    if ($env:JAVA_HOME) {
        $candidate = Join-Path $env:JAVA_HOME "bin\javap.exe"
        if (Test-Path $candidate) { return $candidate }
    }

    # 3. Known dev-environment JDK (per project notes: Oracle JDK 21)
    $known = "C:\Program Files\Java\jdk-21\bin\javap.exe"
    if (Test-Path $known) { return $known }

    # 4. Any jdk-* under Program Files\Java
    $guess = Get-ChildItem "C:\Program Files\Java" -Directory -Filter "jdk-*" -ErrorAction SilentlyContinue |
        Sort-Object Name -Descending | Select-Object -First 1
    if ($guess) {
        $candidate = Join-Path $guess.FullName "bin\javap.exe"
        if (Test-Path $candidate) { return $candidate }
    }

    return $null
}

Write-Section "Disassembling extracted classes (javap -p -c -l)"

$javapPath = Resolve-JavapPath
if (-not $javapPath) {
    Write-Warning "javap not found on PATH, via JAVA_HOME, or at C:\Program Files\Java\jdk-21\bin."
    Write-Warning "Fix by either:"
    Write-Warning '  $env:PATH = "C:\Program Files\Java\jdk-21\bin;" + $env:PATH'
    Write-Warning "or re-run with an explicit path once added: -JavapPath <path to javap.exe>"
}
else {
    Write-Host "Using javap: $javapPath"
    foreach ($item in $extracted) {
        $outFile = Join-Path $javapDir (($item.Fqcn -replace '\.', '_') + ".javap.txt")
        Write-Host "javap: $($item.Fqcn) -> $outFile"

        # -p: show all members (private included) -- these are the ones we need
        # -c: bytecode
        # -l: line number + local variable tables, needed to confirm the report's
        #     line ~104 / line ~61 call sites
        $javapArgs = @("-p", "-c", "-l", "-classpath", $item.SourceJar, $item.Fqcn)
        $result = & $javapPath @javapArgs 2>&1

        $sb = [System.Text.StringBuilder]::new()
        [void]$sb.AppendLine("# javap output for $($item.Fqcn)")
        [void]$sb.AppendLine("# Source jar: $($item.SourceJar)")
        [void]$sb.AppendLine("# Command: `"$javapPath`" $($javapArgs -join ' ')")
        [void]$sb.AppendLine("")
        [void]$sb.AppendLine(($result -join [Environment]::NewLine))

        [System.IO.File]::WriteAllText($outFile, $sb.ToString())
    }
}

if ($DecompilerJar) {
    Write-Section "Decompiling extracted classes ($DecompilerJar)"
    if (-not (Test-CommandExists "java")) {
        Write-Warning "java not found on PATH; skipping decompilation."
    }
    elseif (-not (Test-Path $DecompilerJar)) {
        Write-Warning "Decompiler jar not found at $DecompilerJar; skipping decompilation."
    }
    else {
        foreach ($item in $extracted) {
            Write-Host "Decompiling: $($item.Fqcn)"
            # CFR-style invocation: java -jar cfr.jar <classfile> --outputdir <dir>
            # If using Vineflower instead, the flag is the same (--outputdir); adjust here if your
            # decompiler's CLI differs.
            & java -jar $DecompilerJar $item.ClassFile --outputdir $decompDir 2>&1 |
                Out-File -FilePath (Join-Path $decompDir "$($item.Fqcn -replace '\.', '_').decompile.log") -Encoding utf8
        }
        Write-Host "Decompiled source (if successful) will be under: $decompDir"
    }
}
else {
    Write-Host "(No -DecompilerJar supplied; skipping readable-source decompilation. javap bytecode above is still enough to pin exact call sites/line numbers.)"
}

# ---------------------------------------------------------------------------
# Step 4: re-confirm Path B error counts/breakdown from the log
# ---------------------------------------------------------------------------

Write-Section "Re-confirming Path B signatures against log: $LogPath"

if (-not (Test-Path $LogPath)) {
    Write-Warning "Log file not found at $LogPath. Skipping log confirmation. Pass -LogPath explicitly."
}
else {
    $logLines = Get-Content -Path $LogPath

    # Report baseline (single session, section 1.1):
    #   CountableIngredient#getItemsArray : 229
    #   CountableIngredient#getItems      : 1
    #   WindingCategory(.AssemblyWinding)#setRecipe : 6
    #   Total Path B ("Found a broken recipe")       : 236

    # IMPORTANT: a single JEI "Found a broken recipe" error can print the same
    # class/method reference more than once within its own block (the warning
    # message, an "at ..." stack frame, and sometimes a repeated "Caused by:"
    # trace). Counting every matching *line* with Select-String therefore
    # over-counts relative to the number of actual events. To get an
    # apples-to-apples comparison against the report's baseline (which counts
    # events, not lines), we group the log into per-event blocks first: each
    # block starts at a "Found a broken recipe" line and runs until the next
    # top-level log line (one that starts with a timestamp), i.e. it captures
    # that error's full stack trace and nothing past it.

    $timestampAtLineStart = '^\[[^\]\r\n]*\]\s*\[[^\]\r\n]*\]'  # "[time] [thread/level]" -- the
                                                                  # real per-line marker in MC/log4j
                                                                  # output. A single bracket group
                                                                  # (just a timestamp) turned out to
                                                                  # still occasionally appear inside
                                                                  # stack-trace/message content, which
                                                                  # let blocks bleed into the next event.
    $maxBlockLines = 500  # safety valve: if no next timestamped line appears within this many
                          # lines, stop anyway rather than silently sweeping to EOF (which is
                          # what caused the original bug when the timestamp format didn't match).
    $totalLines = $logLines.Count

    $events = New-Object System.Collections.Generic.List[string]
    $nearWindowLines = 40  # actual single-exception stack traces run well under this; matching
                            # against only the first N lines of a block prevents a missed boundary
                            # further downstream from bleeding into this event's classification.
    $eventsNear = New-Object System.Collections.Generic.List[string]
    $safetyValveHits = 0
    for ($i = 0; $i -lt $totalLines; $i++) {
        if ($logLines[$i] -match 'Found a broken recipe') {
            $blockLines = New-Object System.Collections.Generic.List[string]
            $blockLines.Add($logLines[$i])
            $j = $i + 1
            while ($j -lt $totalLines -and ($logLines[$j] -notmatch $timestampAtLineStart) -and ($blockLines.Count -lt $maxBlockLines)) {
                $blockLines.Add($logLines[$j])
                $j++
            }
            if ($blockLines.Count -ge $maxBlockLines) { $safetyValveHits++ }
            $events.Add(($blockLines -join "`n"))
            $nearCount = [Math]::Min($nearWindowLines, $blockLines.Count)
            $eventsNear.Add(($blockLines[0..($nearCount - 1)] -join "`n"))
        }
    }

    if ($safetyValveHits -gt 0) {
        Write-Warning "$safetyValveHits event block(s) hit the $maxBlockLines-line safety cap without finding a timestamped line."
        Write-Warning "This means the timestamp regex likely still doesn't match this log's format -- counts below may be unreliable."
        Write-Warning "Check a sample line manually and adjust `$timestampAtLineStart in the script if needed."
    }

    $getItemsArrayEvents = 0
    $getItemsEvents      = 0
    $windingEvents       = 0
    $namespaceCounts     = @{}

    foreach ($eventText in $eventsNear) {
        if ($eventText -match 'CountableIngredient\.getItemsArray') { $getItemsArrayEvents++ }
        elseif ($eventText -match 'CountableIngredient\.getItems\b') { $getItemsEvents++ }

        if ($eventText -match 'WindingCategory(\$AssemblyWinding)?\.setRecipe') { $windingEvents++ }

        # modid:path token, e.g. "electrodynamics:mineral_grinder/copper" or "create:winding/...".
        # Require the modid to start with a letter so timestamps (e.g. "09:37:33") never match.
        $idMatch = [regex]::Match($eventText, '(?<!\d)\b([a-z][a-z0-9_]*):([a-z0-9_/]+)')
        if ($idMatch.Success) {
            $ns = $idMatch.Groups[1].Value
            if (-not $namespaceCounts.ContainsKey($ns)) { $namespaceCounts[$ns] = 0 }
            $namespaceCounts[$ns]++
        }
    }

    $atlUnsupportedLines = $logLines | Select-String -Pattern 'ATLUnsupportedOperation'

    $summary = [System.Text.StringBuilder]::new()
    [void]$summary.AppendLine("Path B confirmation summary")
    [void]$summary.AppendLine("Log scanned: $LogPath")
    [void]$summary.AppendLine("Generated:   $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    [void]$summary.AppendLine("")
    [void]$summary.AppendLine("(Counts below are per DISTINCT EVENT -- i.e. per 'Found a broken recipe' block --")
    [void]$summary.AppendLine("not per matching log line, so a frame repeated within one event's stack trace")
    [void]$summary.AppendLine("is not double-counted.)")
    [void]$summary.AppendLine("")
    [void]$summary.AppendLine("Total ATLUnsupportedOperation lines (all paths, raw):  $($atlUnsupportedLines.Count)")
    [void]$summary.AppendLine("Total 'Found a broken recipe' events (Path B, JEI):    $($events.Count)   (report baseline: 236)")
    [void]$summary.AppendLine("  CountableIngredient.getItemsArray setCount:          $getItemsArrayEvents   (report baseline: 229)")
    [void]$summary.AppendLine("  CountableIngredient.getItems (one-off) setCount:     $getItemsEvents     (report baseline: 1)")
    [void]$summary.AppendLine("  WindingCategory(.AssemblyWinding).setRecipe:         $windingEvents     (report baseline: 6)")
    [void]$summary.AppendLine("")
    [void]$summary.AppendLine("Namespace breakdown (one match per event, from the recipe id in that event's block):")
    foreach ($kv in ($namespaceCounts.GetEnumerator() | Sort-Object -Property Value -Descending)) {
        [void]$summary.AppendLine("  $($kv.Key): $($kv.Value)")
    }
    [void]$summary.AppendLine("")
    [void]$summary.AppendLine("Note: if getItemsArray + getItems + Winding != total events, some events used a")
    [void]$summary.AppendLine("mutation site not covered by the three patterns above -- inspect those blocks")
    [void]$summary.AppendLine("manually (search the log for 'Found a broken recipe' and check which line hit)")
    [void]$summary.AppendLine("before assuming the mixin fix targets are complete.")

    $summaryText = $summary.ToString()
    Write-Host ""
    Write-Host $summaryText

    $summaryPath = Join-Path $OutDir "path-b-confirmation-summary.txt"
    [System.IO.File]::WriteAllText($summaryPath, $summaryText)
    Write-Host "Summary written to: $summaryPath"
}

Write-Section "Done"
Write-Host "Extracted classes:   $classDir"
Write-Host "javap disassembly:   $javapDir"
if ($DecompilerJar) { Write-Host "Decompiled source:   $decompDir" }
Write-Host "Log confirmation:    $OutDir\path-b-confirmation-summary.txt"
Write-Host ""
Write-Host "Next step per report section 6: open the javap (or decompiled) output for" -ForegroundColor Yellow
Write-Host "CountableIngredient and WindingCategory, confirm the exact expressions around" -ForegroundColor Yellow
Write-Host "line ~104 (getItemsArray/getItems) and line ~61 (setRecipe), then write the" -ForegroundColor Yellow
Write-Host "copy-before-mutate mixins described in report section 4." -ForegroundColor Yellow
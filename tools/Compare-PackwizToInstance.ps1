#Requires -Version 5.1
<#
.SYNOPSIS
    Diffs the packwiz pack definition against a live instance's mods folder.

.DESCRIPTION
    Answers one question: does the instance you actually play match the pack you
    ship to everyone else?

    The pack declares mods two different ways, and both have to be handled:

      .pw.toml metafiles   remote mods (Modrinth or CurseForge). The authoritative
                           thing is the `filename` field -- that is the exact jar
                           packwiz-installer will place in the instance.
      raw .jar files       local/proprietary mods committed straight into the pack.
                           These carry a sha256 in index.toml, so content drift is
                           detectable even when the filename has not changed.

    Matching is by exact filename first. Anything left over is paired up by a
    normalized "stem" (version tokens, loader names and mc versions stripped), which
    is what catches the common case of the same mod at a different version on each
    side. Only genuinely unpaired entries are reported as missing or extra.

    `side` is respected: a side = "server" entry is not expected in a client
    instance and is reported as SKIPPED_SIDE rather than missing.

    This is a read-only comparison. It changes nothing in either location.

    CONFIGURATION
    Paths can live in secrets.local.env instead of the command line:

        INSTANCE_ROOT=C:\Users\Terra\AppData\Roaming\ModrinthApp\profiles\Forge Everything
        INSTANCE_MODS_FOLDER=${INSTANCE_ROOT}\mods      # optional; derived if omitted
        PACKWIZ_DIR=.\packwiz
        OUTPUT_DIR=.\reports

    A command-line parameter always beats the file.

.PARAMETER PackwizDir
    The folder holding pack.toml. Falls back to PACKWIZ_DIR, then .\packwiz.

.PARAMETER ModsFolder
    The live instance's mods folder. Falls back to INSTANCE_MODS_FOLDER, then
    INSTANCE_ROOT\mods.

.PARAMETER Side
    Which side the instance represents: client or server. Controls which entries are
    expected to be present. Default client.

.PARAMETER OutputCsv
    Where to write the diff. Falls back to OUTPUT_DIR\packwiz-instance-diff.csv,
    then .\reports.

.PARAMETER SkipHash
    Skip sha256 comparison of local jars. Faster, but content drift in a
    proprietary mod whose filename did not change will go unnoticed.

.PARAMETER SecretsFile
    Path to the settings file. Defaults to $env:FORGE_EVERYTHING_SECRETS, else
    secrets.local.env beside this script.

.EXAMPLE
    .\Compare-PackwizToInstance.ps1
    Full diff using paths from secrets.local.env.

.EXAMPLE
    .\Compare-PackwizToInstance.ps1 -Side server
    Check a server instance instead (client-only entries become SKIPPED_SIDE).
#>

[CmdletBinding()]
param(
    [string] $PackwizDir,
    [string] $ModsFolder,
    [ValidateSet('client', 'server')]
    [string] $Side = 'client',
    [string] $OutputCsv,
    [switch] $SkipHash,
    [string] $SecretsFile
)

$ScriptVersion = '1.0.0'
Write-Host "Compare-PackwizToInstance.ps1 v$ScriptVersion" -ForegroundColor Cyan

# --------------------------------------------------------------------------
# Config resolution: explicit param -> env var -> secrets file -> default
# --------------------------------------------------------------------------

$sharedModule = Join-Path $PSScriptRoot 'PackConfig.ps1'
if (Test-Path -LiteralPath $sharedModule) {
    . $sharedModule
    Write-Host "  loaded PackConfig.ps1" -ForegroundColor DarkGray
}

if (-not $SecretsFile) {
    $SecretsFile = $env:FORGE_EVERYTHING_SECRETS
    if (-not $SecretsFile) { $SecretsFile = Join-Path $PSScriptRoot 'secrets.local.env' }
}

$script:Secrets = @{}
if (Test-Path -LiteralPath $SecretsFile) {
    foreach ($line in [IO.File]::ReadAllLines($SecretsFile)) {
        if ($line -match "^\s*([A-Za-z0-9_]+)\s*=\s*'?(.*?)'?\s*$") {
            $script:Secrets[$Matches[1]] = $Matches[2]
        }
    }
    # Allow ${VAR} interpolation between settings, as the other scripts do.
    # Plain String.Replace, not -replace: these values are Windows paths and the
    # backslashes must not be treated as regex escapes.
    foreach ($k in @($script:Secrets.Keys)) {
        $v = $script:Secrets[$k]
        $guard = 0
        while ($v -match '\$\{([A-Za-z0-9_]+)\}' -and $guard -lt 10) {
            $ref = $Matches[1]
            $sub = if ($script:Secrets.ContainsKey($ref)) { $script:Secrets[$ref] } else { '' }
            $v = $v.Replace('${' + $ref + '}', $sub)
            $guard++
        }
        $script:Secrets[$k] = $v
    }
}

function Resolve-Setting {
    param([string] $ParamName, [string] $Key, [string] $Default)
    if ($PSBoundParameters.ContainsKey($ParamName)) {
        return (Get-Variable -Name $ParamName -ValueOnly -Scope 1)
    }
    $envVal = [Environment]::GetEnvironmentVariable($Key)
    if (-not [string]::IsNullOrWhiteSpace($envVal)) { return $envVal }
    if ($script:Secrets.ContainsKey($Key) -and -not [string]::IsNullOrWhiteSpace($script:Secrets[$Key])) {
        return $script:Secrets[$Key]
    }
    return $Default
}

if (-not $PackwizDir) {
    $PackwizDir = Resolve-Setting -ParamName 'PackwizDir' -Key 'PACKWIZ_DIR' `
                                  -Default (Join-Path $PSScriptRoot 'packwiz')
}
if (-not $ModsFolder) {
    $ModsFolder = Resolve-Setting -ParamName 'ModsFolder' -Key 'INSTANCE_MODS_FOLDER' -Default ''
    if (-not $ModsFolder) {
        $root = Resolve-Setting -ParamName 'ModsFolder' -Key 'INSTANCE_ROOT' -Default ''
        if ($root) { $ModsFolder = Join-Path $root 'mods' }
    }
}
if (-not $OutputCsv) {
    $outDir = Resolve-Setting -ParamName 'OutputCsv' -Key 'OUTPUT_DIR' `
                              -Default (Join-Path $PSScriptRoot 'reports')
    $OutputCsv = Join-Path $outDir 'packwiz-instance-diff.csv'
}

$packMods = Join-Path $PackwizDir 'mods'
foreach ($p in @($PackwizDir, $packMods, $ModsFolder)) {
    if (-not $p -or -not (Test-Path -LiteralPath $p)) {
        Write-Error "Path not found: '$p'. Pass -PackwizDir / -ModsFolder or set them in $SecretsFile."
        exit 1
    }
}
Write-Host "  packwiz : $PackwizDir" -ForegroundColor DarkGray
Write-Host "  instance: $ModsFolder" -ForegroundColor DarkGray
Write-Host "  side    : $Side" -ForegroundColor DarkGray

# --------------------------------------------------------------------------
# Read the pack definition
# --------------------------------------------------------------------------

# Normalizes a jar filename down to something comparable across versions, so the
# same mod at two different versions collapses to the same stem.
#
# Tokens are dropped only when they LOOK like a version, never merely because
# they contain a digit -- otherwise names such as "skinlayers3d" lose the part
# that identifies them. Version shapes seen in this pack include 1.21.1, 0.3.0,
# r5.8.1, beta.2, v2, and mc1.21.1.
function Get-Stem {
    param([string] $Name)
    $s = $Name -replace '\.jar$', ''
    $s = $s.ToLowerInvariant()
    $s = $s -replace '[+_]', '-'
    $parts = $s -split '-' | Where-Object {
        $_ -and
        $_ -notmatch '^\d[\d.]*$' -and                              # 1.21.1, 0.3.0
        $_ -notmatch '^[vr]\d[\d.]*$' -and                          # v2, r5.8.1
        $_ -notmatch '^(beta|alpha|rc|pre|snapshot|build|release)[\d.]*$' -and
        $_ -notmatch '^(neoforge|forge|fabric|quilt|mc|v)$' -and
        $_ -notmatch '^mc\d'                                        # mc1.21.1
    }
    return ($parts -join '')
}

$expected = New-Object System.Collections.Generic.List[object]

foreach ($f in Get-ChildItem -LiteralPath $packMods -Filter '*.pw.toml' -File) {
    $text = Get-Content -LiteralPath $f.FullName -Raw
    $name = if ($text -match '(?m)^name\s*=\s*"(.*?)"') { $Matches[1] } else { $f.BaseName }
    $fn = if ($text -match '(?m)^filename\s*=\s*"(.*?)"') { $Matches[1] } else { $null }
    $sd = if ($text -match '(?m)^side\s*=\s*"(.*?)"') { $Matches[1] } else { 'both' }
    $src = if ($text -match 'update\.modrinth') { 'modrinth' }
           elseif ($text -match 'update\.curseforge') { 'curseforge' }
           else { 'unknown' }
    if (-not $fn) {
        Write-Warning "No filename in $($f.Name); skipping."
        continue
    }
    $expected.Add([pscustomobject]@{
        Entry = $f.Name; Name = $name; Filename = $fn; Side = $sd
        Source = $src; Kind = 'metafile'; Sha256 = $null; Stem = (Get-Stem $fn)
    })
}

# Raw jars committed into the pack. index.toml carries their sha256.
$indexPath = Join-Path $PackwizDir 'index.toml'
$indexHashes = @{}
if (Test-Path -LiteralPath $indexPath) {
    $idx = Get-Content -LiteralPath $indexPath -Raw
    foreach ($m in [regex]::Matches($idx, '(?m)^file\s*=\s*"(.+?)"\s*\r?\nhash\s*=\s*"([0-9a-f]+)"')) {
        $indexHashes[$m.Groups[1].Value] = $m.Groups[2].Value
    }
}

foreach ($f in Get-ChildItem -LiteralPath $packMods -Filter '*.jar' -File) {
    $rel = "mods/$($f.Name)"
    $expected.Add([pscustomobject]@{
        Entry = $f.Name; Name = $f.BaseName; Filename = $f.Name; Side = 'both'
        Source = 'local'; Kind = 'localjar'
        Sha256 = $(if ($indexHashes.ContainsKey($rel)) { $indexHashes[$rel] } else { $null })
        Stem = (Get-Stem $f.Name)
    })
}

$actual = Get-ChildItem -LiteralPath $ModsFolder -Filter '*.jar' -File
Write-Host ("  pack declares {0} mod(s); instance has {1} jar(s)" -f $expected.Count, $actual.Count) -ForegroundColor DarkGray

# --------------------------------------------------------------------------
# Diff
# --------------------------------------------------------------------------

$actualByName = @{}
foreach ($a in $actual) { $actualByName[$a.Name] = $a }

$rows = New-Object System.Collections.Generic.List[object]
$matchedActual = New-Object 'System.Collections.Generic.HashSet[string]'
$unmatchedExpected = New-Object System.Collections.Generic.List[object]

function Test-SideApplies {
    param([string] $EntrySide)
    if ($EntrySide -eq 'both') { return $true }
    return ($EntrySide -eq $Side)
}

foreach ($e in $expected) {
    if (-not (Test-SideApplies $e.Side)) {
        $rows.Add([pscustomobject]@{
            Status = 'SKIPPED_SIDE'; Mod = $e.Name; PackwizEntry = $e.Entry
            Expected = $e.Filename; InInstance = ''; Side = $e.Side; Source = $e.Source
            Note = "side=$($e.Side); not expected on $Side"
        })
        if ($actualByName.ContainsKey($e.Filename)) { [void]$matchedActual.Add($e.Filename) }
        continue
    }
    if ($actualByName.ContainsKey($e.Filename)) {
        [void]$matchedActual.Add($e.Filename)
        $note = ''
        $status = 'OK'
        if ($e.Kind -eq 'localjar' -and $e.Sha256 -and -not $SkipHash) {
            $h = (Get-FileHash -LiteralPath $actualByName[$e.Filename].FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($h -ne $e.Sha256.ToLowerInvariant()) {
                $status = 'CONTENT_DIFFERS'
                $note = 'same filename, different bytes - pack copy is stale or diverged'
            }
        }
        $rows.Add([pscustomobject]@{
            Status = $status; Mod = $e.Name; PackwizEntry = $e.Entry
            Expected = $e.Filename; InInstance = $e.Filename; Side = $e.Side
            Source = $e.Source; Note = $note
        })
    }
    else {
        $unmatchedExpected.Add($e)
    }
}

$leftoverActual = @($actual | Where-Object { -not $matchedActual.Contains($_.Name) })

# Pair leftovers by stem: same mod, different version on each side.
$actualStems = @{}
foreach ($a in $leftoverActual) {
    $st = Get-Stem $a.Name
    if (-not $actualStems.ContainsKey($st)) { $actualStems[$st] = New-Object System.Collections.Generic.List[object] }
    $actualStems[$st].Add($a)
}

$pairedActual = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($e in $unmatchedExpected) {
    if ($actualStems.ContainsKey($e.Stem) -and $actualStems[$e.Stem].Count -gt 0) {
        $a = $actualStems[$e.Stem][0]
        $actualStems[$e.Stem].RemoveAt(0)
        [void]$pairedActual.Add($a.Name)
        $status = 'VERSION_DIFFERS'
        $note = 'filename differs - version drift between pack and instance'
        # For a local jar both copies are on disk, so we can tell a pure rename
        # from an actual rebuild. That changes the fix: one needs a filename
        # decision, the other needs the new build copied into the pack.
        if ($e.Kind -eq 'localjar' -and -not $SkipHash) {
            $packJar = Join-Path $packMods $e.Filename
            if (Test-Path -LiteralPath $packJar) {
                $hp = (Get-FileHash -LiteralPath $packJar -Algorithm SHA256).Hash
                $hi = (Get-FileHash -LiteralPath $a.FullName -Algorithm SHA256).Hash
                if ($hp -eq $hi) {
                    $status = 'RENAMED_ONLY'
                    $note = 'identical bytes, different filename - naming mismatch only'
                }
                else {
                    $note = 'local jar rebuilt since it was committed to the pack'
                }
            }
        }
        $rows.Add([pscustomobject]@{
            Status = $status; Mod = $e.Name; PackwizEntry = $e.Entry
            Expected = $e.Filename; InInstance = $a.Name; Side = $e.Side
            Source = $e.Source; Note = $note
        })
    }
    else {
        $rows.Add([pscustomobject]@{
            Status = 'MISSING_FROM_INSTANCE'; Mod = $e.Name; PackwizEntry = $e.Entry
            Expected = $e.Filename; InInstance = ''; Side = $e.Side
            Source = $e.Source; Note = 'declared in pack, not installed'
        })
    }
}

foreach ($a in $leftoverActual) {
    if ($pairedActual.Contains($a.Name)) { continue }
    $rows.Add([pscustomobject]@{
        Status = 'EXTRA_IN_INSTANCE'; Mod = [IO.Path]::GetFileNameWithoutExtension($a.Name)
        PackwizEntry = ''; Expected = ''; InInstance = $a.Name; Side = ''
        Source = 'untracked'
        Note = 'present locally, not declared in the pack - other users will not get it'
    })
}

# --------------------------------------------------------------------------
# Report
# --------------------------------------------------------------------------

$outDir = Split-Path -Parent $OutputCsv
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
}
$order = @{ 'CONTENT_DIFFERS' = 0; 'MISSING_FROM_INSTANCE' = 1; 'EXTRA_IN_INSTANCE' = 2
            'VERSION_DIFFERS' = 3; 'RENAMED_ONLY' = 4; 'SKIPPED_SIDE' = 5; 'OK' = 6 }
$sorted = $rows | Sort-Object @{ e = { $order[$_.Status] } }, Mod
$sorted | Export-Csv -LiteralPath $OutputCsv -NoTypeInformation -Encoding UTF8

Write-Host ''
$counts = $rows | Group-Object Status | Sort-Object @{ e = { $order[$_.Name] } }
foreach ($g in $counts) {
    $color = switch ($g.Name) {
        'OK' { 'DarkGray' }
        'SKIPPED_SIDE' { 'DarkGray' }
        'CONTENT_DIFFERS' { 'Red' }
        'MISSING_FROM_INSTANCE' { 'Yellow' }
        'EXTRA_IN_INSTANCE' { 'Yellow' }
        'RENAMED_ONLY' { 'DarkYellow' }
        default { 'Cyan' }
    }
    Write-Host ("  {0,-22} {1,4}" -f $g.Name, $g.Count) -ForegroundColor $color
}

foreach ($status in @('CONTENT_DIFFERS', 'MISSING_FROM_INSTANCE', 'EXTRA_IN_INSTANCE', 'VERSION_DIFFERS', 'RENAMED_ONLY')) {
    $sel = @($rows | Where-Object { $_.Status -eq $status })
    if (-not $sel) { continue }
    Write-Host ''
    Write-Host "  $status" -ForegroundColor Cyan
    foreach ($r in ($sel | Sort-Object Mod)) {
        $detail = if ($r.Status -in @('VERSION_DIFFERS', 'RENAMED_ONLY')) { "$($r.Expected)  ->  $($r.InInstance)" }
                  elseif ($r.Status -eq 'EXTRA_IN_INSTANCE') { $r.InInstance }
                  else { $r.Expected }
        Write-Host ("    {0}" -f $detail) -ForegroundColor Gray
    }
}

Write-Host ''
Write-Host "  wrote $OutputCsv" -ForegroundColor DarkGray

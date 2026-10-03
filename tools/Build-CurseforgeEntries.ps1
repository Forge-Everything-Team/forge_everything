<#
.SYNOPSIS
    Produces packwiz metadata:curseforge entries for jars that Resolve-InstanceByHash
    could not resolve, using ZERO CurseForge API calls.

.DESCRIPTION
    When the CurseForge API is unavailable (revoked key, IP-level rate limiting,
    Cloudflare block) Phase 2 of the resolver cannot run. But a packwiz
    metadata:curseforge entry needs only five facts, and three of them are
    already on disk:

        filename      <- the local jar
        hash (sha1)   <- mod-folder-inventory.csv / hash-resolution-report.csv
        side          <- preserved from an existing .pw.toml, else "both"
        project-id    <- MISSING (CurseForge mod page sidebar)
        file-id       <- MISSING (the number in the file page URL)

    So the task reduces to a two-column lookup, not a pipeline. This script
    narrows that lookup as far as it can automatically and leaves you a
    worksheet to finish by hand.

    PASS 1 (default) - build the worksheet:
      * reads UNMATCHED rows from the resolver's report
      * opens each jar and reads META-INF/neoforge.mods.toml (or mods.toml, or
        fabric.mod.json) for modId, version, displayName, displayURL and
        issueTrackerURL. Authors very often point displayURL straight at their
        CurseForge page, which hands you the slug for free.
      * cross-references your existing links_to_mods.txt: any CurseForge link
        already in there gives BOTH a slug and a file-id with no lookup at all
      * emits <WorksheetCsv> with ProjectId/FileId prefilled where known and
        blank where you need to look them up, plus a ready-to-click URL

    PASS 2 (-Apply) - consume the completed worksheet:
      * writes one .pw.toml per row that has both ProjectId and FileId
      * skips incomplete rows and reports them
      * still zero API calls

    IMPORTANT - do NOT solve this by committing third-party jars into the pack
    repo. packwiz will happily index and distribute any loose file, but most
    CurseForge mods do not license redistribution. metadata:curseforge exists
    precisely so the client fetches from CurseForge itself.

    CONFIGURATION
    Every path below can be set once in secrets.local.env:

        MODPACK_ROOT=C:\Users\Terra\projects\Minecraft Modpacks\forge_everything
        PACK_DIR=${MODPACK_ROOT}\packwiz
        INSTANCE_ROOT=C:\Users\Terra\AppData\Roaming\ModrinthApp\profiles\NeoForge 1.21.1
        OUTPUT_DIR=${MODPACK_ROOT}\reports
        LINKS_FILE=${MODPACK_ROOT}\links_to_mods.txt

    RESOLUTION_REPORT_CSV and CURSEFORGE_WORKSHEET_CSV override the OUTPUT_DIR
    defaults individually if you need them somewhere else. The report key is
    shared with Resolve-InstanceByHash.ps1 on purpose, so the file this script
    reads is by construction the file the resolver wrote.

.PARAMETER SecretsFile
    Path to the settings file. Defaults to $env:FORGE_EVERYTHING_SECRETS, else
    secrets.local.env beside this script.

.EXAMPLE
    # Report, links file and mods folder all from secrets.local.env
    .\Build-CurseforgeEntries.ps1

.EXAMPLE
    .\Build-CurseforgeEntries.ps1 -ReportCsv .\hash-resolution-report.csv `
        -LinksFile .\links_to_mods.txt `
        -InstanceModsFolder "C:\Users\Terra\AppData\Roaming\ModrinthApp\profiles\NeoForge 1.21.1\mods"

.EXAMPLE
    .\Build-CurseforgeEntries.ps1 -Apply `
        -PackDir "C:\Users\Terra\projects\Minecraft Modpacks\forge_everything\packwiz"
#>

param(
    [string]$ReportCsv = ".\hash-resolution-report.csv",
    [string]$LinksFile = ".\links_to_mods.txt",
    [string]$InstanceModsFolder,
    [string]$WorksheetCsv = ".\curseforge-worksheet.csv",

    [switch]$Apply,
    [string]$PackDir,

    [string]$SecretsFile
)

# ============================ Configuration ============================
$PackConfigPath = Join-Path $PSScriptRoot "PackConfig.ps1"
if (-not (Test-Path -LiteralPath $PackConfigPath)) {
    Write-Error "PackConfig.ps1 was not found at $PackConfigPath. It ships alongside this script and is required; without it, settings in secrets.local.env would be ignored silently."
    exit 1
}
. $PackConfigPath
Initialize-PackConfig -SecretsFile $SecretsFile -ScriptRoot $PSScriptRoot

if (-not $PSBoundParameters.ContainsKey('ReportCsv')) {
    $ReportCsv = Get-PackOutputPath -Name RESOLUTION_REPORT_CSV -DefaultFileName "hash-resolution-report.csv" -Default $ReportCsv
}
if (-not $PSBoundParameters.ContainsKey('WorksheetCsv')) {
    $WorksheetCsv = Get-PackOutputPath -Name CURSEFORGE_WORKSHEET_CSV -DefaultFileName "curseforge-worksheet.csv" -Default $WorksheetCsv
}
if (-not $PSBoundParameters.ContainsKey('LinksFile')) {
    $LinksFile = Get-PackSetting -Name LINKS_FILE -AsPath -Default $LinksFile
}
if (-not $PSBoundParameters.ContainsKey('InstanceModsFolder')) {
    $InstanceModsFolder = Get-PackFolderSetting -Name INSTANCE_MODS_FOLDER -ParentName INSTANCE_ROOT -ChildFolder "mods" -Default $InstanceModsFolder
}
if (-not $PSBoundParameters.ContainsKey('PackDir')) {
    $PackDir = Get-PackSetting -Name PACK_DIR -AsPath -Default $PackDir
}

Show-PackConfigSummary -Values @{
    ReportCsv          = $ReportCsv
    WorksheetCsv       = $WorksheetCsv
    LinksFile          = $LinksFile
    InstanceModsFolder = $InstanceModsFolder
    PackDir            = $PackDir
}

Add-Type -AssemblyName System.IO.Compression.FileSystem

function Write-TextFile {
    param([string]$Path, [string]$Text)
    $full = if ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    } else {
        [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
    }
    [System.IO.File]::WriteAllText($full, $Text, (New-Object System.Text.UTF8Encoding($false)))
    return $full
}

# ============================ Jar metadata ============================
# Read the loader manifest out of the jar. This is free, offline, and far more
# reliable than guessing a slug from the filename - filenames are decorated with
# loader/MC-version noise, manifests are authored.
function Get-JarMetadata {
    param([string]$JarPath)

    $result = [PSCustomObject]@{
        ModId = ""; ModVersion = ""; DisplayName = ""; Urls = @()
    }
    $zip = $null
    try { $zip = [System.IO.Compression.ZipFile]::OpenRead($JarPath) }
    catch { return $result }

    try {
        $wanted = @("META-INF/neoforge.mods.toml", "META-INF/mods.toml", "fabric.mod.json")
        foreach ($w in $wanted) {
            $entry = $zip.Entries | Where-Object { $_.FullName -eq $w } | Select-Object -First 1
            if (-not $entry) { continue }

            $reader = New-Object System.IO.StreamReader($entry.Open())
            $text = $reader.ReadToEnd()
            $reader.Dispose()

            if ($w -eq "fabric.mod.json") {
                try {
                    $j = $text | ConvertFrom-Json
                    $result.ModId = "$($j.id)"
                    $result.ModVersion = "$($j.version)"
                    $result.DisplayName = "$($j.name)"
                    $urls = @()
                    if ($j.contact) { foreach ($p in $j.contact.PSObject.Properties) { $urls += "$($p.Value)" } }
                    $result.Urls = $urls
                } catch { }
            }
            else {
                # Deliberately regex, not a TOML parser: we want five scalar
                # fields out of a file whose full grammar we do not care about.
                $m = [regex]::Match($text, '(?m)^\s*modId\s*=\s*"([^"]+)"')
                if ($m.Success) { $result.ModId = $m.Groups[1].Value }
                $m = [regex]::Match($text, '(?m)^\s*version\s*=\s*"([^"]+)"')
                if ($m.Success) { $result.ModVersion = $m.Groups[1].Value }
                $m = [regex]::Match($text, '(?m)^\s*displayName\s*=\s*"([^"]+)"')
                if ($m.Success) { $result.DisplayName = $m.Groups[1].Value }
                $urls = @()
                foreach ($k in @("displayURL", "issueTrackerURL", "updateJSONURL")) {
                    foreach ($um in [regex]::Matches($text, "(?m)^\s*$k\s*=\s*`"([^`"]+)`"")) {
                        $urls += $um.Groups[1].Value
                    }
                }
                $result.Urls = $urls
            }
            break
        }
    }
    finally { if ($zip) { $zip.Dispose() } }
    return $result
}

function Get-SlugFromUrls {
    param([string[]]$Urls)
    foreach ($u in $Urls) {
        $m = [regex]::Match($u, 'curseforge\.com/minecraft/mc-mods/([^/?#]+)')
        if ($m.Success) { return $m.Groups[1].Value }
    }
    return ""
}

# ================================ Apply ================================
function Get-EntryName {
    # Metadata filename priority. packwiz does not care what this is called,
    # but you do: these sit alongside 400+ slug-named Modrinth entries, and
    # "cf-384991.pw.toml" is unreadable in a diff. Fall back through the
    # sources most likely to yield a human-meaningful, stable name.
    param($Row)
    $s = "$($Row.Slug)".Trim()
    if ($s) { return $s }
    $m = [regex]::Match("$($Row.LookupUrl)", 'curseforge\.com/minecraft/mc-mods/([^/?#]+)')
    if ($m.Success -and $m.Groups[1].Value -ne 'search') { return $m.Groups[1].Value }
    $mid = "$($Row.ModId)".Trim()
    if ($mid) { return $mid }
    return "cf-$("$($Row.ProjectId)".Trim())"
}

if ($Apply) {
    if (-not (Test-Path $WorksheetCsv)) { Write-Error "Worksheet not found: $WorksheetCsv"; exit 1 }
    if (-not ($PackDir -and (Test-Path (Join-Path $PackDir "pack.toml")))) {
        Write-Error "-Apply requires a pack directory containing pack.toml. Pass -PackDir, or set PACK_DIR in $(Resolve-PackSecretsFile -SecretsFile $SecretsFile). Current value: $(if ($PackDir) { $PackDir } else { '<not set>' })"
        exit 1
    }

    # Blank trailing rows are normal when a spreadsheet round-trips a CSV.
    $rows = @(Import-Csv -Path $WorksheetCsv | Where-Object { "$($_.FileName)".Trim() })
    Write-Host "Worksheet rows with data: $($rows.Count)" -ForegroundColor Cyan

    # ---- Preflight. Validate everything BEFORE writing anything. A partial
    # ---- write across hundreds of pack files is far worse than a clean stop.
    $errors = New-Object System.Collections.Generic.List[string]
    $nameSeen = @{}
    foreach ($r in $rows) {
        $fn = "$($r.FileName)".Trim()
        $pid = "$($r.ProjectId)".Trim()
        $fid = "$($r.FileId)".Trim()
        $sha = "$($r.Sha1)".Trim()

        if ($pid -notmatch '^\d+$')  { $errors.Add("$fn : ProjectId '$pid' is not numeric") }
        if ($fid -notmatch '^\d+$')  { $errors.Add("$fn : FileId '$fid' is not numeric") }
        if ($sha -notmatch '^[0-9a-fA-F]{40}$') { $errors.Add("$fn : Sha1 '$sha' is not a 40-char hex digest") }

        $nm = Get-EntryName -Row $r
        if ($nameSeen.ContainsKey($nm)) {
            $errors.Add("$fn : output name '$nm.pw.toml' collides with $($nameSeen[$nm])")
        } else { $nameSeen[$nm] = $fn }

        if ($fn -match 'everything(ores|food|bugs)') {
            $errors.Add("$fn : this looks like your own dev jar - it is not on CurseForge, delete the row")
        }
    }
    if ($errors.Count -gt 0) {
        Write-Host "`nPreflight FAILED - nothing was written." -ForegroundColor Red
        foreach ($e in $errors) { Write-Host "  $e" -ForegroundColor Yellow }
        exit 1
    }
    Write-Host "Preflight passed: ids numeric, hashes well-formed, no name collisions." -ForegroundColor Green

    $modsDir = Join-Path $PackDir "mods"
    if (-not (Test-Path $modsDir)) { New-Item -ItemType Directory -Path $modsDir | Out-Null }

    $written = 0; $overwritten = 0
    foreach ($r in $rows) {
        $nm = Get-EntryName -Row $r
        $name = if ("$($r.DisplayName)".Trim()) { "$($r.DisplayName)".Trim() } else { $nm }
        $tomlPath = Join-Path $modsDir "$nm.pw.toml"

        # Preserve 'side' if an entry already exists - same convention as the
        # resolver and Process-ModList.
        $side = "both"
        if (Test-Path $tomlPath) {
            $overwritten++
            $m = [regex]::Match((Get-Content -Path $tomlPath -Raw), '(?m)^\s*side\s*=\s*"([^"]*)"')
            if ($m.Success) { $side = $m.Groups[1].Value }
        }

        $safeName = $name -replace '"', '\"'
        $content = @"
name = "$safeName"
filename = "$("$($r.FileName)".Trim())"
side = "$side"

[download]
hash-format = "sha1"
hash = "$("$($r.Sha1)".Trim().ToLower())"
mode = "metadata:curseforge"

[update]
[update.curseforge]
file-id = $("$($r.FileId)".Trim())
project-id = $("$($r.ProjectId)".Trim())
"@
        Write-TextFile -Path $tomlPath -Text $content | Out-Null
        Write-Host "  $nm -> $($r.FileName)" -ForegroundColor DarkGray
        $written++
    }

    Write-Host "`nWrote $written entry/entries ($overwritten replaced an existing file)." -ForegroundColor Green
    Write-Host "`nNow run: packwiz refresh" -ForegroundColor Cyan
    Write-Host "packwiz verifies each file against the sha1 above when it downloads," -ForegroundColor Cyan
    Write-Host "so a wrong file-id fails loudly rather than silently shipping the wrong build." -ForegroundColor Cyan
    exit 0
}

# ============================ Build worksheet ============================
if (-not (Test-Path $ReportCsv)) { Write-Error "Report not found: $ReportCsv (run Resolve-InstanceByHash.ps1 first)"; exit 1 }

$unmatched = @(Import-Csv -Path $ReportCsv | Where-Object { $_.Status -eq "UNMATCHED" })
Write-Host "Unmatched jars in report: $($unmatched.Count)" -ForegroundColor Cyan

# Known CurseForge links from the hand-collected file: slug -> fileId.
$linkFileIdBySlug = @{}
if ($LinksFile -and (Test-Path $LinksFile)) {
    foreach ($raw in Get-Content -Path $LinksFile) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $m = [regex]::Match($line, 'curseforge\.com/minecraft/mc-mods/([^/]+)/files/(\d+)')
        if ($m.Success) { $linkFileIdBySlug[$m.Groups[1].Value] = $m.Groups[2].Value }
    }
    Write-Host "CurseForge links available in $LinksFile : $($linkFileIdBySlug.Count)" -ForegroundColor Cyan
}

$rows = New-Object System.Collections.Generic.List[object]
$fromManifest = 0; $fromLinks = 0; $noLead = 0

foreach ($u in $unmatched) {
    $jar = ""
    if ($InstanceModsFolder) {
        $cand = Join-Path $InstanceModsFolder $u.FileName
        if (Test-Path -LiteralPath $cand) { $jar = $cand }
    }

    $meta = if ($jar) { Get-JarMetadata -JarPath $jar } else {
        [PSCustomObject]@{ ModId = ""; ModVersion = ""; DisplayName = ""; Urls = @() }
    }

    $slug = Get-SlugFromUrls -Urls $meta.Urls
    if ($slug) { $fromManifest++ }

    $fileId = ""
    if ($slug -and $linkFileIdBySlug.ContainsKey($slug)) { $fileId = $linkFileIdBySlug[$slug]; $fromLinks++ }

    $lookupUrl = if ($slug) {
        "https://www.curseforge.com/minecraft/mc-mods/$slug/files/all?page=1&pageSize=20"
    } elseif ($meta.DisplayName) {
        "https://www.curseforge.com/minecraft/search?class=mc-mods&search=" + [uri]::EscapeDataString($meta.DisplayName)
    } else {
        "https://www.curseforge.com/minecraft/search?class=mc-mods&search=" + [uri]::EscapeDataString($u.FileName)
    }
    if (-not $slug) { $noLead++ }

    $rows.Add([PSCustomObject]@{
        FileName    = $u.FileName
        ModId       = $meta.ModId
        ModVersion  = $meta.ModVersion
        DisplayName = $meta.DisplayName
        Slug        = $slug
        ProjectId   = ""        # <- fill in: sidebar of the mod page
        FileId      = $fileId   # <- fill in: number in the file page URL
        Sha1        = $u.Sha1
        LookupUrl   = $lookupUrl
    })
}

$rows | Export-Csv -Path $WorksheetCsv -NoTypeInformation

Write-Host "`n--- Worksheet ---" -ForegroundColor Cyan
Write-Host "  rows                        : $($rows.Count)"
Write-Host "  slug recovered from jar     : $fromManifest"
Write-Host "  file-id recovered from links: $fromLinks"
Write-Host "  no lead at all              : $noLead"
Write-Host "`nWorksheet: $WorksheetCsv" -ForegroundColor Green
Write-Host @"

Next:
  1. Open the worksheet. Rows with a Slug already have a direct LookupUrl.
  2. For each row, fill ProjectId (mod page sidebar) and FileId (number in the
     file page URL). Rows that are your own dev jars - everythingores,
     everythingfood, everythingbugs - should be DELETED, not filled: they are
     not on CurseForge and belong in the pack by another route.
  3. Re-run with -Apply -PackDir <packwiz dir>, then packwiz refresh.

Because every entry carries the sha1 of the jar you actually have installed,
packwiz verifies your file-id guess on first download. A wrong id fails the
hash check instead of quietly shipping a different build.
"@ -ForegroundColor Cyan

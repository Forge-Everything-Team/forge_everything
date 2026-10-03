<#
.SYNOPSIS
    Gets the exact filename/URL/hash for a specific mod version (Modrinth or
    CurseForge) and, optionally, writes/updates the corresponding .pw.toml
    directly in your packwiz pack.

.DESCRIPTION
    Three lookup modes:

    -ModrinthUrl <version page URL>
        Modrinth's API is public - no key required, though -ApiToken raises
        your rate limit if supplied. Handles both URL styles Modrinth allows
        (opaque version ID, or human-readable version number) automatically.

    -CurseForgeUrl <file page URL>
        Requires -CfApiKey. Resolves the mod's numeric ID from its slug, then
        fetches the specific file's metadata, hash, and download URL.

    -LocalFile <path to a downloaded jar>
        Hashes a file you've already downloaded by hand. Read-only - since
        there's no project/version metadata attached, this mode only prints
        a snippet, it can't -Apply.

    By default all modes just PRINT the info (safe to dry-run and eyeball).
    Add -Apply -PackDir <path to pack.toml's folder> to have it actually
    write the .pw.toml:
      - If a .pw.toml for this same mod already exists anywhere in the pack
        (matched by Modrinth mod-id or CurseForge project-id, not filename),
        it's UPDATED in place - the existing 'side' setting is preserved,
        everything else is overwritten with the correct values.
      - If no existing entry is found, a new .pw.toml is created under
        <PackDir>\mods\. Note: the exact filename packwiz itself would have
        chosen may differ slightly - that's cosmetic only, `packwiz refresh`
        will pick up whatever's there regardless of its filename.

.EXAMPLE
    .\Get-VersionHashInfo.ps1 -ModrinthUrl "https://modrinth.com/mod/jei/version/eBag7ypX" -Apply -PackDir ".\packwiz"

.EXAMPLE
    .\Get-VersionHashInfo.ps1 -CurseForgeUrl "https://www.curseforge.com/minecraft/mc-mods/additional-lights/files/6841545" -CfApiKey $env:CF_API_KEY -Apply -PackDir ".\packwiz"

.EXAMPLE
    .\Get-VersionHashInfo.ps1 -LocalFile "C:\Users\Terra\Downloads\somemod-1.2.3.jar"
#>

param(
    [string]$ModrinthUrl,
    [string]$CurseForgeUrl,
    [string]$LocalFile,

    [string]$ApiToken,      # Modrinth PAT, optional
    [string]$CfApiKey,      # CurseForge key, required for -CurseForgeUrl

    [switch]$Apply,
    [string]$PackDir,

    [string]$SecretsFile = (Join-Path $PSScriptRoot "secrets.local.env")
)

# PowerShell 5.1 doesn't always default to TLS 1.2 on older Windows - CurseForge's
# Cloudflare front-end silently 403s anything that doesn't negotiate it.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- Load secrets from file if present (never committed to git - see note below) ---
# Format: one KEY=VALUE per line, e.g.:
#   CF_API_KEY=$2a$10$....
#   MODRINTH_TOKEN=mr_....
# Lines starting with # are ignored. Values are trimmed of whitespace and any
# accidental wrapping quotes, since a stray character here is exactly what's been
# causing the "missing or invalid" errors.
$secrets = @{}
if (Test-Path $SecretsFile) {
    Write-Host "Loading secrets from $SecretsFile" -ForegroundColor DarkGray
    foreach ($line in Get-Content -Path $SecretsFile) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { continue }
        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim().Trim('"').Trim("'")
        $secrets[$key] = $val
    }
}

# Resolution order: explicit parameter > environment variable > secrets file
if (-not $CfApiKey) { $CfApiKey = $env:CF_API_KEY }
if (-not $CfApiKey -and $secrets.ContainsKey("CF_API_KEY")) { $CfApiKey = $secrets["CF_API_KEY"] }

if (-not $ApiToken) { $ApiToken = $env:MODRINTH_TOKEN }
if (-not $ApiToken -and $secrets.ContainsKey("MODRINTH_TOKEN")) { $ApiToken = $secrets["MODRINTH_TOKEN"] }

if ($CfApiKey) { Write-Host "CurseForge key loaded (length: $($CfApiKey.Length))" -ForegroundColor DarkGray }

function Get-ErrorResponseBody {
    param($ErrorRecord)

    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) {
        return $ErrorRecord.ErrorDetails.Message
    }

    try {
        $resp = $ErrorRecord.Exception.Response
        if ($resp) {
            $stream = $resp.GetResponseStream()
            $reader = New-Object System.IO.StreamReader($stream)
            return $reader.ReadToEnd()
        }
    }
    catch { }
    return $null
}

function Invoke-ModrinthApi {
    param([string]$Uri)
    $headers = @{ "User-Agent" = "ForgeEverything-HashLookup/1.0 (contact: terra)" }
    if ($ApiToken) { $headers["Authorization"] = $ApiToken }
    return Invoke-RestMethod -Uri $Uri -Headers $headers
}

function Invoke-CurseForgeApi {
    param([string]$Uri)
    $headers = @{
        "x-api-key"    = $CfApiKey
        "Accept"       = "application/json"
        "User-Agent"   = "ForgeEverything-HashLookup/1.0 (contact: terra)"
    }
    return Invoke-RestMethod -Uri $Uri -Headers $headers
}

function Show-TomlSnippet {
    param($Filename, $Url, $Hash, $HashFormat)

    Write-Host "`n--- [download] block ---" -ForegroundColor Cyan
    Write-Host "filename = `"$Filename`""
    Write-Host "[download]"
    Write-Host "url = `"$Url`""
    Write-Host "hash-format = `"$HashFormat`""
    Write-Host "hash = `"$Hash`""
}

function Get-ExistingTomlPath {
    param([string]$PackDir, [string]$Source, [string]$ModrinthModId, [string]$CfProjectId)

    $tomlFiles = Get-ChildItem -Path $PackDir -Filter "*.pw.toml" -Recurse -File -ErrorAction SilentlyContinue
    foreach ($f in $tomlFiles) {
        $text = Get-Content -Path $f.FullName -Raw
        if ($Source -eq "modrinth" -and $ModrinthModId) {
            if ($text -match "(?m)^\s*mod-id\s*=\s*`"$([regex]::Escape($ModrinthModId))`"") { return $f.FullName }
        }
        if ($Source -eq "curseforge" -and $CfProjectId) {
            if ($text -match "(?m)^\s*project-id\s*=\s*$CfProjectId\s*$") { return $f.FullName }
        }
    }
    return $null
}

function Get-ExistingSide {
    param([string]$TomlPath)
    if (-not $TomlPath -or -not (Test-Path $TomlPath)) { return "both" }
    $text = Get-Content -Path $TomlPath -Raw
    $m = [regex]::Match($text, '(?m)^\s*side\s*=\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return "both"
}

function Set-PwTomlEntry {
    param(
        [string]$PackDir, [string]$Source, [string]$Name, [string]$Filename,
        [string]$Url, [string]$Hash, [string]$HashFormat, [string]$ProjectSlug,
        [string]$ModrinthModId, [string]$ModrinthVersion,
        [string]$CfProjectId, [string]$CfFileId
    )

    if (-not $Hash) {
        Write-Host "Refusing to write - no hash available for this file. See warnings above." -ForegroundColor Red
        return
    }

    $existingPath = Get-ExistingTomlPath -PackDir $PackDir -Source $Source -ModrinthModId $ModrinthModId -CfProjectId $CfProjectId
    $side = Get-ExistingSide -TomlPath $existingPath
    $safeName = $Name -replace '"', '\"'

    $updateBlock = if ($Source -eq "modrinth") {
        "[update.modrinth]`nmod-id = `"$ModrinthModId`"`nversion = `"$ModrinthVersion`""
    } else {
        "[update.curseforge]`nfile-id = $CfFileId`nproject-id = $CfProjectId"
    }

    $content = @"
name = "$safeName"
filename = "$Filename"
side = "$side"

[download]
url = "$Url"
hash-format = "$HashFormat"
hash = "$Hash"

[update]
$updateBlock
"@

    if ($existingPath) {
        Write-Host "Updating existing toml: $existingPath" -ForegroundColor Green
        Set-Content -Path $existingPath -Value $content -NoNewline
    }
    else {
        $modsDir = Join-Path $PackDir "mods"
        if (-not (Test-Path $modsDir)) { New-Item -ItemType Directory -Path $modsDir | Out-Null }
        $newPath = Join-Path $modsDir "$ProjectSlug.pw.toml"
        Write-Host "No existing entry found for this mod - creating new: $newPath" -ForegroundColor Yellow
        Write-Host "(packwiz's own auto-generated filename may differ slightly - cosmetic only)" -ForegroundColor Yellow
        Set-Content -Path $newPath -Value $content -NoNewline
    }
}

# ============================== Modrinth ==============================
if ($ModrinthUrl) {
    if ($ModrinthUrl -notmatch '/mod/([^/]+)/version/([^/?]+)') {
        Write-Error "Couldn't parse that URL - expected .../mod/<slug>/version/<id-or-version-number>"
        exit 1
    }
    $slug = $Matches[1]
    $versionSegment = $Matches[2]
    $resp = $null

    try {
        Write-Host "Querying Modrinth API for version '$versionSegment' ..." -ForegroundColor Cyan
        $resp = Invoke-ModrinthApi -Uri "https://api.modrinth.com/v2/version/$versionSegment"
    }
    catch {
        Write-Host "Not a valid version ID - this URL uses the version NUMBER. Looking it up via the project's version list..." -ForegroundColor Yellow
    }

    if (-not $resp) {
        try {
            $allVersions = Invoke-ModrinthApi -Uri "https://api.modrinth.com/v2/project/$slug/version"
        }
        catch {
            Write-Error "Could not list versions for project '$slug': $($_.Exception.Message)"
            exit 1
        }
        $resp = $allVersions | Where-Object { $_.version_number -eq $versionSegment } | Select-Object -First 1
        if (-not $resp) {
            Write-Error "No version on project '$slug' has version_number '$versionSegment'."
            exit 1
        }
    }

    $primaryFile = $resp.files | Where-Object { $_.primary } | Select-Object -First 1
    if (-not $primaryFile) { $primaryFile = $resp.files | Select-Object -First 1 }
    if (-not $primaryFile) { Write-Error "No files found on this version."; exit 1 }

    $projectTitle = $slug
    try {
        $projectResp = Invoke-ModrinthApi -Uri "https://api.modrinth.com/v2/project/$slug"
        if ($projectResp.title) { $projectTitle = $projectResp.title }
    }
    catch { }

    Write-Host "Version: $($resp.version_number)   Game versions: $($resp.game_versions -join ', ')   Loaders: $($resp.loaders -join ', ')" -ForegroundColor Green
    Show-TomlSnippet -Filename $primaryFile.filename -Url $primaryFile.url -Hash $primaryFile.hashes.sha1 -HashFormat "sha1"
    Write-Host "`n[update.modrinth]`nmod-id = `"$($resp.project_id)`"`nversion = `"$($resp.id)`"" -ForegroundColor Cyan

    if ($Apply) {
        if (-not $PackDir) { Write-Error "-Apply requires -PackDir"; exit 1 }
        Set-PwTomlEntry -PackDir $PackDir -Source "modrinth" -Name $projectTitle -Filename $primaryFile.filename `
            -Url $primaryFile.url -Hash $primaryFile.hashes.sha1 -HashFormat "sha1" -ProjectSlug $slug `
            -ModrinthModId $resp.project_id -ModrinthVersion $resp.id
    }
    return
}

# ============================== CurseForge ==============================
if ($CurseForgeUrl) {
    if (-not $CfApiKey) { Write-Error "-CurseForgeUrl requires -CfApiKey"; exit 1 }
    if ($CurseForgeUrl -notmatch '/mc-mods/([^/]+)/files/(\d+)') {
        Write-Error "Couldn't parse that URL - expected .../mc-mods/<slug>/files/<fileId>"
        exit 1
    }
    $cfSlug = $Matches[1]
    $fileId = $Matches[2]

    Write-Host "Looking up CurseForge mod ID for slug '$cfSlug' ..." -ForegroundColor Cyan
    try {
        $searchResp = Invoke-CurseForgeApi -Uri "https://api.curseforge.com/v1/mods/search?gameId=432&classId=6&slug=$cfSlug"
    }
    catch {
        $body = Get-ErrorResponseBody -ErrorRecord $_
        Write-Error "Search request failed: $($_.Exception.Message)$(if ($body) { "`nResponse body: $body" })"
        exit 1
    }
    if (-not $searchResp.data -or $searchResp.data.Count -eq 0) {
        Write-Error "No CurseForge mod found for slug '$cfSlug'"
        exit 1
    }
    $modId = $searchResp.data[0].id
    $modName = $searchResp.data[0].name

    Write-Host "Fetching file $fileId for mod $modId ($modName) ..." -ForegroundColor Cyan
    try {
        $fileResp = Invoke-CurseForgeApi -Uri "https://api.curseforge.com/v1/mods/$modId/files/$fileId"
    }
    catch {
        $body = Get-ErrorResponseBody -ErrorRecord $_
        Write-Error "File lookup failed: $($_.Exception.Message)$(if ($body) { "`nResponse body: $body" })"
        exit 1
    }
    $file = $fileResp.data
    if (-not $file) { Write-Error "No file data returned."; exit 1 }

    $sha1Hash = ($file.hashes | Where-Object { $_.algo -eq 1 } | Select-Object -First 1).value

    if (-not $file.downloadUrl) {
        Write-Host "WARNING: this mod's author has disabled third-party downloads via the API - downloadUrl is empty." -ForegroundColor Red
        Write-Host "Download it manually from the CurseForge site instead, then use -LocalFile for the hash." -ForegroundColor Red
    }
    if (-not $sha1Hash) {
        $available = ($file.hashes | ForEach-Object { "algo$($_.algo)=$($_.value)" }) -join ', '
        Write-Host "WARNING: no SHA1 returned for this file. Available hashes: $available" -ForegroundColor Yellow
        Write-Host "packwiz normally wants sha1 - if this stays blank, fall back to -LocalFile after a manual download." -ForegroundColor Yellow
    }

    Write-Host "File: $($file.fileName)   Game versions: $($file.gameVersions -join ', ')" -ForegroundColor Green
    Show-TomlSnippet -Filename $file.fileName -Url $file.downloadUrl -Hash $sha1Hash -HashFormat "sha1"
    Write-Host "`n[update.curseforge]`nfile-id = $fileId`nproject-id = $modId" -ForegroundColor Cyan

    if ($Apply) {
        if (-not $PackDir) { Write-Error "-Apply requires -PackDir"; exit 1 }
        Set-PwTomlEntry -PackDir $PackDir -Source "curseforge" -Name $modName -Filename $file.fileName `
            -Url $file.downloadUrl -Hash $sha1Hash -HashFormat "sha1" -ProjectSlug $cfSlug `
            -CfProjectId $modId -CfFileId $fileId
    }
    return
}

# ============================== Local file (read-only) ==============================
if ($LocalFile) {
    if (-not (Test-Path $LocalFile)) { Write-Error "File not found: $LocalFile"; exit 1 }

    $sha1 = (Get-FileHash -Path $LocalFile -Algorithm SHA1).Hash.ToLower()
    $filename = Split-Path -Leaf $LocalFile

    Write-Host "Hashed local file: $filename" -ForegroundColor Green
    Show-TomlSnippet -Filename $filename -Url "<the CDN download URL for this exact file>" -Hash $sha1 -HashFormat "sha1"
    Write-Host "`nThis mode is read-only (no project/version metadata attached) - can't -Apply." -ForegroundColor Yellow
    Write-Host "Paste manually, updating [update.modrinth] version or [update.curseforge] file-id yourself." -ForegroundColor Yellow
    return
}

Write-Error "Specify -ModrinthUrl, -CurseForgeUrl, or -LocalFile"

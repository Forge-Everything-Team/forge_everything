<#
.SYNOPSIS
    Processes every entry in links_to_mods.txt through the Modrinth/CurseForge APIs
    to get the ground-truth filename + hash for each, then cross-references that
    filename directly against the modpack instance's actual folders - covering
    mods, datapacks, resourcepacks, shaders, and plugins.

.DESCRIPTION
    This replaces the earlier filename/modId-heuristic verification approach.
    Since every URL in the fully-resolved links file points at ONE specific
    version/file, the API tells us exactly what filename and hash that version
    is supposed to have - no guessing needed. This script:

      1. Parses links_to_mods.txt (sections: Modrinth / Curseforge / FTB Mods)
      2. For each resolved URL, queries the matching API for the real filename,
         download URL, and SHA1 hash of that exact version - Modrinth URLs of
         any project type (mod, datapack, resourcepack, shader, plugin) are
         detected automatically from the URL path
      3. Checks the RIGHT instance folder for that type for a file with that
         EXACT filename (mods/plugins are matched as .jar, resourcepacks/
         shaderpacks/datapacks as .zip)
      4. If found, hashes it and compares against the API's hash
      5. Logs a clear per-mod status, and (optionally) writes/updates the
         corresponding .pw.toml in the correct packwiz subfolder for that type
         (mods/, resourcepacks/, shaderpacks/, datapacks/, plugins/), with a
         sensible default 'side' per type (resourcepacks/shaders default to
         client, datapacks/plugins default to server, mods stay both) - an
         existing entry's side is always preserved regardless.

    CurseForge resolution currently only covers mc-mods (classId 6) - CurseForge
    resourcepacks/worlds use different URL paths and classIds this script
    doesn't handle yet, so those would need to be added separately if needed.

    Statuses:
      OK                        - exact filename found locally, hash matches
      HASH_MISMATCH              - exact filename found locally, content differs
      MISSING_FROM_INSTANCE      - a folder IS configured for this type, but no
                                    file with that filename exists in it
      NO_LOCAL_FOLDER_CONFIGURED - this type's -Instance...Folder parameter
                                    wasn't supplied, so no local check was
                                    possible (the API lookup itself still ran,
                                    and -Apply will still write the toml)
      LOOKUP_FAILED              - the API call itself failed (bad key, 403,
                                    deleted project, etc.) - see the Notes column

    A note on datapacks specifically: this only detects datapacks distributed as
    a single .zip file (e.g. dropped into a datapack-loader mod's designated
    folder). A datapack sitting loose as an unzipped folder inside a world's
    datapacks/ directory won't be picked up by this file-based scan.

    Rate-limited with backoff on 429s. Continues past individual failures
    (e.g. a CurseForge key issue) rather than aborting the whole run.

.PARAMETER LinksFile
    Path to the fully-resolved links_to_mods.txt

.PARAMETER InstanceModsFolder
    Path to the actual jar files, e.g.
    "C:\Users\Terra\AppData\Roaming\ModrinthApp\profiles\forge everything\mods"

.PARAMETER InstanceResourcepacksFolder
    Optional. Path to the instance's resourcepacks folder. If omitted,
    resourcepack entries are still resolved via the API but not checked locally.

.PARAMETER InstanceShaderpacksFolder
    Optional. Path to the instance's shaderpacks folder.

.PARAMETER InstanceDatapacksFolder
    Optional. Path to wherever your datapack-loader mod expects its zips.

.PARAMETER InstancePluginsFolder
    Optional. Path to a plugins folder, if applicable to this pack.

.PARAMETER Apply
    Also write/update the .pw.toml for every successfully-resolved entry.

.PARAMETER PackDir
    Path to the folder containing pack.toml (required with -Apply)

.PARAMETER SecretsFile
    KEY=VALUE file for CF_API_KEY / MODRINTH_TOKEN. Default: secrets.local.env
    next to this script.

.EXAMPLE
    .\Process-ModList.ps1 -LinksFile .\links_to_mods.txt `
        -InstanceModsFolder "C:\...\mods" `
        -InstanceResourcepacksFolder "C:\...\resourcepacks" `
        -InstanceShaderpacksFolder "C:\...\shaderpacks" `
        -InstanceDatapacksFolder "C:\...\datapacks"

.EXAMPLE
    .\Process-ModList.ps1 -LinksFile .\links_to_mods.txt `
        -InstanceModsFolder "C:\...\mods" -Apply -PackDir "C:\...\packwiz"
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$LinksFile,

    [Parameter(Mandatory = $true)]
    [string]$InstanceModsFolder,

    [string]$InventoryCsv,
    [string]$ModpackVersion,

    [string]$InstanceResourcepacksFolder,
    [string]$InstanceShaderpacksFolder,
    [string]$InstanceDatapacksFolder,
    [string]$InstancePluginsFolder,

    [switch]$Apply,
    [string]$PackDir,

    [string]$ApiToken,
    [string]$CfApiKey,
    [string]$SecretsFile = (Join-Path $PSScriptRoot "secrets.local.env"),

    [int]$DelaySeconds = 2,
    [int]$MaxRetries = 5,
    [int]$MaxBackoffSeconds = 60,
    [string]$OutputCsv = ".\mod-list-processing-report.csv"
)

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# --- Secrets (same resolution order as Get-VersionHashInfo.ps1: param > env > file) ---
$secrets = @{}
if (Test-Path $SecretsFile) {
    Write-Host "Loading secrets from $SecretsFile" -ForegroundColor DarkGray
    foreach ($line in Get-Content -Path $SecretsFile) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { continue }
        $secrets[$line.Substring(0, $idx).Trim()] = $line.Substring($idx + 1).Trim().Trim('"').Trim("'")
    }
}
else {
    Write-Host "No secrets file found at $SecretsFile" -ForegroundColor Yellow
}
if (-not $CfApiKey) { $CfApiKey = $env:CF_API_KEY }
if (-not $CfApiKey -and $secrets.ContainsKey("CF_API_KEY")) { $CfApiKey = $secrets["CF_API_KEY"] }
if (-not $ApiToken) { $ApiToken = $env:MODRINTH_TOKEN }
if (-not $ApiToken -and $secrets.ContainsKey("MODRINTH_TOKEN")) { $ApiToken = $secrets["MODRINTH_TOKEN"] }
if (-not $ModpackVersion -and $secrets.ContainsKey("MODPACK_VERSION")) { $ModpackVersion = $secrets["MODPACK_VERSION"] }

if ($CfApiKey) { Write-Host "CurseForge key loaded (length: $($CfApiKey.Length))" -ForegroundColor DarkGray }
else { Write-Host "No CurseForge key found anywhere (param / env / secrets file) - all CurseForge lookups will fail" -ForegroundColor Red }

if (-not (Test-Path $LinksFile)) { Write-Error "Links file not found: $LinksFile"; exit 1 }
if (-not (Test-Path $InstanceModsFolder)) { Write-Error "Instance mods folder not found: $InstanceModsFolder"; exit 1 }
if ($Apply -and -not (Test-Path (Join-Path $PackDir "pack.toml"))) { Write-Error "-Apply requires a valid -PackDir (no pack.toml found)"; exit 1 }

# ============================== Helpers ==============================
function Invoke-ModrinthApi {
    param([string]$Uri)
    $headers = @{ "User-Agent" = "ForgeEverything-BulkProcessor/1.0 (contact: terra)" }
    if ($ApiToken) { $headers["Authorization"] = $ApiToken }
    return Invoke-RestMethod -Uri $Uri -Headers $headers
}

function Invoke-CurseForgeApi {
    param([string]$Uri)
    $headers = @{ "x-api-key" = $CfApiKey; "Accept" = "application/json"; "User-Agent" = "ForgeEverything-BulkProcessor/1.0 (contact: terra)" }
    return Invoke-RestMethod -Uri $Uri -Headers $headers
}

function Get-ErrorInfo {
    param($ErrorRecord)
    $body = $null
    if ($ErrorRecord.ErrorDetails -and $ErrorRecord.ErrorDetails.Message) { $body = $ErrorRecord.ErrorDetails.Message }
    $isRateLimit = ($ErrorRecord.Exception.Message -match '429') -or ($body -match '429')
    [PSCustomObject]@{ Message = "$($ErrorRecord.Exception.Message) $body".Trim(); IsRateLimit = $isRateLimit }
}

function Resolve-ModrinthEntry {
    param([string]$Url)
    if ($Url -notmatch '/(mod|datapack|resourcepack|shader|plugin)/([^/]+)/version/([^/?]+)') { return $null }
    $type = $Matches[1]; $slug = $Matches[2]; $versionSegment = $Matches[3]
    $resp = $null
    try { $resp = Invoke-ModrinthApi -Uri "https://api.modrinth.com/v2/version/$versionSegment" } catch { }
    if (-not $resp) {
        $allVersions = Invoke-ModrinthApi -Uri "https://api.modrinth.com/v2/project/$slug/version"
        $resp = $allVersions | Where-Object { $_.version_number -eq $versionSegment } | Select-Object -First 1
        if (-not $resp) { throw "No version on '$slug' matches '$versionSegment'" }
    }
    $file = $resp.files | Where-Object { $_.primary } | Select-Object -First 1
    if (-not $file) { $file = $resp.files | Select-Object -First 1 }
    if (-not $file) { throw "No files on this version" }

    $title = $slug
    try { $p = Invoke-ModrinthApi -Uri "https://api.modrinth.com/v2/project/$slug"; if ($p.title) { $title = $p.title } } catch { }

    [PSCustomObject]@{
        Source = "modrinth"; Type = $type; Slug = $slug; Name = $title
        Filename = $file.filename; DownloadUrl = $file.url; Hash = $file.hashes.sha1
        ModrinthModId = $resp.project_id; ModrinthVersion = $resp.id
        CfProjectId = $null; CfFileId = $null
    }
}

function Resolve-CurseForgeEntry {
    param([string]$Url)
    if (-not $CfApiKey) { throw "No CF_API_KEY available" }
    if ($Url -notmatch '/mc-mods/([^/]+)/files/(\d+)') { return $null }
    $slug = $Matches[1]; $fileId = $Matches[2]

    $search = Invoke-CurseForgeApi -Uri "https://api.curseforge.com/v1/mods/search?gameId=432&classId=6&slug=$slug"
    if (-not $search.data -or $search.data.Count -eq 0) { throw "No CurseForge mod found for slug '$slug'" }
    $modId = $search.data[0].id
    $modName = $search.data[0].name

    $fileResp = Invoke-CurseForgeApi -Uri "https://api.curseforge.com/v1/mods/$modId/files/$fileId"
    $file = $fileResp.data
    if (-not $file) { throw "No file data for file $fileId" }
    $sha1 = ($file.hashes | Where-Object { $_.algo -eq 1 } | Select-Object -First 1).value

    [PSCustomObject]@{
        Source = "curseforge"; Type = "mod"; Slug = $slug; Name = $modName
        Filename = $file.fileName; DownloadUrl = $file.downloadUrl; Hash = $sha1
        ModrinthModId = $null; ModrinthVersion = $null
        CfProjectId = $modId; CfFileId = $fileId
    }
}

function Get-ExistingTomlPath {
    param([string]$PackDir, [string]$Source, [string]$ModrinthModId, [string]$CfProjectId)
    $tomlFiles = Get-ChildItem -Path $PackDir -Filter "*.pw.toml" -Recurse -File -ErrorAction SilentlyContinue
    foreach ($f in $tomlFiles) {
        $text = Get-Content -Path $f.FullName -Raw
        if ($Source -eq "modrinth" -and $ModrinthModId -and $text -match "(?m)^\s*mod-id\s*=\s*`"$([regex]::Escape($ModrinthModId))`"") { return $f.FullName }
        if ($Source -eq "curseforge" -and $CfProjectId -and $text -match "(?m)^\s*project-id\s*=\s*$CfProjectId\s*$") { return $f.FullName }
    }
    return $null
}

function Get-ExistingSide {
    param([string]$TomlPath, [string]$DefaultSide = "both")
    if (-not $TomlPath -or -not (Test-Path $TomlPath)) { return $DefaultSide }
    $m = [regex]::Match((Get-Content -Path $TomlPath -Raw), '(?m)^\s*side\s*=\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return $DefaultSide
}

# Sensible per-type defaults, only used when creating a brand-new entry (an existing
# toml's side setting is always preserved regardless of this).
$DefaultSideByType = @{
    mod = "both"; resourcepack = "client"; shader = "client"; datapack = "server"; plugin = "server"
}
# packwiz's on-disk convention: one subfolder per project type
$SubfolderByType = @{
    mod = "mods"; resourcepack = "resourcepacks"; shader = "shaderpacks"; datapack = "datapacks"; plugin = "plugins"
}

function Set-PwTomlEntry {
    param($Entry, [string]$PackDir)
    $existingPath = Get-ExistingTomlPath -PackDir $PackDir -Source $Entry.Source -ModrinthModId $Entry.ModrinthModId -CfProjectId $Entry.CfProjectId
    $defaultSide = if ($DefaultSideByType.ContainsKey($Entry.Type)) { $DefaultSideByType[$Entry.Type] } else { "both" }
    $side = Get-ExistingSide -TomlPath $existingPath -DefaultSide $defaultSide
    $safeName = $Entry.Name -replace '"', '\"'
    $updateBlock = if ($Entry.Source -eq "modrinth") {
        "[update.modrinth]`nmod-id = `"$($Entry.ModrinthModId)`"`nversion = `"$($Entry.ModrinthVersion)`""
    } else {
        "[update.curseforge]`nfile-id = $($Entry.CfFileId)`nproject-id = $($Entry.CfProjectId)"
    }
    $content = @"
name = "$safeName"
filename = "$($Entry.Filename)"
side = "$side"

[download]
url = "$($Entry.DownloadUrl)"
hash-format = "sha1"
hash = "$($Entry.Hash)"

[update]
$updateBlock
"@
    $path = if ($existingPath) { $existingPath } else {
        $subfolder = if ($SubfolderByType.ContainsKey($Entry.Type)) { $SubfolderByType[$Entry.Type] } else { "mods" }
        $targetDir = Join-Path $PackDir $subfolder
        if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir | Out-Null }
        Join-Path $targetDir "$($Entry.Slug).pw.toml"
    }
    Set-Content -Path $path -Value $content -NoNewline
    return $path
}

# ============================== Parse links file ==============================
$section = $null
$targets = New-Object System.Collections.Generic.List[object]
foreach ($rawLine in Get-Content -Path $LinksFile) {
    $line = $rawLine.Trim()
    if (-not $line) { continue }
    if ($line -match '^#{1,3}\s*Modrinth') { $section = 'modrinth'; continue }
    if ($line -match '^#{1,3}\s*Curseforge') { $section = 'curseforge'; continue }
    if ($line -match '^#{1,3}\s*FTB Mods') { $section = 'curseforge'; continue }
    if ($line.StartsWith('#')) { continue }
    $url = ($line -split '\s+', 2)[0]
    if ($url -notmatch '^https?://') { continue }
    $isResolved = ($url -match '/version/[^/?]+$') -or ($url -match '/files/\d+$')
    if (-not $isResolved) { continue }  # e.g. datapack listing pages - handle those manually
    $targets.Add([PSCustomObject]@{ Section = $section; Url = $url })
}
Write-Host "Parsed $($targets.Count) resolved entries from $LinksFile" -ForegroundColor Cyan

# ============================== Load pre-generated inventory (most explicit check) ==============================
# If provided, this becomes the PREFERRED hash source for jar-based entries (mods,
# plugins, and jar-packaged datapacks) instead of re-hashing live every run. It's the
# more explicit check since it was independently generated and can include the jar's
# own internal ModId/Version alongside the hash. Only covers jars (Get-ModFolderInventory.ps1
# is mods/-only) - resourcepacks/shaders/zip-datapacks always fall back to live hashing.
#
# Freshness check: gated on MODPACK_VERSION (from -ModpackVersion or secrets.local.env),
# not a timestamp. This is a value YOU bump manually whenever the pack changes in a way
# that matters. The inventory's meta.json records what version it was generated against;
# if that doesn't match the CURRENT MODPACK_VERSION, the whole inventory is treated as
# stale and discarded - everything falls back to live hashing rather than risk trusting
# hashes that no longer reflect the pack. This is an all-or-nothing gate at the inventory
# level (not per-file), so it only takes one missed version bump to be caught, not one
# missed timestamp per file.
$InventoryByFilename = @{}
if ($InventoryCsv) {
    if (-not (Test-Path $InventoryCsv)) {
        Write-Host "Warning: -InventoryCsv path not found: $InventoryCsv - falling back to live hashing for everything" -ForegroundColor Yellow
    }
    else {
        $metaPath = [System.IO.Path]::ChangeExtension($InventoryCsv, ".meta.json")
        $inventoryVersion = $null
        if (Test-Path $metaPath) {
            try {
                $meta = Get-Content -Path $metaPath -Raw | ConvertFrom-Json
                $inventoryVersion = $meta.ModpackVersion
            }
            catch { }
        }

        if (-not $ModpackVersion) {
            Write-Host "Warning: no current MODPACK_VERSION set (param or secrets.local.env) - cannot verify inventory freshness, falling back to live hashing for everything" -ForegroundColor Yellow
        }
        elseif (-not $inventoryVersion -or $inventoryVersion -eq "unversioned") {
            Write-Host "Warning: inventory has no recorded version (older/unversioned inventory) - falling back to live hashing for everything" -ForegroundColor Yellow
        }
        elseif ($inventoryVersion -ne $ModpackVersion) {
            Write-Host "Inventory version '$inventoryVersion' does not match current MODPACK_VERSION '$ModpackVersion' - STALE, falling back to live hashing for everything" -ForegroundColor Yellow
            Write-Host "  Regenerate with Get-ModFolderInventory.ps1 to refresh it against the current pack state" -ForegroundColor Yellow
        }
        else {
            Write-Host "Inventory version '$inventoryVersion' matches current MODPACK_VERSION - trusting its hashes" -ForegroundColor Cyan
            $blankHashCount = 0
            foreach ($row in (Import-Csv -Path $InventoryCsv)) {
                if ($row.SHA1) {
                    $InventoryByFilename[$row.FileName] = $row.SHA1.ToLower()
                }
                else {
                    $blankHashCount++
                }
            }
            Write-Host "Loaded inventory: $($InventoryByFilename.Count) hashed entries from $InventoryCsv" -ForegroundColor Cyan
            if ($blankHashCount -gt 0) {
                Write-Host "  ($blankHashCount rows had a blank hash - e.g. a past hashing failure - those fall back to live hashing)" -ForegroundColor Yellow
            }
        }
    }
}

# ============================== Snapshot local instance folders (per type) ==============================
# Extensions: mods/plugins are jars; resourcepacks/shaderpacks/datapacks are typically zips.
# Note on datapacks specifically: distribution format varies - a datapack sitting loose in a
# world's datapacks/ folder is an unzipped directory, not a file, and won't be picked up by
# this file-based scan. This only catches datapacks distributed as a single .zip (e.g. via a
# datapack-loader mod's designated folder). Loose-folder datapacks need manual verification.
$FolderConfig = @{
    mod          = @{ Path = $InstanceModsFolder;          Ext = "*.jar" }
    resourcepack = @{ Path = $InstanceResourcepacksFolder;  Ext = "*.zip" }
    shader       = @{ Path = $InstanceShaderpacksFolder;    Ext = "*.zip" }
    datapack     = @{ Path = $InstanceDatapacksFolder;      Ext = "*.zip" }
    plugin       = @{ Path = $InstancePluginsFolder;        Ext = "*.jar" }
}

$localByType = @{}
foreach ($type in $FolderConfig.Keys) {
    $cfg = $FolderConfig[$type]
    $localByType[$type] = @{}
    if (-not $cfg.Path) { continue }
    if (-not (Test-Path $cfg.Path)) {
        Write-Host "Warning: configured $type folder not found: $($cfg.Path)" -ForegroundColor Yellow
        continue
    }
    foreach ($f in Get-ChildItem -Path $cfg.Path -Filter $cfg.Ext -File) {
        $localByType[$type][$f.Name] = $f.FullName
    }
    Write-Host "Found $($localByType[$type].Count) local $type file(s) in $($cfg.Path)" -ForegroundColor Cyan
}

# ============================== Main loop ==============================
$results = New-Object System.Collections.Generic.List[object]
$i = 0
foreach ($target in $targets) {
    $i++
    Write-Host "[$i/$($targets.Count)] $($target.Section): $($target.Url)" -ForegroundColor Green

    $entry = $null
    $errorMsg = $null
    $attempt = 0

    while (-not $entry -and $attempt -le $MaxRetries) {
        if ($attempt -gt 0) {
            $backoff = [Math]::Min($DelaySeconds * [Math]::Pow(2, $attempt), $MaxBackoffSeconds)
            Write-Host "  retrying in ${backoff}s (attempt $attempt/$MaxRetries)" -ForegroundColor Yellow
            Start-Sleep -Seconds $backoff
        }
        try {
            $entry = if ($target.Section -eq 'modrinth') { Resolve-ModrinthEntry -Url $target.Url } else { Resolve-CurseForgeEntry -Url $target.Url }
            if (-not $entry) { $errorMsg = "URL did not match expected pattern"; break }
        }
        catch {
            $info = Get-ErrorInfo -ErrorRecord $_
            $errorMsg = $info.Message
            if ($info.IsRateLimit) { $attempt++; continue }
            break  # non-rate-limit failure - don't burn retries, e.g. bad CF key
        }
    }

    if (-not $entry) {
        Write-Host "  LOOKUP_FAILED: $errorMsg" -ForegroundColor Red
        $results.Add([PSCustomObject]@{
            Source = $target.Section; Type = ""; Slug = ""; RequestedUrl = $target.Url
            Filename = ""; Status = "LOOKUP_FAILED"; ExpectedHash = ""; LocalHash = ""
            HashSource = ""; Notes = $errorMsg
        })
        Start-Sleep -Seconds $DelaySeconds
        continue
    }

    # The Modrinth/CurseForge project CATEGORY (mod/datapack/resourcepack/...) is not a
    # reliable signal for where the file actually lives on disk. Several "datapack"
    # category projects (Structory included) are packaged as a .jar and loaded via the
    # mod loader's data-mod support, so they sit in mods/ like an ordinary mod, not in a
    # datapacks folder. The ACTUAL file extension the API returned is the real signal:
    # a .jar always gets checked against mods/, regardless of what category it's filed
    # under on the platform. Only .zip files fall back to the category-based folder
    # (datapacks/resourcepacks/shaderpacks all use .zip, so category still disambiguates
    # between those three).
    $isJar = $entry.Filename -match '\.jar$'
    $lookupType = if ($isJar) { "mod" } else { $entry.Type }

    $typeFolderConfigured = [bool]$FolderConfig[$lookupType].Path
    $localDict = $localByType[$lookupType]
    $localPath = if ($localDict) { $localDict[$entry.Filename] } else { $null }
    $hashSource = "live"

    if (-not $typeFolderConfigured) {
        $status = "NO_LOCAL_FOLDER_CONFIGURED"
        $localHash = ""
    }
    elseif (-not $localPath) {
        $status = "MISSING_FROM_INSTANCE"
        $localHash = ""
    }
    else {
        # If the inventory passed its version-gate check at load time, its entries are
        # trusted outright - no per-file check needed here anymore.
        if ($isJar -and $InventoryByFilename.ContainsKey($entry.Filename)) {
            $localHash = $InventoryByFilename[$entry.Filename]
            $hashSource = "inventory"
        }
        else {
            $localHash = (Get-FileHash -LiteralPath $localPath -Algorithm SHA1).Hash.ToLower()
        }
        $status = if ($entry.Hash -and ($localHash -ieq $entry.Hash)) { "OK" } else { "HASH_MISMATCH" }
    }

    Write-Host "  $status - [$($entry.Type)/$hashSource] $($entry.Filename)" -ForegroundColor $(if ($status -eq "OK") { "Green" } else { "Yellow" })

    $results.Add([PSCustomObject]@{
        Source = $entry.Source; Type = $entry.Type; Slug = $entry.Slug; RequestedUrl = $target.Url
        Filename = $entry.Filename; Status = $status; ExpectedHash = $entry.Hash; LocalHash = $localHash
        HashSource = $hashSource; Notes = ""
    })

    if ($Apply -and $status -in @("OK", "HASH_MISMATCH", "MISSING_FROM_INSTANCE", "NO_LOCAL_FOLDER_CONFIGURED") -and $entry.Hash) {
        $tomlPath = Set-PwTomlEntry -Entry $entry -PackDir $PackDir
        Write-Host "  toml -> $tomlPath" -ForegroundColor DarkGray
    }

    Start-Sleep -Seconds $DelaySeconds
}

$results | Export-Csv -Path $OutputCsv -NoTypeInformation

$counts = $results | Group-Object Status | Sort-Object Name
Write-Host "`n--- Summary ---" -ForegroundColor Cyan
foreach ($c in $counts) { Write-Host "  $($c.Name): $($c.Count)" }
Write-Host "`nFull report: $OutputCsv" -ForegroundColor Cyan
if ($Apply) { Write-Host "Don't forget: packwiz refresh" -ForegroundColor Cyan }

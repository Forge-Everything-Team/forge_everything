<#
.SYNOPSIS
    Resolves every jar ACTUALLY INSTALLED in the instance to its exact Modrinth
    version (by SHA1) or CurseForge file (by fingerprint) - reversing the
    direction of the old pipeline. Instead of trusting links_to_mods.txt and
    checking the folder against it, this treats the folder as ground truth and
    asks the platforms "which exact version IS this file?"

.DESCRIPTION
    Why this exists - two failure modes in the URL-driven approach:

    1. WRONG VERSION: when a Modrinth URL ends in a human-readable version
       NUMBER (e.g. /version/1.2.7.0-1.21.1) instead of an opaque version ID,
       resolution has to search the project's version list for a matching
       version_number. Modrinth projects routinely publish the SAME version
       number as separate versions per loader (fabric/forge/neoforge) and per
       MC version - so "first match" can silently be the wrong build. Hash
       lookup has no such ambiguity: one SHA1 -> one exact version.

    2. WRONG FILE (.zip vs .jar): datapack-category projects like Structory /
       Structory: Towers attach BOTH a datapack .zip and loader .jars to their
       releases (or mark the .zip as the "primary" file). Selecting the
       version's primary file returns the .zip even though the Modrinth App
       installed the NeoForge .jar. Hash lookup sidesteps this too: we select
       the file within the version whose sha1 EQUALS the local jar's sha1 -
       by construction that is the jar sitting in mods/.

    Pipeline:
      1. Load the inventory CSV (FileName + SHA1 per jar), or hash a mods
         folder live if no inventory is given.
      2. Batch POST all SHA1s to Modrinth /v2/version_files (100 per request)
         -> exact version + exact file for every Modrinth-sourced jar.
      3. Batch GET /v2/projects for slugs/titles of everything matched.
      4. For jars Modrinth doesn't know: compute CurseForge fingerprints
         (murmur2 seed=1 over the file with whitespace bytes stripped) and
         batch POST /v1/fingerprints/432 -> exact modId + fileId. Requires
         CF_API_KEY; skipped (with a warning) if absent.
      5. Whatever matches neither is reported UNMATCHED - expected for
         self-built jars (everythingores/everythingfood dev builds) and
         hand-patched files.

    Outputs:
      - <OutputCsv>: one row per jar with source, slug, exact version/file id,
        canonical URL, and whether the platform filename matches the local one.
      - <ResolvedLinksOut>: a regenerated links file (##Modrinth /
        ##Curseforge sections) with EXACT version-ID URLs - this becomes the
        new ground-truth links_to_mods.txt, replacing hand-collected links.
      - With -Apply -PackDir: writes/updates one .pw.toml per matched jar
        under <PackDir>\mods\. An existing entry (matched by Modrinth mod-id
        or CF project-id, same convention as Process-ModList.ps1) is updated
        in place with its 'side' preserved. CurseForge entries are written in
        packwiz's metadata mode (mode = "metadata:curseforge") so they work
        even when the author has disabled third-party API downloads.
      - With -LinksFile: a drift report comparing the old hand-collected links
        against what's actually installed (projects linked but not installed,
        installed but not linked, and Modrinth version-ID mismatches).

    CONFIGURATION
    Every path below can be set once in secrets.local.env rather than typed on
    each run. Keys are shared across all five scripts, so the inventory this
    script reads is by construction the one Get-ModFolderInventory wrote:

        MODPACK_ROOT=C:\Users\Terra\projects\Minecraft Modpacks\forge_everything
        INSTANCE_ROOT=C:\Users\Terra\AppData\Roaming\ModrinthApp\profiles\NeoForge 1.21.1
        PACK_DIR=${MODPACK_ROOT}\packwiz
        OUTPUT_DIR=${MODPACK_ROOT}\reports
        LINKS_FILE=${MODPACK_ROOT}\links_to_mods.txt
        CF_STATE_DIR=${MODPACK_ROOT}\.cfstate
        CF_API_KEY=$2a$10$...
        MODRINTH_TOKEN=...

    A parameter typed on the command line always beats the file. -Apply is
    intentionally not configurable: the dry-run-by-default posture of the
    pipeline should not be flippable from a config file.

.PARAMETER SecretsFile
    Path to the settings file. Defaults to $env:FORGE_EVERYTHING_SECRETS, else
    secrets.local.env beside this script.

.PARAMETER InventoryCsv
    Path to mod-folder-inventory.csv from Get-ModFolderInventory.ps1
    (needs FileName + SHA1 columns). Preferred over live hashing.
    Falls back to INVENTORY_CSV, then OUTPUT_DIR\mod-folder-inventory.csv if
    that file exists.

.PARAMETER InstanceModsFolder
    Used to hash jars live when -InventoryCsv is omitted, and (always) to
    locate the physical files for CurseForge fingerprinting. If you pass only
    -InventoryCsv, fingerprinting reads paths from the CSV's FullPath column.

.PARAMETER LinksFile
    Optional. Old links_to_mods.txt to produce the drift report against.

.PARAMETER Apply / PackDir
    Write .pw.toml files into <PackDir>\mods (PackDir must contain pack.toml).

.PARAMETER SelfTest
    Verifies the embedded murmur2/fingerprint implementation against known
    vectors and exits. Run this once before trusting CF fingerprint results.

.PARAMETER TestCfKey
    Diagnoses the CurseForge API key (shape check + optional live probe against
    /v1/games/432) and exits without touching the mods folder. Use this when
    Phase 2 dies with a 401 - it tells you WHICH key was loaded, from where,
    and what is wrong with it, instead of failing 74 fingerprints later.
    The same shape check runs automatically on every normal run.

.EXAMPLE
    .\Resolve-InstanceByHash.ps1 -InventoryCsv .\mod-folder-inventory.csv `
        -LinksFile .\links_to_mods.txt

.EXAMPLE
    .\Resolve-InstanceByHash.ps1 -InventoryCsv .\mod-folder-inventory.csv `
        -Apply -PackDir "C:\Users\Terra\projects\forge-everything-pack\packwiz"

.EXAMPLE
    .\Resolve-InstanceByHash.ps1 -TestCfKey
#>

param(
    [string]$InventoryCsv,
    [string]$InstanceModsFolder,

    [string]$LinksFile,

    [switch]$Apply,
    [string]$PackDir,

    [string]$ApiToken,
    [string]$CfApiKey,
    # No default here: PackConfig.ps1 owns the fallback chain
    # (-SecretsFile, then $env:FORGE_EVERYTHING_SECRETS, then
    # secrets.local.env beside the script) so all five scripts agree.
    [string]$SecretsFile,

    [int]$ChunkSize = 100,
    [int]$DelaySeconds = 1,
    [int]$MaxRetries = 5,
    [int]$MaxBackoffSeconds = 60,

    # --- CurseForge governor (see the CF GOVERNOR section for rationale) ---
    [string]$CfStateDir = $PSScriptRoot,
    [int]$CfMaxRequestsPerHour = 90,
    [int]$CfMaxRequestsPerMinute = 8,
    [int]$CfMinIntervalSeconds = 4,
    [int]$CfCooldownMinutes = 60,
    [int]$CfMissTtlDays = 14,
    [switch]$CfNoCache,
    [switch]$CfClearCooldown,
    [switch]$CfStatus,

    [string]$OutputCsv = ".\hash-resolution-report.csv",
    [string]$ResolvedLinksOut = ".\links_to_mods.resolved-by-hash.txt",
    [string]$DriftCsv = ".\links-drift-report.csv",

    [switch]$SelfTest,
    [switch]$TestCfKey
)

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# ============================ CurseForge fingerprint =============================
# CF fingerprint = MurmurHash2 (Austin Appleby reference, 32-bit, seed = 1) computed
# over the file's bytes AFTER stripping whitespace bytes 0x09 0x0A 0x0D 0x20.
# Implemented in C# via Add-Type because doing per-byte work in pure PowerShell on
# ~500 multi-MB jars would take minutes; this does the whole folder in seconds.
Add-Type -TypeDefinition @"
public static class CfFingerprint
{
    public static uint ComputeFromFile(string path)
    {
        byte[] data = System.IO.File.ReadAllBytes(path);
        return Compute(data);
    }

    public static uint Compute(byte[] data)
    {
        int len = 0;
        byte[] filtered = new byte[data.Length];
        for (int j = 0; j < data.Length; j++)
        {
            byte b = data[j];
            if (b == 9 || b == 10 || b == 13 || b == 32) continue;
            filtered[len++] = b;
        }
        return Murmur2(filtered, len, 1u);
    }

    private static uint Murmur2(byte[] data, int length, uint seed)
    {
        const uint m = 0x5bd1e995;
        const int r = 24;
        uint h = seed ^ (uint)length;
        int i = 0;
        while (length >= 4)
        {
            uint k = (uint)(data[i] | data[i + 1] << 8 | data[i + 2] << 16 | data[i + 3] << 24);
            k *= m; k ^= k >> r; k *= m;
            h *= m; h ^= k;
            i += 4; length -= 4;
        }
        switch (length)
        {
            case 3: h ^= (uint)(data[i + 2] << 16); goto case 2;
            case 2: h ^= (uint)(data[i + 1] << 8); goto case 1;
            case 1: h ^= data[i]; h *= m; break;
        }
        h ^= h >> 13; h *= m; h ^= h >> 15;
        return h;
    }
}
"@

if ($SelfTest) {
    # Vectors cross-verified against two independent implementations (Python + Node).
    $enc = [System.Text.Encoding]::UTF8
    $blob = New-Object byte[] 100003
    for ($i = 0; $i -lt $blob.Length; $i++) { $blob[$i] = [byte]((($i * $i * 31) + 7) % 256) }
    $big = New-Object byte[] (256 * 7 + 3)
    for ($i = 0; $i -lt 256 * 7; $i++) { $big[$i] = [byte]($i % 256) }
    $big[256*7] = 120; $big[256*7+1] = 121; $big[256*7+2] = 122  # "xyz"
    $vectors = @(
        @{ Data = $enc.GetBytes("");                        Expect = 1540447798 }
        @{ Data = $enc.GetBytes("a");                       Expect = 626045324 }
        @{ Data = $enc.GetBytes("ab");                      Expect = 1692487918 }
        @{ Data = $enc.GetBytes("abc");                     Expect = 1621425345 }
        @{ Data = $enc.GetBytes("abcd");                    Expect = 3376380438 }
        @{ Data = $enc.GetBytes("hello world`r`n`t test");  Expect = 1058731812 }
        @{ Data = $big;                                     Expect = 3423133700 }
        @{ Data = $blob;                                    Expect = 219597404 }
    )
    $fail = 0
    foreach ($v in $vectors) {
        $got = [CfFingerprint]::Compute($v.Data)
        $ok = ([long]$got -eq [long]$v.Expect)
        if (-not $ok) { $fail++ }
        Write-Host ("  {0}  expect={1}  got={2}" -f ($(if ($ok) { "PASS" } else { "FAIL" }), $v.Expect, $got)) -ForegroundColor $(if ($ok) { "Green" } else { "Red" })
    }
    if ($fail -eq 0) { Write-Host "Fingerprint self-test: ALL PASS" -ForegroundColor Green; exit 0 }
    else { Write-Host "Fingerprint self-test FAILED - do not trust CF fingerprint results" -ForegroundColor Red; exit 1 }
}

# ========================== Secrets and settings ==========================
$PackConfigPath = Join-Path $PSScriptRoot "PackConfig.ps1"
if (-not (Test-Path -LiteralPath $PackConfigPath)) {
    Write-Error "PackConfig.ps1 was not found at $PackConfigPath. It ships alongside this script and is required; without it, settings in secrets.local.env would be ignored silently."
    exit 1
}
. $PackConfigPath
Initialize-PackConfig -SecretsFile $SecretsFile -ScriptRoot $PSScriptRoot
# Pin the resolved path so every later diagnostic (-TestCfKey especially) names
# the file that was actually read, not an empty parameter.
$SecretsFile = Resolve-PackSecretsFile -SecretsFile $SecretsFile

# Provenance matters when diagnosing a 401: a stale env var silently wins over a
# freshly-corrected secrets.local.env, and you can stare at the good file for an
# hour while the bad value is the one on the wire.
$CfApiKeySource = "-CfApiKey parameter"
if (-not $CfApiKey) { $CfApiKey = $env:CF_API_KEY; $CfApiKeySource = "`$env:CF_API_KEY" }
if (-not $CfApiKey) {
    $CfApiKey = Get-PackSetting -Name CF_API_KEY
    if ($CfApiKey) { $CfApiKeySource = "secrets file ($SecretsFile)" }
}
if (-not $CfApiKey) { $CfApiKeySource = "none" }
if (-not $ApiToken) { $ApiToken = $env:MODRINTH_TOKEN }
if (-not $ApiToken) { $ApiToken = Get-PackSetting -Name MODRINTH_TOKEN }

# --- Path settings. Same rule everywhere: an explicitly-passed parameter wins,
# --- otherwise fall back to the settings file, otherwise the built-in default.
# The inventory is an INPUT, so it does not go through Get-PackOutputPath: that
# helper invents a .\<name> default, and inventing an input path is how you end
# up resolving against a stale CSV you forgot was in the working directory. An
# INVENTORY_CSV you actually set is honoured as written - and still hard-errors
# below if it is missing, rather than quietly falling back to live hashing.
# Only the OUTPUT_DIR-derived guess is conditional on the file existing.
if (-not $PSBoundParameters.ContainsKey('InventoryCsv')) {
    $InventoryCsv = Get-PackSetting -Name INVENTORY_CSV -AsPath -Default $InventoryCsv
    if (-not $InventoryCsv) {
        $inventoryOutDir = Get-PackSetting -Name OUTPUT_DIR -AsPath
        if ($inventoryOutDir) {
            $inventoryGuess = Join-Path $inventoryOutDir "mod-folder-inventory.csv"
            if (Test-Path -LiteralPath $inventoryGuess) { $InventoryCsv = $inventoryGuess }
        }
    }
}
if (-not $PSBoundParameters.ContainsKey('InstanceModsFolder')) {
    $InstanceModsFolder = Get-PackFolderSetting -Name INSTANCE_MODS_FOLDER -ParentName INSTANCE_ROOT -ChildFolder "mods" -Default $InstanceModsFolder
}
if (-not $PSBoundParameters.ContainsKey('LinksFile')) {
    $LinksFile = Get-PackSetting -Name LINKS_FILE -AsPath -Default $LinksFile
}
if (-not $PSBoundParameters.ContainsKey('PackDir')) {
    $PackDir = Get-PackSetting -Name PACK_DIR -AsPath -Default $PackDir
}
if (-not $PSBoundParameters.ContainsKey('CfStateDir')) {
    $CfStateDir = Get-PackSetting -Name CF_STATE_DIR -AsPath -Default $CfStateDir
}
# The default state dir is the script folder and always exists. A configured one
# may not, and discovering that at ledger-write time means losing the rate-limit
# accounting for a run that already spent the requests.
if ($CfStateDir -and -not (Test-Path -LiteralPath $CfStateDir)) {
    New-Item -ItemType Directory -Path $CfStateDir -Force | Out-Null
}
if (-not $PSBoundParameters.ContainsKey('OutputCsv')) {
    $OutputCsv = Get-PackOutputPath -Name RESOLUTION_REPORT_CSV -DefaultFileName "hash-resolution-report.csv" -Default $OutputCsv
}
if (-not $PSBoundParameters.ContainsKey('ResolvedLinksOut')) {
    $ResolvedLinksOut = Get-PackOutputPath -Name RESOLVED_LINKS_OUT -DefaultFileName "links_to_mods.resolved-by-hash.txt" -Default $ResolvedLinksOut
}
if (-not $PSBoundParameters.ContainsKey('DriftCsv')) {
    $DriftCsv = Get-PackOutputPath -Name DRIFT_CSV -DefaultFileName "links-drift-report.csv" -Default $DriftCsv
}

if (-not $TestCfKey -and -not $CfStatus -and -not $InventoryCsv -and -not $InstanceModsFolder) {
    Write-Error "Provide -InventoryCsv (preferred) and/or -InstanceModsFolder, or set INVENTORY_CSV / INSTANCE_MODS_FOLDER (or INSTANCE_ROOT) in $SecretsFile."
    exit 1
}
if ($Apply -and -not ($PackDir -and (Test-Path (Join-Path $PackDir "pack.toml")))) {
    Write-Error "-Apply requires a pack directory containing pack.toml. Pass -PackDir, or set PACK_DIR in $SecretsFile. Current value: $(if ($PackDir) { $PackDir } else { '<not set>' })"
    exit 1
}

if (-not $TestCfKey -and -not $CfStatus) {
    Show-PackConfigSummary -Values @{
        InventoryCsv       = $InventoryCsv
        InstanceModsFolder = $InstanceModsFolder
        LinksFile          = $LinksFile
        PackDir            = $PackDir
        CfStateDir         = $CfStateDir
        OutputCsv          = $OutputCsv
        ResolvedLinksOut   = $ResolvedLinksOut
        DriftCsv           = $DriftCsv
    }
}

# ================================ Helpers ================================
function Invoke-WithRetry {
    param([scriptblock]$Call, [string]$What)
    $attempt = 0
    while ($true) {
        try { return (& $Call) }
        catch {
            $msg = $_.Exception.Message
            # Windows PowerShell 5.1 usually leaves ErrorDetails null for
            # Invoke-RestMethod, so the server's own explanation ("A valid
            # api-key is required.") is lost unless we read the stream.
            $body = ""
            if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $body = $_.ErrorDetails.Message }
            elseif ($_.Exception.Response) {
                try {
                    $stream = $_.Exception.Response.GetResponseStream()
                    if ($stream.CanSeek) { $stream.Position = 0 }
                    $body = (New-Object System.IO.StreamReader($stream)).ReadToEnd()
                } catch { }
            }
            if ($msg -match '\(401\)') {
                $hint = if ($What -match 'fingerprint|mods batch') { " Re-run with -TestCfKey to inspect the CurseForge key." } else { " Check MODRINTH_TOKEN." }
                Write-Host "  401 on $What - the credential on the wire was rejected.$hint" -ForegroundColor Red
            }
            $isRateLimit = ($msg -match '429') -or ($body -match '429')
            if ($isRateLimit -and $attempt -lt $MaxRetries) {
                $attempt++
                $backoff = [Math]::Min($DelaySeconds * [Math]::Pow(2, $attempt), $MaxBackoffSeconds)
                Write-Host "  429 on $What - retrying in ${backoff}s (attempt $attempt/$MaxRetries)" -ForegroundColor Yellow
                Start-Sleep -Seconds $backoff
                continue
            }
            throw "$What failed: $msg $body"
        }
    }
}

function Invoke-Modrinth {
    param([string]$Uri, [string]$Method = "Get", [string]$BodyJson)
    $headers = @{ "User-Agent" = "ForgeEverything-HashResolver/1.0 (contact: terra)" }
    if ($ApiToken) { $headers["Authorization"] = $ApiToken }
    if ($Method -eq "Post") {
        return Invoke-RestMethod -Uri $Uri -Method Post -Headers $headers -Body $BodyJson -ContentType "application/json"
    }
    return Invoke-RestMethod -Uri $Uri -Headers $headers
}

function Invoke-CurseForge {
    param([string]$Uri, [string]$Method = "Get", [string]$BodyJson)
    $headers = @{ "x-api-key" = $CfApiKey; "Accept" = "application/json"; "User-Agent" = "ForgeEverything-HashResolver/1.0 (contact: terra)" }
    if ($Method -eq "Post") {
        return Invoke-RestMethod -Uri $Uri -Method Post -Headers $headers -Body $BodyJson -ContentType "application/json"
    }
    return Invoke-RestMethod -Uri $Uri -Headers $headers
}

# ========================== CurseForge key diagnosis ==========================
# A CurseForge API key is a bcrypt-shaped string: a '$2a$10$' prefix plus 53
# characters = 60 total, containing EXACTLY three '$'. CF answers 401 for a
# missing OR malformed key and 403 for a valid-but-unauthorised/rate-limited
# one, so a 401 is always a statement about the literal bytes we sent - which
# is why checking the shape locally resolves this faster than any retry logic.
#
# The dominant failure is a MANGLED key, not an absent one, because '$' is the
# PowerShell interpolation sigil:
#     $env:CF_API_KEY = "$2a$10$IWDpXbn..."   -> $2a, $10, $IWDpXbn all expand
#                                                to empty; you store garbage
#     $env:CF_API_KEY = '$2a$10$IWDpXbn...'   -> correct (single quotes)
# The same applies to any script that WROTE secrets.local.env using double
# quotes, or an interpolating here-string instead of a literal one.
#
# Second most common: an inline comment or stray quote surviving the parse,
# since the secrets reader only skips lines that START with '#'.
function Test-CfApiKey {
    param([string]$Key, [string]$Source = "unknown")

    $problems = New-Object System.Collections.Generic.List[string]

    if ([string]::IsNullOrEmpty($Key)) {
        return [PSCustomObject]@{
            Ok = $false; Present = $false; Source = $Source; Length = 0
            Masked = "<empty>"; Problems = @("no key found (checked -CfApiKey, `$env:CF_API_KEY, then $SecretsFile)")
        }
    }

    $len     = $Key.Length
    $dollars = @($Key.ToCharArray() | Where-Object { $_ -eq '$' }).Count
    # 2a is what CF issues; 2b/2y accepted so a future reissue doesn't false-alarm.
    $prefixOk = ($Key -match '^\$2[aby]\$\d\d\$')

    if ($len -ne 60)                  { $problems.Add("length is $len, expected 60") }
    if (-not $prefixOk)               { $problems.Add("does not start with a bcrypt prefix like '" + '$2a$10$' + "'") }
    if ($dollars -ne 3)               { $problems.Add("contains $dollars '" + '$' + "' characters, expected exactly 3") }
    if ($Key -ne $Key.Trim())         { $problems.Add("has leading or trailing whitespace") }
    if ($Key -match '#')              { $problems.Add("contains '#' - an inline comment leaked in from the secrets file") }
    if ($Key -match '["'']')          { $problems.Add("contains a quote character - strip the quotes around the value") }
    if ($Key -match '[\u2018\u2019\u201C\u201D]') { $problems.Add("contains smart quotes - re-copy the key as plain text") }
    if ($Key.Trim() -match '\s')      { $problems.Add("contains internal whitespace - the value was split or a comment ran into it") }

    # Interpolation damage has a signature: the '$2a$10$' head is eaten while a
    # plausible-looking tail survives, so the key is short but not empty.
    if ($len -gt 0 -and $len -lt 60 -and -not $prefixOk) {
        $problems.Add("looks like PowerShell ate the '" + '$' + "' segments - assign the key with SINGLE quotes, not double")
    }

    $masked = if ($len -ge 12) { $Key.Substring(0, 7) + ('*' * ($len - 11)) + $Key.Substring($len - 4) } else { '*' * $len }

    return [PSCustomObject]@{
        Ok = ($problems.Count -eq 0); Present = $true; Source = $Source
        Length = $len; Masked = $masked; Problems = @($problems)
        Tail = (@([int[]][char[]]$Key | Select-Object -Last 6) -join ',')
    }
}

function Write-CfKeyDiagnosis {
    param($Diag)
    Write-Host "`nCurseForge API key check" -ForegroundColor Cyan
    Write-Host "  source : $($Diag.Source)"
    Write-Host "  value  : $($Diag.Masked)"
    Write-Host "  length : $($Diag.Length) (expected 60)"
    if ($Diag.Ok) {
        Write-Host "  shape  : OK" -ForegroundColor Green
        return
    }
    Write-Host "  shape  : PROBLEM" -ForegroundColor Red
    foreach ($p in $Diag.Problems) { Write-Host "    - $p" -ForegroundColor Yellow }
    if ($Diag.Present) {
        Write-Host "  Fix: put the key in the secrets file unquoted, one line, no trailing comment:" -ForegroundColor Cyan
        Write-Host '           CF_API_KEY=$2a$10$...' -ForegroundColor DarkGray
        Write-Host "       or set it in the shell with SINGLE quotes:" -ForegroundColor Cyan
        Write-Host '           $env:CF_API_KEY = ''$2a$10$...''' -ForegroundColor DarkGray
        Write-Host "       Secrets file in use: $SecretsFile" -ForegroundColor Cyan
        Write-Host "       Regenerate at https://console.curseforge.com/ if in doubt." -ForegroundColor Cyan
        # Trailing codepoints expose damage the eye cannot catch.
        Write-Host "  (last codepoints: $($Diag.Tail)  - 32=space, 9=tab, 35='#', 34/39=quote)" -ForegroundColor DarkGray
    }
}

# ============================== CF GOVERNOR ==============================
# CurseForge does not publish its rate limits. The community consensus is that
# they are low, that the reset window is unknown (an hour is the usual advice),
# and that what actually gets a key flagged is a process retrying in a tight
# loop after the first rejection. Some 403s are Cloudflare reacting to the IP
# rather than CurseForge reacting to the key.
#
# Because the ceiling is unknowable, this does NOT try to ride close to it.
# Five layers, cheapest first:
#
#   1. CACHE       A fingerprint is a content hash: fingerprint -> CF file is a
#                  permanent fact. Cache it on disk and a re-run costs zero
#                  requests. This is by far the biggest saving, since the
#                  workflow is "run the script repeatedly while iterating".
#                  Misses are cached too (a dev jar will never be on CF), with
#                  a TTL so a newly-published mod is eventually re-checked.
#   2. BATCHING    /v1/fingerprints takes 100 per call, /v1/mods takes 50.
#                  74 unmatched jars is ONE fingerprint call plus one or two
#                  mods calls. The budget below is enormous relative to need.
#   3. BUDGET      A ledger of request timestamps persisted ACROSS RUNS. In-
#                  process pacing is useless here: ten runs in ten minutes is
#                  the realistic pattern, and each would start with a clean
#                  counter. Rolling hour + rolling minute windows.
#   4. SPACING     Minimum interval between requests, with jitter, serial only.
#                  Never parallel.
#   5. BREAKER     On 429/403 the run does not retry into the wall. It records
#                  a cooldown timestamp in the ledger and every subsequent run
#                  refuses to touch CF until it expires. This is the layer that
#                  actually protects the key; the others just make it rare.
#
# 401 is deliberately NOT treated as throttling: it is a bad credential, not a
# transient condition, and backing off would only obscure it.

$script:CfLedgerPath = Join-Path $CfStateDir ".cf-ratelimit.json"
$script:CfCachePath  = Join-Path $CfStateDir ".cf-cache.json"
$script:CfLedger     = $null
$script:CfCache      = $null
$script:CfLastCall   = $null
$script:CfCallsThisRun = 0
$script:CfCacheHits    = 0

function Read-JsonFileOrNull {
    param([string]$Path)
    if (-not (Test-Path $Path)) { return $null }
    try { return (Get-Content -Path $Path -Raw -ErrorAction Stop | ConvertFrom-Json) }
    catch { Write-Host "  (corrupt state file, starting fresh: $Path)" -ForegroundColor Yellow; return $null }
}

function ConvertTo-HashtableShallow {
    # PS 5.1 has no ConvertFrom-Json -AsHashtable.
    param($Obj)
    $h = @{}
    if ($Obj) { foreach ($p in $Obj.PSObject.Properties) { $h[$p.Name] = $p.Value } }
    return $h
}

function Initialize-CfState {
    $l = Read-JsonFileOrNull -Path $script:CfLedgerPath
    $cutoff = (Get-Date).ToUniversalTime().AddHours(-1)
    # ArrayList, not List[datetime], deliberately. A strongly-typed generic
    # list makes .Add() overload resolution the caller's problem, and a
    # PSObject-wrapped DateTime arriving there fails with an unhelpful
    # "Argument types do not match". Nothing here needs the type safety.
    $stamps = New-Object System.Collections.ArrayList
    if ($l -and $l.Requests) {
        foreach ($s in $l.Requests) {
            try {
                $t = [datetime]::Parse($s, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                if ($t -gt $cutoff) { [void]$stamps.Add($t) }   # prune: only the rolling hour matters
            } catch { }
        }
    }
    $cool = $null
    if ($l -and $l.CooldownUntil) {
        try { $cool = [datetime]::Parse($l.CooldownUntil, $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { }
    }
    if ($CfClearCooldown -and $cool) {
        Write-Host "Clearing CF cooldown (was until $($cool.ToString('u')))" -ForegroundColor Yellow
        $cool = $null
    }
    $script:CfLedger = [PSCustomObject]@{
        Stamps        = $stamps
        CooldownUntil = $cool
        LastReason    = if ($l) { $l.LastReason } else { "" }
        # Strikes survive -CfClearCooldown on purpose. Clearing the cooldown is
        # a deliberate override for a changed situation (different network);
        # it is not a claim that the previous rejections never happened, so it
        # must not reset the escalation ladder.
        Strikes       = if ($l -and $l.Strikes) { [int]$l.Strikes } else { 0 }
    }

    $script:CfCache = @{ Fingerprints = @{}; Misses = @{}; Mods = @{} }
    if (-not $CfNoCache) {
        $c = Read-JsonFileOrNull -Path $script:CfCachePath
        if ($c) {
            $script:CfCache.Fingerprints = ConvertTo-HashtableShallow $c.Fingerprints
            $script:CfCache.Misses       = ConvertTo-HashtableShallow $c.Misses
            $script:CfCache.Mods         = ConvertTo-HashtableShallow $c.Mods
        }
    }
}

function Save-CfLedger {
    $obj = [PSCustomObject]@{
        Requests      = @($script:CfLedger.Stamps | ForEach-Object { $_.ToString("o") })
        CooldownUntil = if ($script:CfLedger.CooldownUntil) { $script:CfLedger.CooldownUntil.ToString("o") } else { $null }
        LastReason    = $script:CfLedger.LastReason
        Strikes       = $script:CfLedger.Strikes
    }
    Write-TextFile -Path $script:CfLedgerPath -Text ($obj | ConvertTo-Json -Depth 4) | Out-Null
}

function Save-CfCache {
    if ($CfNoCache) { return }
    $obj = [PSCustomObject]@{
        Fingerprints = $script:CfCache.Fingerprints
        Misses       = $script:CfCache.Misses
        Mods         = $script:CfCache.Mods
    }
    Write-TextFile -Path $script:CfCachePath -Text ($obj | ConvertTo-Json -Depth 6) | Out-Null
}

function Get-CfBudgetState {
    $now = (Get-Date).ToUniversalTime()
    $hourAgo = $now.AddHours(-1); $minAgo = $now.AddMinutes(-1)
    $inHour = @($script:CfLedger.Stamps | Where-Object { $_ -gt $hourAgo }).Count
    $inMin  = @($script:CfLedger.Stamps | Where-Object { $_ -gt $minAgo }).Count
    return [PSCustomObject]@{
        InHour        = $inHour
        InMinute      = $inMin
        HourRemaining = [Math]::Max(0, $CfMaxRequestsPerHour - $inHour)
        MinRemaining  = [Math]::Max(0, $CfMaxRequestsPerMinute - $inMin)
        CooldownUntil = $script:CfLedger.CooldownUntil
        InCooldown    = ($script:CfLedger.CooldownUntil -and $now -lt $script:CfLedger.CooldownUntil)
    }
}

function Set-CfCooldown {
    param([string]$Reason, [int]$Minutes = 0)
    # Escalation ladder. A flat cooldown is wrong for the failure mode we
    # actually hit: an IP-level block can last days, and a fixed 60 minutes
    # means ~24 rejected probes a day, each of which plausibly refreshes the
    # block. Each consecutive trip doubles the wait, capped at 24h.
    $script:CfLedger.Strikes = [int]$script:CfLedger.Strikes + 1
    if ($Minutes -le 0) {
        $mult = [Math]::Pow(2, [Math]::Min($script:CfLedger.Strikes - 1, 6))
        $Minutes = [int][Math]::Min($CfCooldownMinutes * $mult, 1440)
    }
    $script:CfLedger.CooldownUntil = (Get-Date).ToUniversalTime().AddMinutes($Minutes)
    $script:CfLedger.LastReason    = $Reason
    Save-CfLedger
    Write-Host "  CF breaker tripped (strike $($script:CfLedger.Strikes)): $Reason" -ForegroundColor Red
    $hrs = [Math]::Round($Minutes / 60.0, 1)
    Write-Host "  No CurseForge requests for ${Minutes}m (~${hrs}h), until $($script:CfLedger.CooldownUntil.ToString('u')) UTC. Persists across runs." -ForegroundColor Yellow
    if ($script:CfLedger.Strikes -ge 3) {
        Write-Host "  Three or more consecutive rejections: this is not transient. Stop probing" -ForegroundColor Yellow
        Write-Host "  and use Build-CurseforgeEntries.ps1, which needs no API access." -ForegroundColor Cyan
    }
}

function Reset-CfStrikes {
    # Any successful request proves the block is gone. Clear the ladder so a
    # future unrelated hiccup starts at 60m rather than 24h.
    if ([int]$script:CfLedger.Strikes -gt 0) {
        Write-Host "  CF request succeeded - clearing $($script:CfLedger.Strikes) strike(s)" -ForegroundColor Green
        $script:CfLedger.Strikes = 0
        $script:CfLedger.LastReason = ""
        Save-CfLedger
    }
}

function Invoke-CfGoverned {
    # Every CurseForge request in this script goes through here. Throws
    # CF_HALT:* for conditions the caller should treat as "stop Phase 2
    # cleanly", as opposed to a genuine transport failure.
    param([string]$Uri, [string]$Method = "Get", [string]$BodyJson, [string]$What = "cf request")

    $budget = Get-CfBudgetState
    if ($budget.InCooldown) {
        throw "CF_HALT: cooldown active until $($budget.CooldownUntil.ToString('u')) UTC (reason: $($script:CfLedger.LastReason))"
    }
    if ($budget.HourRemaining -le 0) {
        throw "CF_HALT: local hourly budget spent ($CfMaxRequestsPerHour/hr). Oldest request ages out shortly; re-run later."
    }
    if ($budget.MinRemaining -le 0) {
        $wait = 61 - [int]((Get-Date).ToUniversalTime() - ($script:CfLedger.Stamps | Sort-Object | Select-Object -Last $CfMaxRequestsPerMinute | Select-Object -First 1)).TotalSeconds
        if ($wait -gt 0) {
            Write-Host "  per-minute budget reached, pausing ${wait}s" -ForegroundColor DarkGray
            Start-Sleep -Seconds $wait
        }
    }

    # Spacing with jitter - serial, never parallel.
    if ($script:CfLastCall) {
        $elapsed = ((Get-Date) - $script:CfLastCall).TotalSeconds
        $need = $CfMinIntervalSeconds + (Get-Random -Minimum 0.0 -Maximum 1.0)
        if ($elapsed -lt $need) { Start-Sleep -Milliseconds ([int](($need - $elapsed) * 1000)) }
    }

    $script:CfLastCall = Get-Date
    $nowUtc = [datetime]((Get-Date).ToUniversalTime())
    [void]$script:CfLedger.Stamps.Add($nowUtc)
    $script:CfCallsThisRun++
    Save-CfLedger   # recorded BEFORE the call: a crash must not lose the debit

    try {
        $resp = Invoke-CurseForge -Uri $Uri -Method $Method -BodyJson $BodyJson
        Reset-CfStrikes
        return $resp
    }
    catch {
        $code = 0; $retryAfter = 0
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            $ra = $_.Exception.Response.Headers["Retry-After"]
            if ($ra -and [int]::TryParse($ra, [ref]$retryAfter)) { }
        }
        if ($code -eq 429 -or $code -eq 403) {
            # One polite retry only if the server told us exactly how long and
            # it is short. Otherwise trip the breaker - never loop into a wall.
            if ($retryAfter -gt 0 -and $retryAfter -le $MaxBackoffSeconds) {
                Write-Host "  $code on $What, honouring Retry-After ${retryAfter}s (one retry)" -ForegroundColor Yellow
                Start-Sleep -Seconds ($retryAfter + 1)
                [void]$script:CfLedger.Stamps.Add([datetime]((Get-Date).ToUniversalTime()))
                $script:CfCallsThisRun++
                Save-CfLedger
                try { return (Invoke-CurseForge -Uri $Uri -Method $Method -BodyJson $BodyJson) }
                catch { Set-CfCooldown -Reason "HTTP $code on $What (retry also rejected)"; throw "CF_HALT: throttled" }
            }
            $mins = if ($retryAfter -gt 0) { [Math]::Ceiling($retryAfter / 60.0) } else { $CfCooldownMinutes }
            Set-CfCooldown -Reason "HTTP $code on $What" -Minutes $mins
            throw "CF_HALT: throttled"
        }
        if ($code -eq 401) { throw "CF_HALT: 401 Unauthorized on $What - bad credential, not throttling. Run -TestCfKey." }
        throw
    }
}

function Split-IntoChunks {
    param($Items, [int]$Size)
    $chunks = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $Items.Count; $i += $Size) {
        $end = [Math]::Min($i + $Size - 1, $Items.Count - 1)
        $chunks.Add(@($Items[$i..$end]))
    }
    # Comma prevents PS from unrolling a single-chunk List into its inner
    # elements on return (which would turn one batch call into N single calls)
    return , $chunks
}

function Write-TextFile {
    # Reliable large-output write on Windows PowerShell 5.1 (Set-Content can
    # silently truncate large strings) - UTF-8 without BOM.
    param([string]$Path, [string]$Text)
    # Test rootedness FIRST. Joining the CWD onto an already-absolute path
    # yields "C:\cwd\C:\target\file", and GetFullPath throws NotSupportedException
    # on the embedded colon. The old order computed that doomed join before the
    # rootedness check, so every absolute-path write emitted a (harmless but
    # alarming) non-terminating error before succeeding on the next line.
    $full = if ([System.IO.Path]::IsPathRooted($Path)) {
        $Path
    } else {
        [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $Path))
    }
    [System.IO.File]::WriteAllText($full, $Text, (New-Object System.Text.UTF8Encoding($false)))
    return $full
}

# Same conventions as Process-ModList.ps1: locate an existing toml by platform id,
# preserve its 'side'.
function Get-ExistingTomlPath {
    param([string]$PackDir, [string]$Source, [string]$ModrinthModId, $CfProjectId)
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

function Set-PwToml {
    param($Entry, [string]$PackDir)
    $existingPath = Get-ExistingTomlPath -PackDir $PackDir -Source $Entry.Source -ModrinthModId $Entry.ModrinthProjectId -CfProjectId $Entry.CfProjectId
    $side = Get-ExistingSide -TomlPath $existingPath -DefaultSide "both"
    $safeName = $Entry.Name -replace '"', '\"'
    if ($Entry.Source -eq "modrinth") {
        $content = @"
name = "$safeName"
filename = "$($Entry.ApiFilename)"
side = "$side"

[download]
url = "$($Entry.DownloadUrl)"
hash-format = "sha1"
hash = "$($Entry.Sha1)"

[update]
[update.modrinth]
mod-id = "$($Entry.ModrinthProjectId)"
version = "$($Entry.ModrinthVersionId)"
"@
    }
    else {
        # packwiz's native CurseForge format: no direct url, metadata mode.
        # Works regardless of whether the author allows third-party downloads.
        $content = @"
name = "$safeName"
filename = "$($Entry.ApiFilename)"
side = "$side"

[download]
hash-format = "sha1"
hash = "$($Entry.Sha1)"
mode = "metadata:curseforge"

[update]
[update.curseforge]
file-id = $($Entry.CfFileId)
project-id = $($Entry.CfProjectId)
"@
    }
    $path = if ($existingPath) { $existingPath } else {
        $targetDir = Join-Path $PackDir "mods"
        if (-not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir | Out-Null }
        Join-Path $targetDir "$($Entry.Slug).pw.toml"
    }
    Write-TextFile -Path $path -Text $content | Out-Null
    return $path
}

# ===================== Run the CF key check up front =====================
# Deliberately BEFORE hashing/fingerprinting: a bad key should be visible in
# two seconds, not after Phase 1 has spent five batches on Modrinth and Phase 2
# has fingerprinted 74 multi-MB jars.
$cfKeyDiag = Test-CfApiKey -Key $CfApiKey -Source $CfApiKeySource
if ($TestCfKey -or $cfKeyDiag.Present) { Write-CfKeyDiagnosis -Diag $cfKeyDiag }

Initialize-CfState
$cfBudget = Get-CfBudgetState
if ($CfStatus -or $TestCfKey -or $cfBudget.InCooldown) {
    Write-Host "`nCurseForge governor" -ForegroundColor Cyan
    Write-Host "  state dir      : $CfStateDir"
    Write-Host "  requests used  : $($cfBudget.InHour)/$CfMaxRequestsPerHour this hour, $($cfBudget.InMinute)/$CfMaxRequestsPerMinute this minute"
    Write-Host "  cached         : $($script:CfCache.Fingerprints.Count) fingerprint match(es), $($script:CfCache.Misses.Count) known-absent, $($script:CfCache.Mods.Count) mod record(s)"
    Write-Host "  strikes        : $($script:CfLedger.Strikes) consecutive rejection(s)"
    if ($cfBudget.InCooldown) {
        Write-Host "  cooldown       : ACTIVE until $($cfBudget.CooldownUntil.ToString('u')) UTC" -ForegroundColor Red
        Write-Host "  reason         : $($script:CfLedger.LastReason)" -ForegroundColor Yellow
        Write-Host "  Phase 2 will use cache only. -CfClearCooldown overrides (understand why it tripped first)." -ForegroundColor Yellow
    } else {
        Write-Host "  cooldown       : none" -ForegroundColor Green
    }
}
if ($CfStatus) { exit 0 }

if ($TestCfKey) {
    if (-not $cfKeyDiag.Present) { exit 1 }
    Write-Host "`nLive probe: GET https://api.curseforge.com/v1/games/432 ..." -ForegroundColor Cyan
    try {
        # Governed like any other call: the probe costs budget, and if CF
        # throttles it the breaker trips here rather than during a real run.
        $probe = Invoke-CfGoverned -Uri "https://api.curseforge.com/v1/games/432" -What "key probe"
        Write-Host "  200 OK - key accepted (game: $($probe.data.name))" -ForegroundColor Green
        exit 0
    }
    catch {
        $msg = "$_"
        if ($msg -like "*CF_HALT*") {
            # Invoke-CfGoverned already classified and reported this, and the
            # reason it recorded carries the real status code. Re-deriving it
            # here is impossible: this is a string throw, not a WebException.
            $reason = $script:CfLedger.LastReason
            Write-Host "  probe rejected: $reason" -ForegroundColor Red
            if ($reason -match '\b403\b') {
                Write-Host "  -> 403 means CurseForge RECOGNISED the key and refused it anyway." -ForegroundColor Yellow
                Write-Host "     That is throttling or entitlement, not a bad credential. If a previous" -ForegroundColor Yellow
                Write-Host "     key returned 401 and this one returns 403, the new key is valid and the" -ForegroundColor Yellow
                Write-Host "     block is attached to something else - most likely your IP." -ForegroundColor Yellow
                Write-Host "     Confirm by running this probe from a different network (phone hotspot)" -ForegroundColor Yellow
                Write-Host "     with -CfClearCooldown. Do NOT retry repeatedly from the blocked network;" -ForegroundColor Yellow
                Write-Host "     that is what extends these blocks." -ForegroundColor Yellow
                Write-Host "     Meanwhile Build-CurseforgeEntries.ps1 needs no API access at all." -ForegroundColor Cyan
            }
            elseif ($reason -match '\b429\b') {
                Write-Host "  -> 429 is an explicit rate limit. Wait out the cooldown; do not retry." -ForegroundColor Yellow
            }
            exit 1
        }
        $code = ""
        $body = ""
        if ($_.Exception.Response) {
            $code = [int]$_.Exception.Response.StatusCode
            try { $body = (New-Object System.IO.StreamReader($_.Exception.Response.GetResponseStream())).ReadToEnd() } catch { }
        }
        Write-Host "  HTTP $code - $($_.Exception.Message)" -ForegroundColor Red
        if ($body) { Write-Host "  body: $body" -ForegroundColor Red }
        if ($code -eq 401) { Write-Host "  -> the key itself is invalid or malformed (see the shape check above)." -ForegroundColor Yellow }
        exit 1
    }
}

if ($cfKeyDiag.Present -and -not $cfKeyDiag.Ok) {
    Write-Host "  Continuing anyway - Phase 2 will very likely 401. Run -TestCfKey to confirm." -ForegroundColor Yellow
}

# ============================ Gather local files ============================
# Each record: FileName, FullPath (may be blank if inventory lacks it and no
# folder given), Sha1 (lowercase).
$localFiles = New-Object System.Collections.Generic.List[object]

if ($InventoryCsv) {
    if (-not (Test-Path $InventoryCsv)) { Write-Error "Inventory not found: $InventoryCsv"; exit 1 }
    foreach ($row in (Import-Csv -Path $InventoryCsv)) {
        if (-not $row.SHA1) { continue }
        $path = $row.FullPath
        if ($InstanceModsFolder) {
            $candidate = Join-Path $InstanceModsFolder $row.FileName
            if (Test-Path $candidate) { $path = $candidate }
        }
        $localFiles.Add([PSCustomObject]@{
            FileName = $row.FileName
            FullPath = $path
            Sha1     = $row.SHA1.ToLower()
        })
    }
    Write-Host "Loaded $($localFiles.Count) hashed jars from inventory" -ForegroundColor Cyan
}
else {
    if (-not (Test-Path $InstanceModsFolder)) { Write-Error "Mods folder not found: $InstanceModsFolder"; exit 1 }
    $jars = Get-ChildItem -Path $InstanceModsFolder -Filter "*.jar" -File
    $n = 0
    foreach ($f in $jars) {
        $n++
        Write-Progress -Activity "Hashing jars" -Status $f.Name -PercentComplete (100 * $n / $jars.Count)
        $localFiles.Add([PSCustomObject]@{
            FileName = $f.Name
            FullPath = $f.FullName
            Sha1     = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA1).Hash.ToLower()
        })
    }
    Write-Progress -Activity "Hashing jars" -Completed
    Write-Host "Hashed $($localFiles.Count) jars live from $InstanceModsFolder" -ForegroundColor Cyan
}

# Warn about duplicate hashes (identical jar present twice under different names)
$dupes = $localFiles | Group-Object Sha1 | Where-Object { $_.Count -gt 1 }
foreach ($d in $dupes) {
    Write-Host "Warning: identical content, multiple files: $(($d.Group | ForEach-Object { $_.FileName }) -join ', ')" -ForegroundColor Yellow
}

# ======================= Phase 1: Modrinth batch by SHA1 =======================
$uniqueHashes = @($localFiles | ForEach-Object { $_.Sha1 } | Sort-Object -Unique)
Write-Host "`nPhase 1: resolving $($uniqueHashes.Count) unique SHA1s against Modrinth (batches of $ChunkSize)..." -ForegroundColor Cyan

$versionByHash = @{}
$chunkIdx = 0
foreach ($chunk in (Split-IntoChunks -Items $uniqueHashes -Size $ChunkSize)) {
    $chunkIdx++
    $bodyJson = @{ hashes = [string[]]$chunk; algorithm = "sha1" } | ConvertTo-Json -Compress
    $resp = Invoke-WithRetry -What "version_files batch $chunkIdx" -Call {
        Invoke-Modrinth -Uri "https://api.modrinth.com/v2/version_files" -Method Post -BodyJson $bodyJson
    }
    $found = 0
    if ($resp) {
        foreach ($prop in $resp.PSObject.Properties) {   # PS 5.1: no -AsHashtable, iterate properties
            $versionByHash[$prop.Name.ToLower()] = $prop.Value
            $found++
        }
    }
    Write-Host "  batch $chunkIdx : $found/$($chunk.Count) matched" -ForegroundColor Green
    Start-Sleep -Seconds $DelaySeconds
}
Write-Host "Modrinth knows $($versionByHash.Count) of $($uniqueHashes.Count) files" -ForegroundColor Cyan

# Project metadata (slug + title) for everything matched
$projectIds = @($versionByHash.Values | ForEach-Object { $_.project_id } | Sort-Object -Unique)
$projectById = @{}
if ($projectIds.Count -gt 0) {
    Write-Host "Fetching metadata for $($projectIds.Count) Modrinth projects..." -ForegroundColor Cyan
    $chunkIdx = 0
    foreach ($chunk in (Split-IntoChunks -Items $projectIds -Size $ChunkSize)) {
        $chunkIdx++
        $idsJson = ConvertTo-Json -InputObject ([string[]]$chunk) -Compress
        $uri = "https://api.modrinth.com/v2/projects?ids=" + [uri]::EscapeDataString($idsJson)
        $projects = Invoke-WithRetry -What "projects batch $chunkIdx" -Call { Invoke-Modrinth -Uri $uri }
        foreach ($p in $projects) { $projectById[$p.id] = $p }
        Start-Sleep -Seconds $DelaySeconds
    }
}

# ==================== Phase 2: CurseForge fingerprints ====================
$unmatchedLocal = @($localFiles | Where-Object { -not $versionByHash.ContainsKey($_.Sha1) })
$cfMatchByFingerprint = @{}
$cfModById = @{}
$fingerprintByFile = @{}

if ($unmatchedLocal.Count -gt 0 -and $CfApiKey) {
    Write-Host "`nPhase 2: fingerprinting $($unmatchedLocal.Count) jars Modrinth didn't recognize..." -ForegroundColor Cyan

    # --- Fingerprint locally (free - no network) ---
    $fingerprintable = New-Object System.Collections.Generic.List[object]
    foreach ($lf in $unmatchedLocal) {
        if (-not $lf.FullPath -or -not (Test-Path $lf.FullPath)) {
            Write-Host "  cannot fingerprint (file not accessible): $($lf.FileName)" -ForegroundColor Yellow
            continue
        }
        $fp = [long][CfFingerprint]::ComputeFromFile($lf.FullPath)
        $fingerprintByFile[$lf.FileName] = $fp
        $fingerprintable.Add($fp)
    }
    $uniqueFps = @($fingerprintable | Sort-Object -Unique)

    # --- Layer 1: serve from cache, and decide what actually needs asking ---
    $missTtl = (Get-Date).ToUniversalTime().AddDays(-$CfMissTtlDays)
    $toQuery = New-Object System.Collections.Generic.List[object]
    foreach ($fp in $uniqueFps) {
        $k = "$fp"
        if ($script:CfCache.Fingerprints.ContainsKey($k)) {
            $cfMatchByFingerprint[[long]$fp] = $script:CfCache.Fingerprints[$k]
            $script:CfCacheHits++
            continue
        }
        if ($script:CfCache.Misses.ContainsKey($k)) {
            $when = $null
            try { $when = [datetime]::Parse($script:CfCache.Misses[$k], $null, [System.Globalization.DateTimeStyles]::RoundtripKind) } catch { }
            if ($when -and $when -gt $missTtl) { $script:CfCacheHits++; continue }  # known-absent, still fresh
        }
        [void]$toQuery.Add($fp)
    }
    Write-Host "  cache: $($script:CfCacheHits) of $($uniqueFps.Count) fingerprints already known, $($toQuery.Count) need CurseForge" -ForegroundColor DarkGray

    $budget = Get-CfBudgetState
    if ($budget.InCooldown) {
        Write-Host "  CurseForge is in cooldown until $($budget.CooldownUntil.ToString('u')) UTC (reason: $($script:CfLedger.LastReason))." -ForegroundColor Yellow
        Write-Host "  Skipping live lookups; cached results still applied. Use -CfClearCooldown to override deliberately." -ForegroundColor Yellow
        $toQuery.Clear()
    }
    elseif ($toQuery.Count -gt 0) {
        $planned = [Math]::Ceiling($toQuery.Count / [double]$ChunkSize) + 2   # +2 = expected /v1/mods calls
        Write-Host "  budget: ~$planned request(s) planned, $($budget.HourRemaining) of $CfMaxRequestsPerHour remaining this hour" -ForegroundColor DarkGray

        # CANARY: if the breaker has ever tripped, the first request after a
        # cooldown expires must be the cheapest endpoint available, not a POST
        # carrying 74 fingerprints. If access is still blocked we want that to
        # cost one trivial GET and re-trip immediately, rather than throwing the
        # heavy endpoints at a wall that is demonstrably still there.
        if ([int]$script:CfLedger.Strikes -gt 0) {
            Write-Host "  canary: $($script:CfLedger.Strikes) prior strike(s), verifying access with a single cheap request..." -ForegroundColor DarkGray
            try {
                Invoke-CfGoverned -Uri "https://api.curseforge.com/v1/games/432" -What "canary" | Out-Null
                Write-Host "  canary passed - proceeding" -ForegroundColor Green
            }
            catch {
                Write-Host "  canary failed - CurseForge is still refusing us. Skipping live lookups." -ForegroundColor Yellow
                $toQuery.Clear()
            }
        }
    }

    # Phase 2 is OPTIONAL enrichment. Throttling, an outage or a bad key must
    # not throw away Phase 1's resolutions, the links file or the drift report.
    # Anything learned before the stop is cached, so the next run resumes.
    try {
        $chunkIdx = 0
        foreach ($chunk in (Split-IntoChunks -Items @($toQuery) -Size $ChunkSize)) {
            $chunkIdx++
            # Element-wise rather than a bulk [long[]] cast: $chunk arrives via
            # a List -> array -> range-index chain, and a bulk cast of that is
            # exactly the kind of thing that fails with an opaque type error.
            $fpArray = New-Object 'System.Int64[]' $chunk.Count
            for ($j = 0; $j -lt $chunk.Count; $j++) { $fpArray[$j] = [long]$chunk[$j] }
            $bodyJson = @{ fingerprints = $fpArray } | ConvertTo-Json -Compress
            $resp = Invoke-CfGoverned -Uri "https://api.curseforge.com/v1/fingerprints/432" `
                                      -Method Post -BodyJson $bodyJson -What "fingerprints batch $chunkIdx"
            $seen = @{}
            if ($resp.data -and $resp.data.exactMatches) {
                foreach ($m in $resp.data.exactMatches) {
                    # Normalise to a small stable shape: the raw CF payload is
                    # large and its schema is not ours to depend on.
                    $entry = [PSCustomObject]@{
                        ModId       = [long]$m.id
                        FileId      = [long]$m.file.id
                        FileName    = $m.file.fileName
                        DisplayName = $m.file.displayName
                        DownloadUrl = $m.file.downloadUrl
                        Fingerprint = [long]$m.file.fileFingerprint
                    }
                    $cfMatchByFingerprint[$entry.Fingerprint] = $entry
                    $script:CfCache.Fingerprints["$($entry.Fingerprint)"] = $entry
                    $seen[$entry.Fingerprint] = $true
                }
            }
            # Negative-cache the rest of this batch so we never ask again.
            foreach ($fp in $chunk) {
                if (-not $seen.ContainsKey([long]$fp)) {
                    $script:CfCache.Misses["$fp"] = (Get-Date).ToUniversalTime().ToString("o")
                }
            }
            Save-CfCache
            Write-Host "  batch $chunkIdx : $($seen.Count)/$($chunk.Count) exact matches" -ForegroundColor Green
        }

        # --- Mod names/slugs, also cache-first ---
        $needModsSet = @{}
        foreach ($m in $cfMatchByFingerprint.Values) {
            $k = "$($m.ModId)"
            if ($script:CfCache.Mods.ContainsKey($k)) { $cfModById[[long]$m.ModId] = $script:CfCache.Mods[$k] }
            else { $needModsSet[[long]$m.ModId] = $true }   # hashtable dedupe: List.Contains on boxed longs is fragile
        }
        $needMods = @($needModsSet.Keys)
        if ($needMods.Count -gt 0 -and -not (Get-CfBudgetState).InCooldown) {
            Write-Host "Fetching metadata for $($needMods.Count) CurseForge mods..." -ForegroundColor Cyan
            foreach ($chunk in (Split-IntoChunks -Items @($needMods) -Size 50)) {
                $idArray = New-Object 'System.Int64[]' $chunk.Count
                for ($j = 0; $j -lt $chunk.Count; $j++) { $idArray[$j] = [long]$chunk[$j] }
                $bodyJson = @{ modIds = $idArray } | ConvertTo-Json -Compress
                $resp = Invoke-CfGoverned -Uri "https://api.curseforge.com/v1/mods" `
                                          -Method Post -BodyJson $bodyJson -What "mods batch"
                foreach ($m in $resp.data) {
                    $entry = [PSCustomObject]@{ Slug = $m.slug; Name = $m.name }
                    $cfModById[[long]$m.id] = $entry
                    $script:CfCache.Mods["$($m.id)"] = $entry
                }
                Save-CfCache
            }
        }
    }
    catch {
        $msg = "$_"
        if ($msg -like "*CF_HALT*") {
            Write-Host "`nPhase 2 stopped early: $msg" -ForegroundColor Yellow
            Write-Host "Everything resolved before the stop has been cached; re-running later resumes from there." -ForegroundColor Yellow
        }
        else {
            Write-Host "`nPhase 2 FAILED (CurseForge): $msg" -ForegroundColor Red
            # A bare message is not diagnosable. Non-HTTP failures here are
            # local bugs, and the line number is the whole answer.
            if ($_.InvocationInfo -and $_.InvocationInfo.PositionMessage) {
                Write-Host $_.InvocationInfo.PositionMessage -ForegroundColor DarkGray
            }
            if ($_.ScriptStackTrace) {
                Write-Host "  stack:" -ForegroundColor DarkGray
                foreach ($l in ($_.ScriptStackTrace -split "`n")) { Write-Host "    $l" -ForegroundColor DarkGray }
            }
            Write-Host "  exception type: $($_.Exception.GetType().FullName)" -ForegroundColor DarkGray
            if (-not $cfKeyDiag.Ok) {
                Write-Host "The key shape check above already flagged a problem - fix that first." -ForegroundColor Yellow
            }
        }
        Write-Host "Continuing with Modrinth results only; unresolved jars will report UNMATCHED." -ForegroundColor Yellow
    }
    Save-CfCache
    Write-Host "  CF requests used this run: $($script:CfCallsThisRun)" -ForegroundColor DarkGray
}
elseif ($unmatchedLocal.Count -gt 0) {
    Write-Host "`nPhase 2 SKIPPED: $($unmatchedLocal.Count) files not on Modrinth and no CF_API_KEY available" -ForegroundColor Yellow
}

# ============================ Assemble results ============================
$results = New-Object System.Collections.Generic.List[object]
foreach ($lf in $localFiles) {
    if ($versionByHash.ContainsKey($lf.Sha1)) {
        $v = $versionByHash[$lf.Sha1]
        # THE key line: pick the file whose sha1 equals OUR file's sha1 - never
        # the "primary" file. This is what stops datapack projects (Structory,
        # Structory: Towers) resolving to their .zip when the installed file is
        # the NeoForge .jar attached to the same version.
        $file = $v.files | Where-Object { $_.hashes.sha1 -ieq $lf.Sha1 } | Select-Object -First 1
        if (-not $file) { $file = $v.files | Where-Object { $_.primary } | Select-Object -First 1 }
        if (-not $file) { $file = $v.files | Select-Object -First 1 }
        $proj = $projectById[$v.project_id]
        $slug = if ($proj) { $proj.slug } else { $v.project_id }
        $name = if ($proj -and $proj.title) { $proj.title } else { $slug }
        $results.Add([PSCustomObject]@{
            FileName          = $lf.FileName
            Status            = "MATCHED_MODRINTH"
            Source            = "modrinth"
            Slug              = $slug
            Name              = $name
            ModrinthProjectId = $v.project_id
            ModrinthVersionId = $v.id
            VersionNumber     = $v.version_number
            CfProjectId       = $null
            CfFileId          = $null
            ApiFilename       = $file.filename
            FilenameAgrees    = ($file.filename -eq $lf.FileName)
            DownloadUrl       = $file.url
            Sha1              = $lf.Sha1
            Url               = "https://modrinth.com/mod/$slug/version/$($v.id)"
        })
    }
    elseif ($fingerprintByFile.ContainsKey($lf.FileName) -and $cfMatchByFingerprint.ContainsKey($fingerprintByFile[$lf.FileName])) {
        # $m is the normalised entry written by Phase 2 (or restored from the
        # disk cache) - NOT the raw CurseForge payload.
        $m = $cfMatchByFingerprint[$fingerprintByFile[$lf.FileName]]
        $mod = $cfModById[[long]$m.ModId]
        $slug = if ($mod) { $mod.Slug } else { "cf-$($m.ModId)" }
        $name = if ($mod -and $mod.Name) { $mod.Name } else { $slug }
        $results.Add([PSCustomObject]@{
            FileName          = $lf.FileName
            Status            = "MATCHED_CURSEFORGE"
            Source            = "curseforge"
            Slug              = $slug
            Name              = $name
            ModrinthProjectId = $null
            ModrinthVersionId = $null
            VersionNumber     = $m.DisplayName
            CfProjectId       = [long]$m.ModId
            CfFileId          = [long]$m.FileId
            ApiFilename       = $m.FileName
            FilenameAgrees    = ($m.FileName -eq $lf.FileName)
            DownloadUrl       = $m.DownloadUrl
            Sha1              = $lf.Sha1
            Url               = "https://www.curseforge.com/minecraft/mc-mods/$slug/files/$($m.FileId)"
        })
    }
    else {
        $results.Add([PSCustomObject]@{
            FileName          = $lf.FileName
            Status            = "UNMATCHED"
            Source            = ""
            Slug              = ""
            Name              = ""
            ModrinthProjectId = $null
            ModrinthVersionId = $null
            VersionNumber     = ""
            CfProjectId       = $null
            CfFileId          = $null
            ApiFilename       = ""
            FilenameAgrees    = $null
            DownloadUrl       = ""
            Sha1              = $lf.Sha1
            Url               = ""
        })
    }
}

$results | Export-Csv -Path $OutputCsv -NoTypeInformation

# ======================= Regenerated ground-truth links =======================
$sb = New-Object System.Text.StringBuilder
[void]$sb.AppendLine("##Modrinth")
[void]$sb.AppendLine("")
foreach ($r in ($results | Where-Object { $_.Status -eq "MATCHED_MODRINTH" } | Sort-Object Slug)) {
    [void]$sb.AppendLine($r.Url)
}
[void]$sb.AppendLine("")
[void]$sb.AppendLine("##Curseforge")
[void]$sb.AppendLine("")
foreach ($r in ($results | Where-Object { $_.Status -eq "MATCHED_CURSEFORGE" } | Sort-Object Slug)) {
    [void]$sb.AppendLine($r.Url)
}
$unmatchedRows = @($results | Where-Object { $_.Status -eq "UNMATCHED" })
if ($unmatchedRows.Count -gt 0) {
    [void]$sb.AppendLine("")
    [void]$sb.AppendLine("## Unmatched local files (self-built dev jars, hand-patched files, or missing CF key) - handle manually:")
    foreach ($r in $unmatchedRows) { [void]$sb.AppendLine("# $($r.FileName)") }
}
$linksPath = Write-TextFile -Path $ResolvedLinksOut -Text $sb.ToString()

# ============================== Drift report ==============================
if ($LinksFile -and (Test-Path $LinksFile)) {
    Write-Host "`nComparing against old links file..." -ForegroundColor Cyan
    $oldMrSlugs = @{}; $oldMrVersionSeg = @{}; $oldCf = @{}
    foreach ($rawLine in Get-Content -Path $LinksFile) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -match 'modrinth\.com/(?:mod|datapack|resourcepack|shader|plugin)/([^/]+)/version/([^/?]+)') {
            $oldMrSlugs[$Matches[1]] = $true
            $oldMrVersionSeg[$Matches[1]] = $Matches[2]
        }
        elseif ($line -match 'curseforge\.com/minecraft/mc-mods/([^/]+)/files/(\d+)') {
            $oldCf[$Matches[1]] = $Matches[2]
        }
    }
    $drift = New-Object System.Collections.Generic.List[object]
    $installedMrSlugs = @{}
    foreach ($r in ($results | Where-Object { $_.Status -eq "MATCHED_MODRINTH" })) {
        $installedMrSlugs[$r.Slug] = $r
        if ($oldMrSlugs.ContainsKey($r.Slug)) {
            $seg = $oldMrVersionSeg[$r.Slug]
            # If the old link used an opaque version ID and it differs from the
            # installed version's ID, the link points at a different build.
            if ($seg -ne $r.ModrinthVersionId -and $seg -ne $r.VersionNumber) {
                $drift.Add([PSCustomObject]@{ Kind = "VERSION_DIFFERS"; Slug = $r.Slug; Detail = "link says '$seg', installed is '$($r.VersionNumber)' ($($r.ModrinthVersionId))"; CorrectUrl = $r.Url })
            }
        }
        else {
            $drift.Add([PSCustomObject]@{ Kind = "INSTALLED_NOT_IN_LINKS"; Slug = $r.Slug; Detail = $r.FileName; CorrectUrl = $r.Url })
        }
    }
    $installedCfSlugs = @{}
    foreach ($r in ($results | Where-Object { $_.Status -eq "MATCHED_CURSEFORGE" })) {
        $installedCfSlugs[$r.Slug] = $r
        if ($oldCf.ContainsKey($r.Slug)) {
            if ($oldCf[$r.Slug] -ne "$($r.CfFileId)") {
                $drift.Add([PSCustomObject]@{ Kind = "VERSION_DIFFERS"; Slug = $r.Slug; Detail = "link file $($oldCf[$r.Slug]), installed file $($r.CfFileId)"; CorrectUrl = $r.Url })
            }
        }
        elseif (-not $installedMrSlugs.ContainsKey($r.Slug)) {
            $drift.Add([PSCustomObject]@{ Kind = "INSTALLED_NOT_IN_LINKS"; Slug = $r.Slug; Detail = $r.FileName; CorrectUrl = $r.Url })
        }
    }
    foreach ($slug in $oldMrSlugs.Keys) {
        if (-not $installedMrSlugs.ContainsKey($slug) -and -not $installedCfSlugs.ContainsKey($slug)) {
            $drift.Add([PSCustomObject]@{ Kind = "LINKED_NOT_INSTALLED"; Slug = $slug; Detail = "modrinth link has no matching installed file"; CorrectUrl = "" })
        }
    }
    foreach ($slug in $oldCf.Keys) {
        if (-not $installedCfSlugs.ContainsKey($slug) -and -not $installedMrSlugs.ContainsKey($slug)) {
            $drift.Add([PSCustomObject]@{ Kind = "LINKED_NOT_INSTALLED"; Slug = $slug; Detail = "curseforge link has no matching installed file (may be installed via its Modrinth release instead - check the Modrinth section of the resolved links)"; CorrectUrl = "" })
        }
    }
    $drift | Export-Csv -Path $DriftCsv -NoTypeInformation
    Write-Host "Drift report: $($drift.Count) findings -> $DriftCsv" -ForegroundColor Cyan
}

# ================================ Apply ================================
if ($Apply) {
    Write-Host "`nWriting pw.toml entries..." -ForegroundColor Cyan
    foreach ($r in ($results | Where-Object { $_.Status -like "MATCHED_*" })) {
        $tomlPath = Set-PwToml -Entry $r -PackDir $PackDir
        Write-Host "  $($r.Slug) -> $tomlPath" -ForegroundColor DarkGray
    }
    Write-Host "Don't forget: packwiz refresh" -ForegroundColor Cyan
}

# ================================ Summary ================================
Write-Host "`n--- Summary ---" -ForegroundColor Cyan
foreach ($c in ($results | Group-Object Status | Sort-Object Name)) { Write-Host "  $($c.Name): $($c.Count)" }
$renamed = @($results | Where-Object { $_.FilenameAgrees -eq $false })
if ($renamed.Count -gt 0) {
    Write-Host "`n  Note: $($renamed.Count) file(s) matched by hash but the platform filename differs from the local one" -ForegroundColor Yellow
    Write-Host "  (local file was renamed - the pw.toml uses the platform filename, which is what packwiz will download):" -ForegroundColor Yellow
    foreach ($r in $renamed) { Write-Host "    $($r.FileName)  ->  $($r.ApiFilename)" -ForegroundColor Yellow }
}
Write-Host "`nReport:         $OutputCsv"
Write-Host "Resolved links: $linksPath"

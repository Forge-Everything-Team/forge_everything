<#
.SYNOPSIS
    Shared configuration loader. Dot-sourced by every script in this folder so
    that folder locations live in secrets.local.env instead of being retyped on
    every invocation.

.DESCRIPTION
    This file is not run directly. Each script dot-sources it near the top:

        . (Join-Path $PSScriptRoot "PackConfig.ps1")
        Initialize-PackConfig -SecretsFile $SecretsFile -ScriptRoot $PSScriptRoot

    after which Get-PackSetting reads any key out of the loaded environment.

    RESOLUTION ORDER (first hit wins), applied per setting:

        1. the explicit -Parameter on the command line
        2. a real process environment variable of the same name
        3. the key in secrets.local.env
        4. the script's own built-in default

    Rule 1 is why every call site is guarded by
    $PSBoundParameters.ContainsKey(...): PowerShell cannot otherwise tell a
    parameter you typed from a default it filled in, and without the guard the
    env file would silently override the flag you just passed.

    Rule 2 exists because the resolver already honoured $env:CF_API_KEY before
    the secrets file, and reversing that mid-pipeline would be a surprise.

    RELATIVE PATHS IN THE SECRETS FILE resolve against the folder holding the
    secrets file, NOT against the current directory. A path written in a config
    file means the same thing regardless of where you happen to be standing
    when you run the script. Paths typed on the command line keep normal
    PowerShell behaviour and resolve against the current directory.

    ${VAR} REFERENCES are expanded against keys defined earlier in the file, so
    you can define a root once:

        MODPACK_ROOT=C:\Users\Terra\projects\Minecraft Modpacks\forge_everything
        PACK_DIR=${MODPACK_ROOT}\packwiz

    Only the braced form is expanded, and never for keys whose names end in
    _KEY, _TOKEN, _SECRET or _PASSWORD. That is deliberate: a bcrypt-format
    CurseForge key is literally $2a$10$IWDpXbn..., and any scheme that treated
    a bare $NAME as a reference would eat it alive. Braces plus the name-suffix
    exclusion means a secret can never be mangled by expansion.

.NOTES
    PS 5.1 compatible. No ConvertFrom-Json -AsHashtable, no ?? operator,
    no ternary.
#>

$script:PackConfigValues      = @{}
$script:PackConfigSecretsFile = $null
$script:PackConfigLoaded      = $false
# Captured at dot-source time. Whether $PSScriptRoot inside a dot-sourced
# function reports the defining file or the calling one is a detail nobody
# should have to remember, so it is pinned here once and never read again from
# inside a function body.
$script:PackConfigRoot        = $PSScriptRoot

function Resolve-PackSecretsFile {
    <#
    .SYNOPSIS
        Decides which secrets file to read: -SecretsFile, else
        $env:FORGE_EVERYTHING_SECRETS, else secrets.local.env beside the scripts.
    #>
    param([string]$SecretsFile)

    if ($SecretsFile) { return $SecretsFile }
    if ($env:FORGE_EVERYTHING_SECRETS) { return $env:FORGE_EVERYTHING_SECRETS }

    $root = $script:PackConfigRoot
    if (-not $root) { $root = (Get-Location).Path }
    return (Join-Path $root "secrets.local.env")
}

function Initialize-PackConfig {
    <#
    .SYNOPSIS
        Parses secrets.local.env into memory. Safe to call when the file does
        not exist - every script still works from parameters alone.
    #>
    param(
        [string]$SecretsFile,
        # Callers pass their own $PSScriptRoot. Read from the caller's body it
        # is unambiguously the calling script's folder, which is a stronger
        # guarantee than anything this file can work out about itself.
        [string]$ScriptRoot,
        [switch]$Quiet
    )

    if ($ScriptRoot) { $script:PackConfigRoot = $ScriptRoot }

    $path = Resolve-PackSecretsFile -SecretsFile $SecretsFile
    $script:PackConfigSecretsFile = $path
    $script:PackConfigValues = @{}
    $script:PackConfigLoaded = $true

    if (-not (Test-Path -LiteralPath $path)) {
        if (-not $Quiet) {
            Write-Host "No secrets file at $path - using parameters and built-in defaults only." -ForegroundColor DarkGray
        }
        return
    }

    $lineNo = 0
    foreach ($raw in (Get-Content -LiteralPath $path)) {
        $lineNo++
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }

        # Tolerate the shell-ism 'export KEY=VALUE' so a file can be shared
        # with a bash-based workflow without editing.
        if ($line -match '^export\s+(.+)$') { $line = $Matches[1].Trim() }

        $idx = $line.IndexOf("=")
        if ($idx -lt 1) {
            Write-Host "  secrets.local.env line ${lineNo}: no '=' found, ignoring: $line" -ForegroundColor Yellow
            continue
        }

        $key = $line.Substring(0, $idx).Trim()
        $val = $line.Substring($idx + 1).Trim()

        # Strip ONE matching outer quote pair only. Chained .Trim('"').Trim("'")
        # would also eat a quote that is genuinely part of the value.
        if ($val.Length -ge 2) {
            if (($val.StartsWith('"') -and $val.EndsWith('"')) -or
                ($val.StartsWith("'") -and $val.EndsWith("'"))) {
                $val = $val.Substring(1, $val.Length - 2)
            }
        }

        if ($key -notmatch '_(KEY|TOKEN|SECRET|PASSWORD)$') {
            $val = Expand-PackReference -Value $val
        }

        $script:PackConfigValues[$key] = $val
    }

    if (-not $Quiet) {
        Write-Host "Loaded $($script:PackConfigValues.Count) setting(s) from $path" -ForegroundColor DarkGray
    }
}

function Expand-PackReference {
    <#
    .SYNOPSIS
        Expands ${NAME} against already-parsed keys, then already-set process
        environment variables. Unknown names are left untouched rather than
        blanked, so a typo is visible in the resulting path instead of
        silently producing a shorter, wrong one.
    #>
    param([string]$Value)

    if (-not $Value -or $Value -notmatch '\$\{') { return $Value }

    $evaluator = {
        param($m)
        $name = $m.Groups[1].Value
        if ($script:PackConfigValues.ContainsKey($name)) { return $script:PackConfigValues[$name] }
        $fromEnv = [System.Environment]::GetEnvironmentVariable($name)
        if ($fromEnv) { return $fromEnv }
        return $m.Value
    }
    return [regex]::Replace($Value, '\$\{([A-Za-z_][A-Za-z0-9_]*)\}', $evaluator)
}

function Get-PackSetting {
    <#
    .SYNOPSIS
        Returns a configured value: process env var, then secrets file, then
        the supplied default.

    .PARAMETER AsPath
        Treat the value as a filesystem path: a relative value coming from the
        secrets file is resolved against the secrets file's own folder. Values
        coming from -Default (i.e. the script's own default) are left alone.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$Default = $null,
        [switch]$AsPath
    )

    if (-not $script:PackConfigLoaded) { Initialize-PackConfig -Quiet }

    $fromEnv = [System.Environment]::GetEnvironmentVariable($Name)
    if ($fromEnv) {
        if ($AsPath) { return (Expand-PackReference -Value $fromEnv) }
        return $fromEnv
    }

    if ($script:PackConfigValues.ContainsKey($Name)) {
        $v = $script:PackConfigValues[$Name]
        if ($v) {
            if ($AsPath) { return (Resolve-PackRelativePath -Path $v) }
            return $v
        }
    }

    return $Default
}

function Resolve-PackRelativePath {
    <#
    .SYNOPSIS
        Anchors a relative path from the secrets file to the secrets file's
        directory. UNC paths (\\SERVER\share) and rooted paths pass through.
    #>
    param([string]$Path)

    if (-not $Path) { return $Path }
    if ([System.IO.Path]::IsPathRooted($Path)) { return $Path }
    if ($Path.StartsWith("\\") -or $Path.StartsWith("//")) { return $Path }

    $baseDir = $null
    if ($script:PackConfigSecretsFile) {
        $baseDir = Split-Path -Parent $script:PackConfigSecretsFile
    }
    if (-not $baseDir) { $baseDir = $script:PackConfigRoot }
    if (-not $baseDir) { $baseDir = (Get-Location).Path }

    return [System.IO.Path]::GetFullPath((Join-Path $baseDir $Path))
}

function Get-PackFolderSetting {
    <#
    .SYNOPSIS
        A folder setting that can also be derived from a parent folder key.
        INSTANCE_MODS_FOLDER, if unset, is INSTANCE_ROOT\mods - so pointing at
        one instance root configures mods, resourcepacks, shaderpacks and the
        rest in a single line.

    .EXAMPLE
        Get-PackFolderSetting -Name INSTANCE_MODS_FOLDER -ParentName INSTANCE_ROOT -ChildFolder mods
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [string]$ParentName,
        [string]$ChildFolder,
        [string]$Default = $null
    )

    $explicit = Get-PackSetting -Name $Name -AsPath
    if ($explicit) { return $explicit }

    if ($ParentName -and $ChildFolder) {
        $parent = Get-PackSetting -Name $ParentName -AsPath
        if ($parent) { return (Join-Path $parent $ChildFolder) }
    }

    return $Default
}

function Get-PackOutputPath {
    <#
    .SYNOPSIS
        Resolves an output file path, honouring OUTPUT_DIR.

    .DESCRIPTION
        Precedence: the setting's own key (e.g. INVENTORY_CSV), then
        OUTPUT_DIR\<DefaultFileName>, then the plain default. The parent
        directory is created if missing, because Export-Csv failing on a
        not-yet-created reports folder is a pointless way to lose a run that
        already did all the hashing.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$DefaultFileName,
        [string]$Default
    )

    if (-not $Default) { $Default = ".\$DefaultFileName" }

    $result = Get-PackSetting -Name $Name -AsPath
    if (-not $result) {
        $outDir = Get-PackSetting -Name "OUTPUT_DIR" -AsPath
        if ($outDir) { $result = Join-Path $outDir $DefaultFileName }
    }
    if (-not $result) { return $Default }

    $parent = Split-Path -Parent $result
    if ($parent -and -not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    return $result
}

function ConvertTo-PackCsvField {
    <#
    .SYNOPSIS
        Quotes and escapes one CSV field. Always quotes - a value that gains a
        comma later should not silently change the shape of the file.
    #>
    param([string]$Value)

    if ($null -eq $Value) { $Value = "" }
    return '"' + ($Value -replace '"', '""') + '"'
}

function Write-PackTextFile {
    <#
    .SYNOPSIS
        Writes text and confirms it landed.

    .DESCRIPTION
        Set-Content can fail silently under some conditions, which turns a bad
        run into a stale file that looks fine. WriteAllText plus an existence
        check makes the failure loud. Creates the parent directory if needed.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [Parameter(Mandatory = $true)][AllowEmptyString()][string]$Content
    )

    $dir = Split-Path -Parent $Path
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding($false)))

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Write failed (file not present afterwards): $Path"
    }
}

function Write-PackCsvFile {
    <#
    .SYNOPSIS
        Writes objects to CSV via StringBuilder rather than Export-Csv.

    .DESCRIPTION
        Export-Csv infers columns from the first object, which quietly drops
        properties when later rows are shaped differently. Passing -Columns
        explicitly means the header is a contract, not a guess.

        An empty row set still writes a header-only file. A missing file then
        always means a bug rather than "there was nothing to report".

    .PARAMETER Label
        Shown in the console tally. Defaults to the file name.
    #>
    param(
        [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory = $true)][string[]]$Columns,
        [Parameter(Mandatory = $true)][string]$Path,
        [string]$Label,
        [switch]$Quiet
    )

    if (-not $Label) { $Label = Split-Path -Leaf $Path }

    $sb = New-Object System.Text.StringBuilder
    $header = @()
    foreach ($c in $Columns) { $header += (ConvertTo-PackCsvField -Value $c) }
    [void]$sb.AppendLine(($header -join ','))

    $count = 0
    if ($Rows) {
        foreach ($row in $Rows) {
            if ($null -eq $row) { continue }
            $fields = @()
            foreach ($c in $Columns) {
                $v = $null
                if ($row.PSObject.Properties[$c]) { $v = $row.PSObject.Properties[$c].Value }
                if ($null -eq $v) { $v = "" }
                $fields += (ConvertTo-PackCsvField -Value ([string]$v))
            }
            [void]$sb.AppendLine(($fields -join ','))
            $count++
        }
    }

    Write-PackTextFile -Path $Path -Content $sb.ToString()
    if (-not $Quiet) { Write-Host ("  {0,-34} {1} row(s)" -f $Label, $count) -ForegroundColor DarkGray }
    return $count
}

function Get-PackOutputFolder {
    <#
    .SYNOPSIS
        The folder equivalent of Get-PackOutputPath, for scripts that emit a
        set of files rather than one.

    .DESCRIPTION
        Precedence: the setting's own key, then OUTPUT_DIR\<DefaultFolderName>,
        then .\<DefaultFolderName>. The folder itself is created.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [Parameter(Mandatory = $true)][string]$DefaultFolderName
    )

    $result = Get-PackSetting -Name $Name -AsPath
    if (-not $result) {
        $outDir = Get-PackSetting -Name "OUTPUT_DIR" -AsPath
        if ($outDir) { $result = Join-Path $outDir $DefaultFolderName }
    }
    if (-not $result) {
        $result = Join-Path (Get-Location).ProviderPath $DefaultFolderName
    }

    if (-not (Test-Path -LiteralPath $result)) {
        New-Item -ItemType Directory -Path $result -Force | Out-Null
    }
    return $result
}

function Show-PackConfigSummary {
    <#
    .SYNOPSIS
        Prints the resolved paths a script is about to use. Cheap, and it
        removes the entire class of "which folder did it actually read?"
        confusion when a run produces surprising output.
    #>
    param(
        [Parameter(Mandatory = $true)][hashtable]$Values,
        [string]$Title = "Resolved paths"
    )

    Write-Host "`n--- $Title ---" -ForegroundColor DarkCyan
    foreach ($k in ($Values.Keys | Sort-Object)) {
        $v = $Values[$k]
        if (-not $v) { $v = "<not set>" }
        Write-Host ("  {0,-28} {1}" -f $k, $v) -ForegroundColor DarkGray
    }
}

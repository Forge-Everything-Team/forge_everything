<#
.SYNOPSIS
    Lists every file actually present in the modpack instance, organized by type,
    as a lightweight double-check against what links_to_mods.txt / the processing
    report say should be there.

.DESCRIPTION
    No hashing, no API calls - just a fast directory listing across whichever
    instance folders you point it at (mods, resourcepacks, shaderpacks, datapacks,
    plugins). Useful as a quick sanity reference: eyeball it directly, grep it for
    a specific mod, or diff it against mod-list-processing-report.csv's Filename
    column to spot anything unaccounted for at a glance.

    Only scans folders you actually provide a path for - all parameters are
    optional except at least one of them being set.

    CONFIGURATION
    Every folder below can be set once in secrets.local.env instead of being
    typed on each run:

        INSTANCE_ROOT=C:\Users\Terra\AppData\Roaming\ModrinthApp\profiles\NeoForge 1.21.1
        INSTANCE_MODS_FOLDER=${INSTANCE_ROOT}\mods          # optional override
        INSTANCE_RESOURCEPACKS_FOLDER=...                   # optional override
        OUTPUT_DIR=.\reports

    INSTANCE_ROOT alone is usually enough: each folder defaults to the
    conventional subfolder under it, and only the ones that actually exist are
    scanned. A command-line parameter always beats the file.

.PARAMETER SecretsFile
    Path to the settings file. Defaults to $env:FORGE_EVERYTHING_SECRETS, else
    secrets.local.env beside this script.

.PARAMETER InstanceModsFolder
    Path to the mods folder (scanned for *.jar)

.PARAMETER InstanceResourcepacksFolder
    Path to the resourcepacks folder (scanned for *.zip)

.PARAMETER InstanceShaderpacksFolder
    Path to the shaderpacks folder (scanned for *.zip)

.PARAMETER InstanceDatapacksFolder
    Path to wherever your datapack-loader expects zips (scanned for *.zip)

.PARAMETER InstancePluginsFolder
    Path to a plugins folder, if applicable (scanned for *.jar)

.PARAMETER OutputCsv
    Where to write the results. Default: instance-file-list.csv in the current dir.

.EXAMPLE
    # Everything from secrets.local.env
    .\Get-InstanceFileList.ps1

.EXAMPLE
    .\Get-InstanceFileList.ps1 -InstanceModsFolder "C:\...\mods" -InstanceResourcepacksFolder "C:\...\resourcepacks"
#>

param(
    [string]$InstanceModsFolder,
    [string]$InstanceResourcepacksFolder,
    [string]$InstanceShaderpacksFolder,
    [string]$InstanceDatapacksFolder,
    [string]$InstancePluginsFolder,

    [string]$OutputCsv = ".\instance-file-list.csv",

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

# $PSBoundParameters.ContainsKey is the only way to distinguish "the user typed
# this flag" from "PowerShell filled in the default", and it is what keeps a
# command-line argument winning over the settings file.
#
# A folder is "explicit" if you named it directly (parameter or its own key) and
# "derived" if it only exists because INSTANCE_ROOT was set. The difference
# matters at scan time: a missing folder you asked for by name is worth a
# warning, whereas a missing plugins/ under an instance root is just a client
# instance being a client instance, and warning about it every run trains you to
# ignore the warnings that matter.
#
# Field names avoid Key/Value/Count deliberately: PowerShell resolves member
# access on a Hashtable against the real .NET members before falling back to
# entry lookup, so a field called Key is a trap waiting for whoever edits this
# next.
$explicit = @{}
foreach ($pair in @(
    @{ ParamName = 'InstanceModsFolder';          EnvKey = 'INSTANCE_MODS_FOLDER';          Kind = 'mod' }
    @{ ParamName = 'InstanceResourcepacksFolder'; EnvKey = 'INSTANCE_RESOURCEPACKS_FOLDER'; Kind = 'resourcepack' }
    @{ ParamName = 'InstanceShaderpacksFolder';   EnvKey = 'INSTANCE_SHADERPACKS_FOLDER';   Kind = 'shader' }
    @{ ParamName = 'InstanceDatapacksFolder';     EnvKey = 'INSTANCE_DATAPACKS_FOLDER';     Kind = 'datapack' }
    @{ ParamName = 'InstancePluginsFolder';       EnvKey = 'INSTANCE_PLUGINS_FOLDER';       Kind = 'plugin' }
)) {
    $explicit[$pair.Kind] = ($PSBoundParameters.ContainsKey($pair.ParamName) -or [bool](Get-PackSetting -Name $pair.EnvKey))
}

if (-not $PSBoundParameters.ContainsKey('InstanceModsFolder')) {
    $InstanceModsFolder = Get-PackFolderSetting -Name INSTANCE_MODS_FOLDER -ParentName INSTANCE_ROOT -ChildFolder "mods" -Default $InstanceModsFolder
}
if (-not $PSBoundParameters.ContainsKey('InstanceResourcepacksFolder')) {
    $InstanceResourcepacksFolder = Get-PackFolderSetting -Name INSTANCE_RESOURCEPACKS_FOLDER -ParentName INSTANCE_ROOT -ChildFolder "resourcepacks" -Default $InstanceResourcepacksFolder
}
if (-not $PSBoundParameters.ContainsKey('InstanceShaderpacksFolder')) {
    $InstanceShaderpacksFolder = Get-PackFolderSetting -Name INSTANCE_SHADERPACKS_FOLDER -ParentName INSTANCE_ROOT -ChildFolder "shaderpacks" -Default $InstanceShaderpacksFolder
}
if (-not $PSBoundParameters.ContainsKey('InstanceDatapacksFolder')) {
    $InstanceDatapacksFolder = Get-PackFolderSetting -Name INSTANCE_DATAPACKS_FOLDER -ParentName INSTANCE_ROOT -ChildFolder "datapacks" -Default $InstanceDatapacksFolder
}
if (-not $PSBoundParameters.ContainsKey('InstancePluginsFolder')) {
    $InstancePluginsFolder = Get-PackFolderSetting -Name INSTANCE_PLUGINS_FOLDER -ParentName INSTANCE_ROOT -ChildFolder "plugins" -Default $InstancePluginsFolder
}
if (-not $PSBoundParameters.ContainsKey('OutputCsv')) {
    $OutputCsv = Get-PackOutputPath -Name INSTANCE_FILE_LIST_CSV -DefaultFileName "instance-file-list.csv" -Default $OutputCsv
}

$folders = @(
    @{ Type = "mod";          Path = $InstanceModsFolder;          Ext = "*.jar" }
    @{ Type = "resourcepack"; Path = $InstanceResourcepacksFolder; Ext = "*.zip" }
    @{ Type = "shader";       Path = $InstanceShaderpacksFolder;   Ext = "*.zip" }
    @{ Type = "datapack";     Path = $InstanceDatapacksFolder;     Ext = "*.zip" }
    @{ Type = "plugin";       Path = $InstancePluginsFolder;       Ext = "*.jar" }
)

$configured = $folders | Where-Object { $_.Path }
if ($configured.Count -eq 0) {
    Write-Error "No folders to scan. Pass at least one -Instance...Folder parameter, or set INSTANCE_ROOT (or an individual INSTANCE_*_FOLDER key) in $(Resolve-PackSecretsFile -SecretsFile $SecretsFile)."
    exit 1
}

$summary = @{ OutputCsv = $OutputCsv }
foreach ($f in $configured) { $summary[$f.Type] = $f.Path }
Show-PackConfigSummary -Values $summary -Title "Folders to scan"

$results = New-Object System.Collections.Generic.List[object]

foreach ($f in $configured) {
    if (-not (Test-Path $f.Path)) {
        if ($explicit[$f.Type]) {
            Write-Host "Warning: $($f.Type) folder not found: $($f.Path)" -ForegroundColor Yellow
        }
        continue
    }
    $files = Get-ChildItem -Path $f.Path -Filter $f.Ext -File
    Write-Host "$($f.Type): $($files.Count) file(s) in $($f.Path)" -ForegroundColor Cyan
    foreach ($file in $files) {
        $results.Add([PSCustomObject]@{
            Type = $f.Type; Filename = $file.Name; SizeBytes = $file.Length; FullPath = $file.FullName
        })
    }
}

$results = $results | Sort-Object Type, Filename
$results | Export-Csv -Path $OutputCsv -NoTypeInformation

Write-Host "`n$($results.Count) files total -> $OutputCsv" -ForegroundColor Cyan

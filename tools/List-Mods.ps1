<#
.SYNOPSIS
    Lists all mod jar files in a mods folder and saves the list to a text file.

.DESCRIPTION
    Scans a mods directory for .jar files, sorts them alphabetically, and writes
    the results to a text file. Includes filename, size (MB), and last modified date.
    Defaults to the Modrinth App profiles folder if no path is given.

.PARAMETER ModsFolder
    Path to the mods folder. Defaults to a Modrinth App instance if not specified.

.PARAMETER OutputFile
    Path to the output text file. Defaults to "mod_list.txt" in the current directory.

.EXAMPLE
    .\List-Mods.ps1
    Uses default paths.

.EXAMPLE
    .\List-Mods.ps1 -ModsFolder "C:\Users\Terra\AppData\Roaming\ModrinthApp\profiles\Forge Everything\mods" -OutputFile "C:\Users\Terra\Desktop\fe_mod_list.txt"
#>

param(
    [string]$ModsFolder = "$env:APPDATA\ModrinthApp\profiles\Forge Everything\mods",
    [string]$OutputFile = ".\mod_list.txt"
)

if (-not (Test-Path -LiteralPath $ModsFolder)) {
    Write-Error "Mods folder not found: $ModsFolder"
    exit 1
}

$mods = Get-ChildItem -LiteralPath $ModsFolder -Filter *.jar -File |
    Sort-Object Name

if ($mods.Count -eq 0) {
    Write-Warning "No .jar files found in: $ModsFolder"
}

$lines = New-Object System.Collections.Generic.List[string]
$lines.Add("Mod list generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$lines.Add("Source folder: $ModsFolder")
$lines.Add("Total mods: $($mods.Count)")
$lines.Add("")

foreach ($mod in $mods) {
    $sizeMB = [math]::Round($mod.Length / 1MB, 2)
    $lines.Add("$($mod.BaseName)  [$sizeMB MB]  (modified $($mod.LastWriteTime.ToString('yyyy-MM-dd')))")
}

# Use StringBuilder + WriteAllText to avoid the List<string> -> Set-Content
# silent-failure issue.
$sb = New-Object System.Text.StringBuilder
foreach ($line in $lines) {
    [void]$sb.AppendLine($line)
}

$resolvedOutputFile = [System.IO.Path]::GetFullPath($OutputFile)
[System.IO.File]::WriteAllText($resolvedOutputFile, $sb.ToString())

Write-Host "Wrote $($mods.Count) mods to $resolvedOutputFile"

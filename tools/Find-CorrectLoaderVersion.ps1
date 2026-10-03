<#
.SYNOPSIS
    Re-resolves Modrinth entries that were flagged MISSING_FROM_INSTANCE by checking
    whether the resolved link actually points at the wrong loader or wrong Minecraft
    version - and if so, finds and reports the correct NeoForge 1.21.1 version instead.

.DESCRIPTION
    Process-ModList.ps1's MISSING_FROM_INSTANCE bucket mixes two very different
    situations: mods that are genuinely absent locally, and mods where the resolved
    URL itself points at the wrong build (Fabric instead of NeoForge, or the wrong
    MC version) - which will *always* show as missing locally since no such file
    exists in a NeoForge instance to begin with.

    This script takes the report CSV, filters to MISSING_FROM_INSTANCE rows, and for
    each one queries the Modrinth project's version list with STRICT filters
    (loaders=["neoforge"], game_versions=["1.21.1"]). If a valid version exists under
    those filters, it reports the correct direct link - meaning the original
    resolution mistakenly grabbed a different build. If NO version exists under those
    filters, that confirms the mod genuinely doesn't have a compatible build at all
    (a real problem, not a resolution mistake) or is genuinely just not downloaded yet.

.PARAMETER ReportCsv
    Path to mod-list-processing-report.csv (from Process-ModList.ps1)

.PARAMETER SecretsFile
    Same secrets file used by the other scripts, for the Modrinth token (optional).

.EXAMPLE
    .\Find-CorrectLoaderVersion.ps1 -ReportCsv .\mod-list-processing-report.csv
#>

param(
    [Parameter(Mandatory = $true)]
    [string]$ReportCsv,

    [string]$ApiToken,
    [string]$SecretsFile = (Join-Path $PSScriptRoot "secrets.local.env"),

    [string]$TargetGameVersion = "1.21.1",
    [string]$TargetLoader = "neoforge",

    [int]$DelaySeconds = 1
)

[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

if (Test-Path $SecretsFile) {
    foreach ($line in Get-Content -Path $SecretsFile) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith("#")) { continue }
        $idx = $line.IndexOf("=")
        if ($idx -lt 1) { continue }
        if ($line.Substring(0, $idx).Trim() -eq "MODRINTH_TOKEN" -and -not $ApiToken) {
            $ApiToken = $line.Substring($idx + 1).Trim().Trim('"').Trim("'")
        }
    }
}

function Invoke-ModrinthApi {
    param([string]$Uri)
    $headers = @{ "User-Agent" = "ForgeEverything-LoaderCheck/1.0 (contact: terra)" }
    if ($ApiToken) { $headers["Authorization"] = $ApiToken }
    return Invoke-RestMethod -Uri $Uri -Headers $headers
}

if (-not (Test-Path $ReportCsv)) { Write-Error "Report not found: $ReportCsv"; exit 1 }

$rows = Import-Csv -Path $ReportCsv | Where-Object { $_.Status -eq "MISSING_FROM_INSTANCE" -and $_.Source -eq "modrinth" }
Write-Host "Checking $($rows.Count) MISSING_FROM_INSTANCE Modrinth entries for wrong loader/version ..." -ForegroundColor Cyan

$results = New-Object System.Collections.Generic.List[object]
$i = 0

foreach ($row in $rows) {
    $i++
    if ($row.RequestedUrl -notmatch '/mod/([^/]+)/version/') {
        Write-Host "[$i/$($rows.Count)] skip (unparsable): $($row.RequestedUrl)" -ForegroundColor DarkGray
        continue
    }
    $slug = $Matches[1]
    Write-Host "[$i/$($rows.Count)] $slug (was: $($row.Filename))" -ForegroundColor Green

    try {
        $allVersions = Invoke-ModrinthApi -Uri "https://api.modrinth.com/v2/project/$slug/version"
    }
    catch {
        Write-Host "  API error: $($_.Exception.Message)" -ForegroundColor Red
        $results.Add([PSCustomObject]@{
            Slug = $slug; OriginalFilename = $row.Filename; OriginalUrl = $row.RequestedUrl
            Verdict = "API_ERROR"; CorrectFilename = ""; CorrectUrl = ""
        })
        Start-Sleep -Seconds $DelaySeconds
        continue
    }

    $strictMatches = $allVersions | Where-Object {
        $_.loaders -contains $TargetLoader -and $_.game_versions -contains $TargetGameVersion
    }

    if ($strictMatches.Count -eq 0) {
        Write-Host "  NO $TargetLoader / $TargetGameVersion build exists for this mod at all - genuinely not available, not a resolution mistake" -ForegroundColor Yellow
        $results.Add([PSCustomObject]@{
            Slug = $slug; OriginalFilename = $row.Filename; OriginalUrl = $row.RequestedUrl
            Verdict = "NO_COMPATIBLE_BUILD_EXISTS"; CorrectFilename = ""; CorrectUrl = ""
        })
    }
    else {
        $best = $strictMatches | Sort-Object date_published -Descending | Select-Object -First 1
        $file = $best.files | Where-Object { $_.primary } | Select-Object -First 1
        if (-not $file) { $file = $best.files | Select-Object -First 1 }
        $correctUrl = "https://modrinth.com/mod/$slug/version/$($best.id)"

        Write-Host "  FOUND correct build: $($file.filename)" -ForegroundColor Green
        Write-Host "  $correctUrl" -ForegroundColor Green

        $results.Add([PSCustomObject]@{
            Slug = $slug; OriginalFilename = $row.Filename; OriginalUrl = $row.RequestedUrl
            Verdict = "CORRECTED"; CorrectFilename = $file.filename; CorrectUrl = $correctUrl
        })
    }

    Start-Sleep -Seconds $DelaySeconds
}

$outPath = "loader-version-corrections.csv"
$results | Export-Csv -Path $outPath -NoTypeInformation

$corrected = ($results | Where-Object { $_.Verdict -eq "CORRECTED" }).Count
$noBuild = ($results | Where-Object { $_.Verdict -eq "NO_COMPATIBLE_BUILD_EXISTS" }).Count

Write-Host "`n--- Summary ---" -ForegroundColor Cyan
Write-Host "  $corrected mods had a wrong build resolved - correct link now in $outPath" -ForegroundColor Green
Write-Host "  $noBuild mods genuinely have no $TargetLoader/$TargetGameVersion build - not a resolution mistake" -ForegroundColor Yellow
Write-Host "`nNext step: for the CORRECTED rows, replace the old URL with CorrectUrl in links_to_mods.txt," -ForegroundColor Cyan
Write-Host "then re-run Process-ModList.ps1 (or just that subset) to verify." -ForegroundColor Cyan

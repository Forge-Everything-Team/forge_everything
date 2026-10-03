<#
.SYNOPSIS
    Find-EntityReferences.ps1 v1.0.0
    Locates references to an entity/block/item ID inside mod jars, datapacks,
    config files and KubeJS scripts - including inside gzipped structure NBTs.

.DESCRIPTION
    Structure files (.nbt) are gzip-compressed NBT, so a plain Select-String
    across the mods folder will not find IDs baked into spawner SpawnData.
    This script decompresses them in memory and searches the raw bytes.

.EXAMPLE
    .\Find-EntityReferences.ps1 -SearchTerm "alexsmobs:soul_vulture" `
        -Roots "C:\Users\Terra\AppData\Roaming\ModrinthApp\profiles\Forge Everything"

.NOTES
    PowerShell 5.1 compatible. Read-only - never modifies any file.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string[]] $SearchTerm,

    [Parameter(Mandatory = $true)]
    [string[]] $Roots,

    [string[]] $SubDirs = @('mods', 'datapacks', 'config', 'kubejs', 'defaultconfigs', 'paxi'),

    [string] $OutCsv
)

Write-Host "Find-EntityReferences.ps1 v1.0.0" -ForegroundColor Cyan

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$enc = [System.Text.Encoding]::GetEncoding(28591)   # Latin-1: byte-preserving
$results = New-Object System.Collections.ArrayList

function Get-StreamBytes {
    param([System.IO.Stream] $Stream)
    $ms = New-Object System.IO.MemoryStream
    $Stream.CopyTo($ms)
    return $ms.ToArray()
}

function Expand-IfGzip {
    param([byte[]] $Bytes)
    if ($Bytes.Length -gt 2 -and $Bytes[0] -eq 0x1f -and $Bytes[1] -eq 0x8b) {
        try {
            $in  = New-Object System.IO.MemoryStream(, $Bytes)
            $gz  = New-Object System.IO.Compression.GZipStream($in, [System.IO.Compression.CompressionMode]::Decompress)
            $out = New-Object System.IO.MemoryStream
            $gz.CopyTo($out)
            $gz.Dispose(); $in.Dispose()
            return $out.ToArray()
        } catch { return $Bytes }   # truncated/!gzip - fall back to raw
    }
    return $Bytes
}

function Test-Bytes {
    param([byte[]] $Bytes, [string] $Source, [string] $Entry)
    if (-not $Bytes -or $Bytes.Length -eq 0) { return }
    $text = $enc.GetString($Bytes)
    foreach ($term in $SearchTerm) {
        $idx = $text.IndexOf($term, [System.StringComparison]::OrdinalIgnoreCase)
        if ($idx -ge 0) {
            $count = 0; $p = $idx
            while ($p -ge 0) {
                $count++
                $p = $text.IndexOf($term, $p + $term.Length, [System.StringComparison]::OrdinalIgnoreCase)
            }
            $lo = [Math]::Max(0, $idx - 60)
            $hi = [Math]::Min($text.Length, $idx + $term.Length + 60)
            $ctx = ($text.Substring($lo, $hi - $lo) -replace '[^\x20-\x7E]', '.')
            [void]$results.Add([pscustomobject]@{
                Term    = $term
                Source  = $Source
                Entry   = $Entry
                Hits    = $count
                Context = $ctx
            })
            Write-Host ("  HIT [{0}] {1}" -f $term, $Entry) -ForegroundColor Yellow
            Write-Host ("       ...{0}..." -f $ctx) -ForegroundColor DarkGray
        }
    }
}

# --- text-ish entries we search raw, plus .nbt which we gunzip first ---
$textExt = @('.json', '.snbt', '.js', '.ts', '.toml', '.mcfunction', '.txt', '.cfg', '.zs')

foreach ($root in $Roots) {
    if (-not (Test-Path -LiteralPath $root)) {
        Write-Warning "Root not found: $root"; continue
    }

    foreach ($sub in $SubDirs) {
        $dir = Join-Path $root $sub
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        Write-Host "`nScanning $dir" -ForegroundColor Green

        # ---- archives (.jar / .zip) ----
        Get-ChildItem -LiteralPath $dir -Recurse -Include *.jar, *.zip -ErrorAction SilentlyContinue | ForEach-Object {
            $jar = $_.FullName
            try {
                $zip = [System.IO.Compression.ZipFile]::OpenRead($jar)
            } catch {
                Write-Warning "Cannot open $($_.Name): $($_.Exception.Message)"; return
            }
            try {
                foreach ($e in $zip.Entries) {
                    if ($e.Length -eq 0) { continue }
                    $ext = [System.IO.Path]::GetExtension($e.FullName).ToLowerInvariant()
                    if ($ext -ne '.nbt' -and $textExt -notcontains $ext) { continue }
                    $s = $e.Open()
                    try {
                        $bytes = Get-StreamBytes -Stream $s
                    } finally { $s.Dispose() }
                    if ($ext -eq '.nbt') { $bytes = Expand-IfGzip -Bytes $bytes }
                    Test-Bytes -Bytes $bytes -Source $jar -Entry $e.FullName
                }
            } finally { $zip.Dispose() }
        }

        # ---- loose files on disk (datapacks, configs, kubejs) ----
        Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
            $ext = $_.Extension.ToLowerInvariant()
            if ($ext -ne '.nbt' -and $textExt -notcontains $ext) { return }
            try {
                $bytes = [System.IO.File]::ReadAllBytes($_.FullName)
            } catch { return }
            if ($ext -eq '.nbt') { $bytes = Expand-IfGzip -Bytes $bytes }
            Test-Bytes -Bytes $bytes -Source $_.DirectoryName -Entry $_.Name
        }
    }
}

Write-Host ""
if ($results.Count -eq 0) {
    Write-Host "No references found." -ForegroundColor Green
} else {
    Write-Host ("{0} reference(s) found across {1} file(s)." -f
        ($results | Measure-Object -Property Hits -Sum).Sum,
        ($results | Select-Object -ExpandProperty Entry -Unique).Count) -ForegroundColor Yellow
    $results | Group-Object Source | Sort-Object Count -Descending |
        Select-Object @{n='Jar';e={Split-Path $_.Name -Leaf}}, Count | Format-Table -AutoSize
}

if ($OutCsv) {
    $results | Export-Csv -LiteralPath $OutCsv -NoTypeInformation -Encoding UTF8
    Write-Host "Written to $OutCsv" -ForegroundColor Cyan
}

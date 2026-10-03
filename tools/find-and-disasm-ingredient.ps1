Add-Type -AssemblyName System.IO.Compression.FileSystem

$javap = "C:\Program Files\Java\jdk-21\bin\javap.exe"
$targetEntry = "net/minecraft/world/item/crafting/Ingredient.class"
$outDir = "$env:TEMP\ingredient_dump"
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

$gradleCache = "$env:USERPROFILE\.gradle\caches"

if (-not (Test-Path $gradleCache)) {
    Write-Host "No .gradle\caches folder found at $gradleCache" -ForegroundColor Red
    Write-Host "Do you build everythingores from a different Gradle home? Check gradle.properties / GRADLE_USER_HOME."
    exit
}

Write-Host "Scanning Gradle cache for a jar containing deobfuscated Ingredient.class..."
Write-Host "(this cache is usually large - first pass may take a minute)"
Write-Host ""

# Deobfuscated Minecraft jars from NeoForm/NeoGradle are typically named like
# "*-joined.jar", "*-client.jar", "*-mapped.jar", or similar. Search broadly but
# skip obviously irrelevant jars (sources/javadoc) to save time.
$jars = Get-ChildItem -Path $gradleCache -Recurse -Filter "*.jar" -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notlike "*sources*" -and $_.Name -notlike "*javadoc*" -and $_.Length -gt 1MB }

Write-Host "Checking $($jars.Count) candidate jar(s)..."

$foundJar = $null
$i = 0
foreach ($jar in $jars) {
    $i++
    Write-Host -NoNewline "`r[$i/$($jars.Count)] $($jar.Name)".PadRight(100)
    try {
        $zip = [System.IO.Compression.ZipFile]::OpenRead($jar.FullName)
        $entry = $zip.GetEntry($targetEntry)
        if ($entry) {
            $classFile = Join-Path $outDir "Ingredient.class"
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $classFile, $true)
            $foundJar = $jar.FullName
            $zip.Dispose()
            break
        }
        $zip.Dispose()
    } catch {}
}
Write-Host ""
Write-Host ""

if (-not $foundJar) {
    Write-Host "Not found in Gradle cache either." -ForegroundColor Red
    Write-Host "Try instead: cd into the everythingores project and run 'gradlew --stop' then"
    Write-Host "'gradlew compileJava --refresh-dependencies' to force NeoGradle to (re)materialize"
    Write-Host "the mapped jar, then re-run this script."
    exit
}

Write-Host "Found in: $foundJar" -ForegroundColor Green
$classFile = Join-Path $outDir "Ingredient.class"
$outputFile = Join-Path $outDir "Ingredient.javap.txt"
& $javap -p -c -v $classFile | Out-File -FilePath $outputFile -Encoding utf8

Write-Host "--- getItems() method ---"
$sb = New-Object System.Text.StringBuilder
$capture = $false
$blankCount = 0
Get-Content $outputFile | ForEach-Object {
    if ($_ -match "getItems\(\)") { $capture = $true; $blankCount = 0 }
    if ($capture) {
        [void]$sb.AppendLine($_)
        if ($_ -match "^\s*$") { $blankCount++ } else { $blankCount = 0 }
        if ($blankCount -ge 2) { $capture = $false }
    }
}
Write-Host $sb.ToString()

Write-Host "--- Fields ---"
& $javap -p $classFile | Select-String "\["

Write-Host ""
Write-Host "Full disassembly saved at: $outputFile"
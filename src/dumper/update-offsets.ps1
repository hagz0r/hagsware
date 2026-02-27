# Download/Update JSON offset files from cs2-dumper repository using git sparse-checkout
param(
    [string]$RepoUrl = "https://github.com/a2x/cs2-dumper.git",
    [string]$SparsePath = "output"
)

# Get script directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputPath = $scriptDir
$tempRepoPath = Join-Path $scriptDir ".cs2-dumper-temp"

Write-Host "CS2 Dumper Offset Updater" -ForegroundColor Cyan
Write-Host "=========================" -ForegroundColor Cyan
Write-Host ""

# Check if git is available
try {
    git --version | Out-Null
}
catch {
    Write-Host "Error: Git is not installed or not in PATH" -ForegroundColor Red
    exit 1
}

# Always do a fresh clone since we delete temp folder after each run
$needsClone = $true

# Clone repository if needed
if ($needsClone) {
    Write-Host "Cloning repository (sparse checkout)..." -ForegroundColor Cyan

    try {
        # Initialize git repo
        New-Item -ItemType Directory -Path $tempRepoPath -Force | Out-Null
        Push-Location $tempRepoPath

        git init 2>&1 | Out-Null
        git remote add origin $RepoUrl 2>&1 | Out-Null
        git config core.sparseCheckout true

        # Set sparse checkout path
        $sparseCheckoutDir = ".git/info"
        if (-not (Test-Path $sparseCheckoutDir)) {
            New-Item -ItemType Directory -Path $sparseCheckoutDir -Force | Out-Null
        }
        $sparseCheckoutFile = "$sparseCheckoutDir/sparse-checkout"
        Set-Content -Path $sparseCheckoutFile -Value $SparsePath -Force

        # Pull only the specified path
        git pull origin main --quiet 2>&1 | Out-Null

        Pop-Location

        Write-Host "Repository cloned successfully" -ForegroundColor Green
    }
    catch {
        Write-Host "Error cloning repository: $_" -ForegroundColor Red
        if (Test-Path $tempRepoPath) {
            Pop-Location
            Remove-Item -Recurse -Force $tempRepoPath
        }
        exit 1
    }
}

Write-Host ""

# Copy JSON files to output directory
$sourcePath = Join-Path $tempRepoPath $SparsePath
$jsonFiles = Get-ChildItem -Path $sourcePath -Filter "*.json"

if ($jsonFiles.Count -eq 0) {
    Write-Host "No JSON files found in repository" -ForegroundColor Yellow
    exit 1
}

Write-Host "Copying $($jsonFiles.Count) JSON file(s)..." -ForegroundColor Cyan

$successCount = 0
$failCount = 0

foreach ($file in $jsonFiles) {
    $destination = Join-Path $outputPath $file.Name

    try {
        Copy-Item -Path $file.FullName -Destination $destination -Force
        Write-Host "  [OK] $($file.Name)" -ForegroundColor Green
        $successCount++
    }
    catch {
        Write-Host "  [FAIL] $($file.Name) - $_" -ForegroundColor Red
        $failCount++
    }
}

Write-Host ""

# Clean up temp directory
if (Test-Path $tempRepoPath) {
    Write-Host "Cleaning up temporary files..." -ForegroundColor Yellow
    Remove-Item -Recurse -Force $tempRepoPath -ErrorAction SilentlyContinue

    # If cleanup failed, try again after a brief delay
    if (Test-Path $tempRepoPath) {
        Start-Sleep -Milliseconds 500
        Remove-Item -Recurse -Force $tempRepoPath -ErrorAction SilentlyContinue
    }
}

Write-Host "Update complete!" -ForegroundColor Cyan
Write-Host "Success: $successCount | Failed: $failCount" -ForegroundColor $(if ($failCount -eq 0) { "Green" } else { "Yellow" })
Write-Host "Files saved to: $outputPath" -ForegroundColor Gray

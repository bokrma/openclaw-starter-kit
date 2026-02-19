$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$rootDir = $PSScriptRoot
$psUnit = Join-Path (Join-Path $rootDir "tests") "start.unit.ps1"
$shUnit = Join-Path (Join-Path $rootDir "tests") "start.unit.sh"

if (-not (Test-Path $psUnit)) {
    throw "Missing unit test file: $psUnit"
}

Write-Host "[openclaw-easy] Running PowerShell unit tests"
& $psUnit

if (Get-Command bash -ErrorAction SilentlyContinue) {
    if (Test-Path $shUnit) {
        Write-Host "[openclaw-easy] Running Bash unit tests"
        Push-Location $rootDir
        try {
            & bash "./tests/start.unit.sh"
            if ($LASTEXITCODE -ne 0) {
                throw "Bash unit tests failed (exit $LASTEXITCODE)."
            }
        }
        finally {
            Pop-Location
        }
    }
}
else {
    Write-Host "[openclaw-easy] Bash not found; skipped Bash unit tests"
}

Write-Host "[openclaw-easy] Unit tests passed"

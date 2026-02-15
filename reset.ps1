param(
    [switch]$Full
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $true
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[openclaw-easy] $Message"
}

function Resolve-ComposeCommand {
    if (Get-Command docker -ErrorAction SilentlyContinue) {
        & docker compose version > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            return @("docker", "compose")
        }
    }
    if (Get-Command docker-compose -ErrorAction SilentlyContinue) {
        & docker-compose version > $null 2>&1
        if ($LASTEXITCODE -eq 0) {
            return @("docker-compose")
        }
    }
    return @()
}

$RootDir = $PSScriptRoot
$OpenClawSrcDir = if ($env:OPENCLAW_SRC_DIR) { $env:OPENCLAW_SRC_DIR } else { Join-Path (Join-Path $RootDir "vendor") "openclaw" }
$SafeComposeTemplate = Join-Path $RootDir "docker-compose.safe.yml"
$script:ComposeCommand = Resolve-ComposeCommand

if (Test-Path $OpenClawSrcDir) {
    $safeComposeTarget = Join-Path $OpenClawSrcDir "docker-compose.safe.yml"
    if (-not (Test-Path $safeComposeTarget) -and (Test-Path $SafeComposeTemplate)) {
        Copy-Item -Path $SafeComposeTemplate -Destination $safeComposeTarget -Force
        Write-Step "Provisioned docker-compose.safe.yml in cloned OpenClaw repo"
    }
    Write-Step "Stopping and removing OpenClaw safe Docker stack"
    Push-Location $OpenClawSrcDir
    try {
        if ($script:ComposeCommand.Count -gt 0) {
            $composeSuffix = @($script:ComposeCommand | Select-Object -Skip 1)
            & $script:ComposeCommand[0] @composeSuffix -f docker-compose.safe.yml down -v --remove-orphans
        }
        else {
            Write-Step "Docker Compose not found, skipping compose cleanup"
        }
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Step "OpenClaw source not found, skipping docker compose reset"
}

if ($Full) {
    Write-Step "Removing cloned OpenClaw source"
    Remove-Item -Path $OpenClawSrcDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Step "Reset complete"

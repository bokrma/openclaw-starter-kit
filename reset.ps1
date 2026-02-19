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

function Import-DotEnv {
    param([string]$Path)
    foreach ($rawLine in Get-Content -Path $Path) {
        $line = $rawLine.Trim()
        if (-not $line -or $line.StartsWith("#")) {
            continue
        }
        $parts = $line -split "=", 2
        if ($parts.Count -ne 2) {
            continue
        }
        $key = $parts[0].Trim().TrimStart([char]0xFEFF)
        Set-Item -Path "env:$key" -Value $parts[1].Trim()
    }
}

function Is-Truthy {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    return $Value.Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")
}

$RootDir = $PSScriptRoot
$EnvFile = Join-Path $RootDir ".env"
$SafeComposeTemplate = Join-Path $RootDir "docker-compose.safe.yml"
$script:ComposeCommand = Resolve-ComposeCommand
if (Test-Path $EnvFile) {
    Import-DotEnv -Path $EnvFile
}
$OpenClawSrcDir = if ($env:OPENCLAW_SRC_DIR) { $env:OPENCLAW_SRC_DIR } else { Join-Path (Join-Path $RootDir "vendor") "openclaw" }
if (-not $env:COMPOSE_PROJECT_NAME) { $env:COMPOSE_PROJECT_NAME = "openclaw-easy" }
if (-not $env:OPENCLAW_SAFE_PROJECT_NAME) { $env:OPENCLAW_SAFE_PROJECT_NAME = $env:COMPOSE_PROJECT_NAME }
$script:ComposeProjectName = $env:COMPOSE_PROJECT_NAME

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
            $composeArgs = @("-p", $script:ComposeProjectName)
            $composeEnvFile = Join-Path $OpenClawSrcDir ".env"
            if (Test-Path $composeEnvFile) {
                $composeArgs += @("--env-file", $composeEnvFile)
            }
            & $script:ComposeCommand[0] @composeSuffix @composeArgs -f docker-compose.safe.yml down -v --remove-orphans
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

$MissionControlSrcDir = if ($env:OPENCLAW_MISSION_CONTROL_SRC_DIR) { $env:OPENCLAW_MISSION_CONTROL_SRC_DIR } else { Join-Path (Join-Path $RootDir "vendor") "openclaw-mission-control" }
if ((Test-Path $MissionControlSrcDir) -and (Test-Path (Join-Path $MissionControlSrcDir "compose.yml"))) {
    Write-Step "Stopping and removing Mission Control Docker stack"
    Push-Location $MissionControlSrcDir
    try {
        if ($script:ComposeCommand.Count -gt 0) {
            $composeSuffix = @($script:ComposeCommand | Select-Object -Skip 1)
            $composeArgs = @("-p", "$($script:ComposeProjectName)-mission-control")
            $missionEnvFile = Join-Path $MissionControlSrcDir ".env"
            if (Test-Path $missionEnvFile) {
                $composeArgs += @("--env-file", $missionEnvFile)
            }
            & $script:ComposeCommand[0] @composeSuffix @composeArgs -f compose.yml down -v --remove-orphans
        }
        else {
            Write-Step "Docker Compose not found, skipping Mission Control cleanup"
        }
    }
    finally {
        Pop-Location
    }
}

$commandCenterComposeFile = Join-Path $RootDir "command-center.compose.yml"
if (Test-Path $commandCenterComposeFile) {
    Write-Step "Stopping and removing Command Center Docker stack"
    if ($script:ComposeCommand.Count -gt 0) {
        $composeSuffix = @($script:ComposeCommand | Select-Object -Skip 1)
        $composeArgs = @("-p", "$($script:ComposeProjectName)-command-center")
        if (Test-Path $EnvFile) {
            $composeArgs += @("--env-file", $EnvFile)
        }
        & $script:ComposeCommand[0] @composeSuffix @composeArgs -f $commandCenterComposeFile down -v --remove-orphans
    }
    else {
        Write-Step "Docker Compose not found, skipping Command Center cleanup"
    }
}

if ($Full) {
    Write-Step "Removing cloned OpenClaw source"
    Remove-Item -Path $OpenClawSrcDir -Recurse -Force -ErrorAction SilentlyContinue
    Write-Step "Removing cloned Mission Control source"
    Remove-Item -Path $MissionControlSrcDir -Recurse -Force -ErrorAction SilentlyContinue
    $CommandCenterSrcDir = if ($env:OPENCLAW_COMMAND_CENTER_SRC_DIR) { $env:OPENCLAW_COMMAND_CENTER_SRC_DIR } else { Join-Path (Join-Path $RootDir "vendor") "openclaw-command-center" }
    Write-Step "Removing cloned Command Center source"
    Remove-Item -Path $CommandCenterSrcDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Step "Reset complete"

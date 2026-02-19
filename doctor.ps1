$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $true
    $PSNativeCommandArgumentPassing = "Standard"
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "[openclaw-easy][doctor] $Message"
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
    throw "Docker Compose not found. Install Docker Compose v2 (docker compose) or docker-compose."
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

function Invoke-Compose {
    param(
        [string]$OpenClawSrcDir,
        [string[]]$ComposeArgs,
        [switch]$Capture,
        [switch]$IgnoreExitCode
    )
    Push-Location $OpenClawSrcDir
    try {
        $composeSuffix = @($script:ComposeCommand | Select-Object -Skip 1)
        $composeProjectArgs = @("-p", $script:ComposeProjectName)
        $composeEnvArgs = @("--env-file", $script:ComposeEnvFile)
        if ($Capture) {
            $output = & $script:ComposeCommand[0] @composeSuffix @composeProjectArgs @composeEnvArgs -f docker-compose.safe.yml @ComposeArgs 2>&1
        }
        else {
            & $script:ComposeCommand[0] @composeSuffix @composeProjectArgs @composeEnvArgs -f docker-compose.safe.yml @ComposeArgs
            $output = @()
        }
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if (-not $IgnoreExitCode -and $code -ne 0) {
        throw "docker compose failed (exit $code): $($ComposeArgs -join ' ')"
    }
    return [PSCustomObject]@{
        Code = $code
        Output = $output
    }
}

function Invoke-LocalScript {
    param([string]$ScriptPath)
    & $ScriptPath
    if ($LASTEXITCODE -ne 0) {
        throw "Script failed (exit $LASTEXITCODE): $ScriptPath"
    }
}

function Get-LastJsonLine {
    param([object[]]$Lines)
    return @($Lines) | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -match "^\{.*\}$" } | Select-Object -Last 1
}

function Test-BrowserControlService {
    param([string]$OpenClawSrcDir)
    $result = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @(
        "exec", "-T", "openclaw-gateway", "node", "dist/index.js", "browser", "status", "--json"
    ) -Capture -IgnoreExitCode
    if ($result.Code -ne 0) {
        $tail = @($result.Output) | Select-Object -Last 1
        return [PSCustomObject]@{
            Ready = $false
            Detail = "probe command failed: $($tail.ToString().Trim())"
        }
    }
    $jsonRaw = (@($result.Output) | ForEach-Object { $_.ToString() }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($jsonRaw)) {
        return [PSCustomObject]@{
            Ready = $false
            Detail = "probe returned no output"
        }
    }
    try {
        $payload = $jsonRaw | ConvertFrom-Json
        $ready = [bool]$payload.enabled -and ([bool]$payload.cdpHttp -or [bool]$payload.running -or -not [string]::IsNullOrWhiteSpace([string]$payload.detectedBrowser))
        return [PSCustomObject]@{
            Ready = $ready
            Detail = "enabled=$($payload.enabled) cdpHttp=$($payload.cdpHttp) running=$($payload.running) profile=$($payload.profile)"
        }
    }
    catch {
        return [PSCustomObject]@{
            Ready = $false
            Detail = "probe json parse failed"
        }
    }
}

$RootDir = $PSScriptRoot
$EnvFile = Join-Path $RootDir ".env"
$StartScript = Join-Path $RootDir "start.ps1"
$VerifyScript = Join-Path $RootDir "verify.ps1"

if (-not (Test-Path $StartScript)) { throw "Missing script: $StartScript" }
if (-not (Test-Path $VerifyScript)) { throw "Missing script: $VerifyScript" }
if (-not (Test-Path $EnvFile)) { throw ".env not found. Run start.ps1 first." }

$script:ComposeCommand = Resolve-ComposeCommand

Write-Step "Running start"
Invoke-LocalScript -ScriptPath $StartScript

Write-Step "Running verify"
Invoke-LocalScript -ScriptPath $VerifyScript

Import-DotEnv -Path $EnvFile

$OpenClawSrcDir = if ($env:OPENCLAW_SRC_DIR) { $env:OPENCLAW_SRC_DIR } else { Join-Path (Join-Path $RootDir "vendor") "openclaw" }
if (-not (Test-Path $OpenClawSrcDir)) {
    throw "OpenClaw source not found at $OpenClawSrcDir."
}

$script:ComposeEnvFile = Join-Path $OpenClawSrcDir ".env"
if (-not (Test-Path $script:ComposeEnvFile)) {
    Copy-Item -Path $EnvFile -Destination $script:ComposeEnvFile -Force
}
$script:ComposeProjectName = if ($env:COMPOSE_PROJECT_NAME) { $env:COMPOSE_PROJECT_NAME } else { "openclaw-easy" }

Write-Step "Browser status probe"
$browserProbe = Test-BrowserControlService -OpenClawSrcDir $OpenClawSrcDir
if (-not $browserProbe.Ready) {
    throw "Browser status probe failed: $($browserProbe.Detail)"
}

Write-Step "PASS"
Write-Host "[openclaw-easy][doctor] browser $($browserProbe.Detail)"


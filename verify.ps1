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

function Invoke-Compose {
    param(
        [string]$OpenClawSrcDir,
        [string[]]$Args,
        [switch]$IgnoreExitCode
    )
    Push-Location $OpenClawSrcDir
    try {
        $composeSuffix = @($script:ComposeCommand | Select-Object -Skip 1)
        & $script:ComposeCommand[0] @composeSuffix -f docker-compose.safe.yml @Args
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
    if (-not $IgnoreExitCode -and $code -ne 0) {
        throw "docker compose failed (exit $code): $($Args -join ' ')"
    }
    return $code
}

$RootDir = $PSScriptRoot
$EnvFile = Join-Path $RootDir ".env"
$SafeComposeTemplate = Join-Path $RootDir "docker-compose.safe.yml"
$script:ComposeCommand = Resolve-ComposeCommand

if (-not (Test-Path $EnvFile)) {
    throw ".env not found. Run start.ps1 first."
}

Import-DotEnv -Path $EnvFile

$OpenClawSrcDir = if ($env:OPENCLAW_SRC_DIR) { $env:OPENCLAW_SRC_DIR } else { Join-Path (Join-Path $RootDir "vendor") "openclaw" }
if (-not (Test-Path $OpenClawSrcDir)) {
    throw "OpenClaw source not found at $OpenClawSrcDir. Run start.ps1 first."
}

$safeComposeTarget = Join-Path $OpenClawSrcDir "docker-compose.safe.yml"
if (-not (Test-Path $safeComposeTarget)) {
    if (-not (Test-Path $SafeComposeTemplate)) {
        throw "Missing starter compose template: $SafeComposeTemplate"
    }
    Copy-Item -Path $SafeComposeTemplate -Destination $safeComposeTarget -Force
    Write-Step "Provisioned docker-compose.safe.yml in cloned OpenClaw repo"
}

Write-Step "Gateway container status"
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("ps") | Out-Null

Write-Step "Gateway health"
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("exec", "openclaw-gateway", "node", "dist/index.js", "health", "--json") | Out-Null

Write-Step "Supermemory plugin status"
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "plugins", "info", "openclaw-supermemory") | Out-Null

Write-Step "Checking required skills/tools"
$checkScript = @'
set -eu
required="gmail github automation-workflows playwright-mcp summarize weather skill-creator openclaw-github-assistant github-mcp github-cli github-automation-pro"
SKILLS_DIR=/home/node/.openclaw/workspace/skills
CLAWHUB_BIN=/home/node/.openclaw/tools/bin/clawhub

command -v "$CLAWHUB_BIN" >/dev/null

missing=0
for slug in $required; do
  if [ ! -d "$SKILLS_DIR/$slug" ]; then
    echo "missing skill: $slug"
    missing=1
  fi
done

if [ -d /home/node/.openclaw/workspace/tmp/anthropics-skills ]; then
  echo "ok: anthropics skills repo synced"
else
  echo "missing: anthropics skills repo clone"
  missing=1
fi

if [ -d /home/node/.openclaw/workspace/tmp/vercel-agent-skills ]; then
  echo "ok: vercel agent skills repo synced"
else
  echo "missing: vercel agent skills repo clone"
  missing=1
fi

if [ -d /home/node/.openclaw/workspace/tmp/openclaw-supermemory ]; then
  echo "ok: supermemory repo clone"
else
  echo "missing: supermemory repo clone"
  missing=1
fi

if [ "$missing" -ne 0 ]; then
  exit 1
fi
'@
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "--entrypoint", "sh", "openclaw-cli", "-lc", $checkScript) | Out-Null

Write-Step "Checking required CLIs"
$cliScript = @'
set -eu
/home/node/.openclaw/tools/bin/clawhub -V || /home/node/.openclaw/tools/bin/clawhub --cli-version
/home/node/.openclaw/tools/bin/claude --version
/home/node/.openclaw/tools/bin/codex --version
'@
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "--entrypoint", "sh", "openclaw-cli", "-lc", $cliScript) | Out-Null

Write-Step "Dashboard URL"
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "dashboard", "--no-open") | Out-Null

Write-Step "Verification passed"

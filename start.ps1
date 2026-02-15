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

function Require-Command {
    param([string]$Name)
    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Missing dependency: $Name"
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

function Assert-LastExitCode {
    param([string]$Context)
    if ($LASTEXITCODE -ne 0) {
        throw "$Context failed (exit $LASTEXITCODE)."
    }
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
        $key = $parts[0].Trim()
        $key = $key.TrimStart([char]0xFEFF)
        $value = $parts[1].Trim()
        Set-Item -Path "env:$key" -Value $value
    }
}

function Upsert-DotEnvValue {
    param(
        [string]$Path,
        [string]$Key,
        [string]$Value
    )
    $lines = @()
    if (Test-Path $Path) {
        $lines = Get-Content -Path $Path
    }
    $out = New-Object System.Collections.Generic.List[string]
    foreach ($line in $lines) {
        if ($line -match "^([^=]+)=(.*)$") {
            if ($matches[1] -eq $Key) {
                continue
            }
        }
        $out.Add($line)
    }
    $out.Add("$Key=$Value")
    $out | Set-Content -Path $Path -Encoding ascii
}

function Require-Env {
    param([string]$Key)
    $value = (Get-Item -Path "env:$Key" -ErrorAction SilentlyContinue).Value
    if (-not $value) {
        throw "Missing required value: $Key (set it in .env)"
    }
}

function New-HexToken {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    return ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Invoke-Compose {
    param(
        [string]$OpenClawSrcDir,
        [string[]]$Args,
        [switch]$Capture,
        [switch]$IgnoreExitCode
    )
    Push-Location $OpenClawSrcDir
    try {
        $composeSuffix = @($script:ComposeCommand | Select-Object -Skip 1)
        if ($Capture) {
            $output = & $script:ComposeCommand[0] @composeSuffix -f docker-compose.safe.yml @Args 2>&1
        }
        else {
            & $script:ComposeCommand[0] @composeSuffix -f docker-compose.safe.yml @Args
            $output = @()
        }
        $code = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    if (-not $IgnoreExitCode -and $code -ne 0) {
        throw "docker compose failed (exit $code): $($Args -join ' ')"
    }

    return [PSCustomObject]@{
        Code = $code
        Output = $output
    }
}

$RootDir = $PSScriptRoot
$EnvFile = Join-Path $RootDir ".env"
$EnvExampleFile = Join-Path $RootDir ".env.example"
$SafeComposeTemplate = Join-Path $RootDir "docker-compose.safe.yml"

Require-Command docker
Require-Command git

$script:ComposeCommand = Resolve-ComposeCommand
$script:ComposeHint = $script:ComposeCommand -join " "

if (-not (Test-Path $EnvFile)) {
    Copy-Item -Path $EnvExampleFile -Destination $EnvFile -Force
    throw "Created .env. Fill OPENAI_API_KEY and SUPERMEMORY_API_KEY, then run start.ps1 again."
}

Import-DotEnv -Path $EnvFile

Require-Env OPENAI_API_KEY
Require-Env SUPERMEMORY_API_KEY

if (-not $env:SUPERMEMORY_OPENCLAW_API_KEY) {
    $env:SUPERMEMORY_OPENCLAW_API_KEY = $env:SUPERMEMORY_API_KEY
    Upsert-DotEnvValue -Path $EnvFile -Key "SUPERMEMORY_OPENCLAW_API_KEY" -Value $env:SUPERMEMORY_OPENCLAW_API_KEY
}

if (-not $env:OPENCLAW_IMAGE) { $env:OPENCLAW_IMAGE = "openclaw:local" }
if (-not $env:OPENCLAW_GATEWAY_PORT) { $env:OPENCLAW_GATEWAY_PORT = "18789" }
if (-not $env:OPENCLAW_DOCKER_APT_PACKAGES) { $env:OPENCLAW_DOCKER_APT_PACKAGES = "chromium git" }
if ($env:OPENCLAW_DOCKER_APT_PACKAGES -notmatch "(^|\s)chromium(\s|$)") {
    $env:OPENCLAW_DOCKER_APT_PACKAGES = "$($env:OPENCLAW_DOCKER_APT_PACKAGES) chromium".Trim()
}
if ($env:OPENCLAW_DOCKER_APT_PACKAGES -notmatch "(^|\s)git(\s|$)") {
    $env:OPENCLAW_DOCKER_APT_PACKAGES = "$($env:OPENCLAW_DOCKER_APT_PACKAGES) git".Trim()
}

if (-not $env:OPENCLAW_GATEWAY_TOKEN) {
    $env:OPENCLAW_GATEWAY_TOKEN = New-HexToken
    Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_GATEWAY_TOKEN" -Value $env:OPENCLAW_GATEWAY_TOKEN
    Write-Step "Generated OPENCLAW_GATEWAY_TOKEN and saved it to .env"
}

if (-not $env:OPENCLAW_REPO_URL) { $env:OPENCLAW_REPO_URL = "https://github.com/openclaw/openclaw.git" }
if (-not $env:OPENCLAW_REPO_BRANCH) { $env:OPENCLAW_REPO_BRANCH = "v2026.2.14" }

$OpenClawSrcDir = if ($env:OPENCLAW_SRC_DIR) {
    $env:OPENCLAW_SRC_DIR
}
else {
    Join-Path (Join-Path $RootDir "vendor") "openclaw"
}
$env:OPENCLAW_SRC_DIR = $OpenClawSrcDir

if (Test-Path (Join-Path $OpenClawSrcDir ".git")) {
    Write-Step "Updating OpenClaw source: $OpenClawSrcDir"
    & git -C $OpenClawSrcDir fetch --tags --force origin
    if ($LASTEXITCODE -ne 0) {
        Write-Step "Update failed, recloning OpenClaw source"
        Remove-Item -Path $OpenClawSrcDir -Recurse -Force -ErrorAction SilentlyContinue
        & git clone --depth 1 --branch $env:OPENCLAW_REPO_BRANCH $env:OPENCLAW_REPO_URL $OpenClawSrcDir
        Assert-LastExitCode "git clone"
    }
    else {
        & git -C $OpenClawSrcDir show-ref --verify --quiet "refs/remotes/origin/$($env:OPENCLAW_REPO_BRANCH)"
        $isRemoteBranch = ($LASTEXITCODE -eq 0)
        if ($isRemoteBranch) {
            & git -C $OpenClawSrcDir checkout $env:OPENCLAW_REPO_BRANCH
            if ($LASTEXITCODE -ne 0) {
                Write-Step "Update failed, recloning OpenClaw source"
                Remove-Item -Path $OpenClawSrcDir -Recurse -Force -ErrorAction SilentlyContinue
                & git clone --depth 1 --branch $env:OPENCLAW_REPO_BRANCH $env:OPENCLAW_REPO_URL $OpenClawSrcDir
                Assert-LastExitCode "git clone"
            }
            else {
                & git -C $OpenClawSrcDir pull --rebase origin $env:OPENCLAW_REPO_BRANCH
                if ($LASTEXITCODE -ne 0) {
                    Write-Step "Update failed, recloning OpenClaw source"
                    Remove-Item -Path $OpenClawSrcDir -Recurse -Force -ErrorAction SilentlyContinue
                    & git clone --depth 1 --branch $env:OPENCLAW_REPO_BRANCH $env:OPENCLAW_REPO_URL $OpenClawSrcDir
                    Assert-LastExitCode "git clone"
                }
            }
        }
        else {
            & git -C $OpenClawSrcDir checkout --force $env:OPENCLAW_REPO_BRANCH
            if ($LASTEXITCODE -ne 0) {
                Write-Step "Update failed, recloning OpenClaw source"
                Remove-Item -Path $OpenClawSrcDir -Recurse -Force -ErrorAction SilentlyContinue
                & git clone --depth 1 --branch $env:OPENCLAW_REPO_BRANCH $env:OPENCLAW_REPO_URL $OpenClawSrcDir
                Assert-LastExitCode "git clone"
            }
        }
    }
}
else {
    Write-Step "Cloning OpenClaw source"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OpenClawSrcDir) | Out-Null
    & git clone --depth 1 --branch $env:OPENCLAW_REPO_BRANCH $env:OPENCLAW_REPO_URL $OpenClawSrcDir
    Assert-LastExitCode "git clone"
}

$safeComposeTarget = Join-Path $OpenClawSrcDir "docker-compose.safe.yml"
if (-not (Test-Path $safeComposeTarget)) {
    if (-not (Test-Path $SafeComposeTemplate)) {
        throw "Missing starter compose template: $SafeComposeTemplate"
    }
    Copy-Item -Path $SafeComposeTemplate -Destination $safeComposeTarget -Force
    Write-Step "Provisioned docker-compose.safe.yml in cloned OpenClaw repo"
}

Write-Step "Building OpenClaw image"
& docker build `
    --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=$($env:OPENCLAW_DOCKER_APT_PACKAGES)" `
    -t $env:OPENCLAW_IMAGE `
    -f (Join-Path $OpenClawSrcDir "Dockerfile") `
    $OpenClawSrcDir
Assert-LastExitCode "docker build"

Write-Step "Initializing gateway + auth"
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "gateway.mode", "local") | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "gateway.auth.mode", "token") | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "gateway.auth.token", $env:OPENCLAW_GATEWAY_TOKEN) | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @(
    "run", "--rm", "openclaw-cli", "onboard",
    "--non-interactive", "--accept-risk",
    "--auth-choice", "openai-api-key",
    "--openai-api-key", $env:OPENAI_API_KEY,
    "--skip-channels", "--skip-skills", "--skip-health", "--skip-ui", "--no-install-daemon"
) | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "gateway.mode", "local") | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "gateway.auth.mode", "token") | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "gateway.auth.token", $env:OPENCLAW_GATEWAY_TOKEN) | Out-Null

Write-Step "Applying defaults (CLI backends, concurrency, agent pack)"
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "agents.defaults.cliBackends[claude-cli].command", "/home/node/.openclaw/tools/bin/claude") | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "agents.defaults.cliBackends[codex-cli].command", "/home/node/.openclaw/tools/bin/codex") | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "agents.defaults.subagents.maxConcurrent", "8", "--json") | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "agents.defaults.model.primary", "openai/gpt-5.2-codex") | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "agents.defaults.model.fallbacks", '["openai-codex/gpt-5.2-codex"]', "--json") | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "agents.defaults.maxConcurrent", "10", "--json") | Out-Null

$agentsJson = @'
[
  {"id":"main","name":"Jarvis"},
  {"id":"dev","name":"Dev Agent"},
  {"id":"backend","name":"Backend Engineer"},
  {"id":"frontend","name":"Frontend Engineer (React)"},
  {"id":"designer","name":"Designer"},
  {"id":"ux","name":"UI/UX Expert"},
  {"id":"db","name":"Database Engineer"},
  {"id":"pm","name":"PM Agent"},
  {"id":"qa","name":"QA Agent"},
  {"id":"research","name":"Research Agent"},
  {"id":"ops","name":"Ops Agent"},
  {"id":"growth","name":"Growth Agent"},
  {"id":"finance","name":"Financial Expert"},
  {"id":"stocks","name":"Stock Analyzer"},
  {"id":"creative","name":"Creative Agent"},
  {"id":"motivation","name":"Motivation Agent"}
]
'@
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "agents.list", $agentsJson, "--json") | Out-Null

Write-Step "Installing and configuring Supermemory plugin"
$pluginInfo = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "plugins", "info", "openclaw-supermemory", "--json") -Capture -IgnoreExitCode
if ($pluginInfo.Code -ne 0) {
    Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "plugins", "install", "@supermemory/openclaw-supermemory") | Out-Null
}
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "plugins.entries.openclaw-supermemory.enabled", "true", "--json") | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "plugins.entries.openclaw-supermemory.config.apiKey", '${SUPERMEMORY_OPENCLAW_API_KEY}') | Out-Null

Write-Step "Bootstrapping tools + skills"
$bootstrapScript = @'
set -eu
WORKSPACE=/home/node/.openclaw/workspace
TMP_DIR="$WORKSPACE/tmp"
SKILLS_DIR="$WORKSPACE/skills"
TOOLS_DIR=/home/node/.openclaw/tools
CLAWHUB_BIN="$TOOLS_DIR/bin/clawhub"

mkdir -p "$TMP_DIR" "$SKILLS_DIR" "$TOOLS_DIR"

npm i -g clawhub --prefix "$TOOLS_DIR"
npm i -g @anthropic-ai/claude-code @openai/codex --prefix "$TOOLS_DIR"

rm -rf "$TMP_DIR/anthropics-skills"
git clone --depth 1 https://github.com/anthropics/skills "$TMP_DIR/anthropics-skills"
if [ -d "$TMP_DIR/anthropics-skills/skills" ]; then
  cp -a "$TMP_DIR/anthropics-skills/skills/." "$SKILLS_DIR/"
fi

rm -rf "$TMP_DIR/vercel-agent-skills"
git clone --depth 1 https://github.com/vercel-labs/agent-skills "$TMP_DIR/vercel-agent-skills"
if [ -d "$TMP_DIR/vercel-agent-skills/skills" ]; then
  cp -a "$TMP_DIR/vercel-agent-skills/skills/." "$SKILLS_DIR/"
fi

rm -rf "$TMP_DIR/openclaw-supermemory"
git clone --depth 1 https://github.com/supermemoryai/openclaw-supermemory "$TMP_DIR/openclaw-supermemory"

export PATH="$TOOLS_DIR/bin:$PATH"
cd "$WORKSPACE"
for slug in gmail github automation-workflows playwright-mcp summarize weather skill-creator openclaw-github-assistant github-mcp github-cli github-automation-pro; do
  "$CLAWHUB_BIN" install "$slug" || "$CLAWHUB_BIN" update "$slug" || true
done
'@
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "--entrypoint", "sh", "openclaw-cli", "-lc", $bootstrapScript) | Out-Null

Write-Step "Finalizing CLI backend commands"
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "agents.defaults.cliBackends[claude-cli].command", "/home/node/.openclaw/tools/bin/claude") | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "config", "set", "agents.defaults.cliBackends[codex-cli].command", "/home/node/.openclaw/tools/bin/codex") | Out-Null

Write-Step "Starting gateway"
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("up", "-d", "openclaw-gateway") | Out-Null
Start-Sleep -Seconds 2

Write-Step "Health check"
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("exec", "openclaw-gateway", "node", "dist/index.js", "health", "--json") | Out-Null

$dashboard = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -Args @("run", "--rm", "openclaw-cli", "dashboard", "--no-open") -Capture -IgnoreExitCode
$dashboardUrl = ""
$dashboardLines = @($dashboard.Output)
$dashboardMatch = $dashboardLines | Select-String "Dashboard URL:" | Select-Object -Last 1
if ($dashboardMatch) {
    $dashboardText = $dashboardMatch.ToString()
    if ($dashboardText -match "Dashboard URL:\s*(.+)$") {
        $dashboardUrl = $matches[1].Trim()
    }
}

Write-Step "Setup complete"
if ($dashboardUrl) {
    Write-Host "[openclaw-easy] Open this URL:"
    Write-Host $dashboardUrl
}
else {
    Write-Host "[openclaw-easy] Run this to print your URL:"
    Write-Host "cd $OpenClawSrcDir; $script:ComposeHint -f docker-compose.safe.yml run --rm openclaw-cli dashboard --no-open"
}

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $true
    $PSNativeCommandArgumentPassing = "Standard"
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

function New-HexToken {
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = New-Object byte[] 32
    $rng.GetBytes($bytes)
    return ($bytes | ForEach-Object { $_.ToString("x2") }) -join ""
}

function Is-Truthy {
    param([string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }
    return $Value.Trim().ToLowerInvariant() -in @("1", "true", "yes", "on")
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
        $composeProjectArgs = @()
        if ($script:ComposeProjectName) {
            $composeProjectArgs = @("-p", $script:ComposeProjectName)
        }
        $composeEnvArgs = @()
        if ($script:ComposeEnvFile -and (Test-Path $script:ComposeEnvFile)) {
            $composeEnvArgs = @("--env-file", $script:ComposeEnvFile)
        }
        $nativeErrorPref = $null
        $errorPref = $ErrorActionPreference
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            $nativeErrorPref = $PSNativeCommandUseErrorActionPreference
            $PSNativeCommandUseErrorActionPreference = $false
        }
        $ErrorActionPreference = "Continue"
        try {
            if ($Capture) {
                $output = & $script:ComposeCommand[0] @composeSuffix @composeProjectArgs @composeEnvArgs -f docker-compose.safe.yml @ComposeArgs 2>&1
            }
            else {
                & $script:ComposeCommand[0] @composeSuffix @composeProjectArgs @composeEnvArgs -f docker-compose.safe.yml @ComposeArgs
                $output = @()
            }
        }
        finally {
            $ErrorActionPreference = $errorPref
            if ($PSVersionTable.PSVersion.Major -ge 7 -and $null -ne $nativeErrorPref) {
                $PSNativeCommandUseErrorActionPreference = $nativeErrorPref
            }
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

function Convert-ToShSingleQuoted {
    param([string]$Value)
    if ($null -eq $Value) {
        return "''"
    }
    return "'" + $Value.Replace("'", "'""'""'") + "'"
}

function New-OpenClawCliLine {
    param([string[]]$CliArgs)
    $quoted = @($CliArgs | ForEach-Object { Convert-ToShSingleQuoted -Value "$_" })
    return "node dist/index.js " + ($quoted -join " ")
}

function Invoke-OpenClawCliBatch {
    param(
        [string]$OpenClawSrcDir,
        [string[]]$Lines,
        [switch]$Capture,
        [switch]$Quiet,
        [switch]$IgnoreExitCode
    )
    if (-not $Lines -or $Lines.Count -eq 0) {
        return [PSCustomObject]@{
            Code = 0
            Output = @()
        }
    }
    $script = (@("set -eu") + $Lines) -join "`n"
    $shouldCapture = $Capture.IsPresent -or $Quiet.IsPresent
    $result = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @(
        "run", "--rm", "--entrypoint", "sh", "openclaw-cli", "-lc", $script
    ) -Capture:$shouldCapture -IgnoreExitCode:$IgnoreExitCode
    if ($Quiet) {
        return [PSCustomObject]@{
            Code = $result.Code
            Output = @()
        }
    }
    return $result
}

function Set-ExecApprovalMode {
    param(
        [string]$OpenClawSrcDir,
        [bool]$AlwaysAllowExec
    )
    $askValue = if ($AlwaysAllowExec) { "off" } else { "on-miss" }
    $securityValue = if ($AlwaysAllowExec) { "full" } else { "allowlist" }
    Invoke-OpenClawCliBatch -OpenClawSrcDir $OpenClawSrcDir -Lines @(
        (New-OpenClawCliLine @("config", "set", "tools.exec.ask", $askValue)),
        (New-OpenClawCliLine @("config", "set", "tools.exec.security", $securityValue))
    ) -Quiet -IgnoreExitCode | Out-Null
}

function Get-DefaultDashboardUrl {
    $port = if ($env:OPENCLAW_GATEWAY_PORT) { $env:OPENCLAW_GATEWAY_PORT } else { "18789" }
    if ($env:OPENCLAW_GATEWAY_TOKEN) {
        return "http://127.0.0.1:$port/#token=$($env:OPENCLAW_GATEWAY_TOKEN)"
    }
    return "http://127.0.0.1:$port/"
}

function Ensure-TokenizedDashboardUrl {
    param([string]$Url)
    $token = $env:OPENCLAW_GATEWAY_TOKEN
    if (-not $Url) {
        return Get-DefaultDashboardUrl
    }
    if (-not $token) {
        return $Url
    }
    if ($Url -match "(^|[?#&])token=") {
        return $Url
    }
    if ($Url.Contains("#")) {
        if ($Url.EndsWith("#") -or $Url.EndsWith("&")) {
            return "$Url" + "token=$token"
        }
        return "$Url&token=$token"
    }
    return "$Url#token=$token"
}

function Approve-LocalPendingDevicePairings {
    param([string]$OpenClawSrcDir)
    $nodeScript = @'
import { approveDevicePairing, listDevicePairing } from "/app/dist/infra/device-pairing.js";

const baseDir = "/home/node/.openclaw";
const isLocalIp = (value) => {
  const ip = String(value ?? "").trim().toLowerCase();
  if (!ip) return false;
  return (
    ip === "127.0.0.1" ||
    ip === "::1" ||
    ip.startsWith("10.") ||
    ip.startsWith("172.") ||
    ip.startsWith("192.168.") ||
    ip.startsWith("fc") ||
    ip.startsWith("fd")
  );
};

const list = await listDevicePairing(baseDir);
let approved = 0;
for (const req of list.pending ?? []) {
  if (!isLocalIp(req.remoteIp)) continue;
  await approveDevicePairing(req.requestId, baseDir);
  approved += 1;
}
console.log(JSON.stringify({ pending: (list.pending ?? []).length, approved }));
'@
    $result = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("exec", "-T", "openclaw-gateway", "node", "--input-type=module", "-e", $nodeScript) -Capture -IgnoreExitCode
    if ($result.Code -ne 0) {
        return
    }
    $summaryLine = @($result.Output) | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -match "^\{.*\}$" } | Select-Object -Last 1
    if (-not $summaryLine) {
        return
    }
    try {
        $summary = $summaryLine | ConvertFrom-Json
        Write-Host "[openclaw-easy] pending=$($summary.pending) approved=$($summary.approved)"
    }
    catch {
        # no-op
    }
}

function Initialize-AgentMainSessions {
    param([string]$OpenClawSrcDir)
    $seedJson = '[{"id":"main","name":"Jarvis"},{"id":"dev","name":"Dev Agent"},{"id":"backend","name":"Backend Engineer"},{"id":"frontend","name":"Frontend Engineer (React)"},{"id":"designer","name":"Designer"},{"id":"ux","name":"UI/UX Expert"},{"id":"db","name":"Database Engineer"},{"id":"pm","name":"PM Agent"},{"id":"qa","name":"QA Agent"},{"id":"research","name":"Research Agent"},{"id":"ops","name":"Ops Agent"},{"id":"growth","name":"Growth Agent"},{"id":"finance","name":"Financial Expert"},{"id":"stocks","name":"Stock Analyzer"},{"id":"creative","name":"Creative Agent"},{"id":"motivation","name":"Motivation Agent"}]'
    $nodeScript = @'
import { loadConfig } from "/app/dist/config/config.js";
import { updateSessionStore } from "/app/dist/config/sessions.js";
import { resolveAgentMainSessionKey } from "/app/dist/config/sessions/main-session.js";
import { resolveGatewaySessionStoreTarget } from "/app/dist/gateway/session-utils.js";
import { applySessionsPatchToStore } from "/app/dist/gateway/sessions-patch.js";

const cfg = loadConfig();
const seed = JSON.parse(process.env.OPENCLAW_AGENT_SESSION_SEED ?? "[]");
for (const item of seed) {
  const agentId = String(item?.id ?? "").trim();
  const label = String(item?.name ?? "").trim();
  if (!agentId || !label) continue;
  const key = resolveAgentMainSessionKey({ cfg, agentId });
  const target = resolveGatewaySessionStoreTarget({ cfg, key });
  const storeKey = target.storeKeys[0] ?? key;
  await updateSessionStore(target.storePath, async (store) => {
    const existingKey = target.storeKeys.find((candidate) => store[candidate]);
    if (existingKey && existingKey !== storeKey && !store[storeKey]) {
      store[storeKey] = store[existingKey];
      delete store[existingKey];
    }
    const patched = await applySessionsPatchToStore({
      cfg,
      store,
      storeKey,
      patch: { key: storeKey, label },
    });
    if (!patched.ok) {
      throw new Error(patched.error?.message ?? `failed to patch session for ${agentId}`);
    }
    return patched.entry;
  });
}
'@
    $shellScript = @'
set -eu
cat > /tmp/openclaw-agent-session-seed.json <<'"'"'JSON'"'"'
__OPENCLAW_AGENT_SESSION_SEED__
JSON
cat > /tmp/openclaw-bootstrap-sessions.mjs <<'"'"'NODE'"'"'
__OPENCLAW_NODE_SCRIPT__
NODE
OPENCLAW_AGENT_SESSION_SEED="$(cat /tmp/openclaw-agent-session-seed.json)" node /tmp/openclaw-bootstrap-sessions.mjs
'@
    $shellScript = $shellScript.Replace("__OPENCLAW_AGENT_SESSION_SEED__", $seedJson)
    $shellScript = $shellScript.Replace("__OPENCLAW_NODE_SCRIPT__", $nodeScript)
    Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @(
        "run", "--rm",
        "--entrypoint", "sh",
        "openclaw-cli",
        "-lc",
        $shellScript
    ) -IgnoreExitCode | Out-Null
}

$RootDir = $PSScriptRoot
$EnvFile = Join-Path $RootDir ".env"
$SafeComposeTemplate = Join-Path $RootDir "docker-compose.safe.yml"
$script:ComposeCommand = Resolve-ComposeCommand

if (-not (Test-Path $EnvFile)) {
    throw ".env not found. Run start.ps1 first."
}

Import-DotEnv -Path $EnvFile
if (-not $env:OPENCLAW_GATEWAY_TOKEN) {
    $env:OPENCLAW_GATEWAY_TOKEN = New-HexToken
    Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_GATEWAY_TOKEN" -Value $env:OPENCLAW_GATEWAY_TOKEN
    Write-Step "Generated OPENCLAW_GATEWAY_TOKEN and saved it to .env"
}
if (-not $env:OPENCLAW_ALWAYS_ALLOW_EXEC) {
    $env:OPENCLAW_ALWAYS_ALLOW_EXEC = "false"
}
Upsert-DotEnvValue -Path $EnvFile -Key "OPENCLAW_ALWAYS_ALLOW_EXEC" -Value $env:OPENCLAW_ALWAYS_ALLOW_EXEC
$alwaysAllowExec = Is-Truthy -Value $env:OPENCLAW_ALWAYS_ALLOW_EXEC
$OpenClawSrcDir = if ($env:OPENCLAW_SRC_DIR) { $env:OPENCLAW_SRC_DIR } else { Join-Path (Join-Path $RootDir "vendor") "openclaw" }
if (-not (Test-Path $OpenClawSrcDir)) {
    throw "OpenClaw source not found at $OpenClawSrcDir. Run start.ps1 first."
}

$script:ComposeEnvFile = Join-Path $OpenClawSrcDir ".env"
Copy-Item -Path $EnvFile -Destination $script:ComposeEnvFile -Force
if (-not $env:COMPOSE_PROJECT_NAME) {
    $env:COMPOSE_PROJECT_NAME = "openclaw-easy"
}
$script:ComposeProjectName = $env:COMPOSE_PROJECT_NAME

if (Test-Path $SafeComposeTemplate) {
    Copy-Item -Path $SafeComposeTemplate -Destination (Join-Path $OpenClawSrcDir "docker-compose.safe.yml") -Force
}

Write-Step "Starting gateway"
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("up", "-d", "openclaw-gateway") | Out-Null

Write-Step "Reapplying gateway auth token"
Invoke-OpenClawCliBatch -OpenClawSrcDir $OpenClawSrcDir -Lines @(
    (New-OpenClawCliLine @("config", "set", "gateway.mode", "local")),
    (New-OpenClawCliLine @("config", "set", "gateway.auth.mode", "token")),
    (New-OpenClawCliLine @("config", "set", "gateway.auth.token", $env:OPENCLAW_GATEWAY_TOKEN)),
    (New-OpenClawCliLine @("config", "set", "gateway.controlUi.allowInsecureAuth", "true", "--json")),
    (New-OpenClawCliLine @("config", "set", "gateway.controlUi.dangerouslyDisableDeviceAuth", "true", "--json")),
    (New-OpenClawCliLine @("config", "set", "agents.list[0].subagents.allowAgents[0]", "*")) + " || true",
    (New-OpenClawCliLine @("config", "set", "tools.agentToAgent.enabled", "true", "--json")) + " || true",
    (New-OpenClawCliLine @("config", "unset", "tools.agentToAgent.allow")) + " || true",
    (New-OpenClawCliLine @("config", "set", "tools.agentToAgent.allow[0]", "*")) + " || true",
    (New-OpenClawCliLine @("config", "set", "commands.bash", "true", "--json")) + " || true",
    (New-OpenClawCliLine @("config", "set", "tools.elevated.enabled", "true", "--json")) + " || true",
    (New-OpenClawCliLine @("config", "unset", "tools.elevated.allowFrom.web")) + " || true",
    (New-OpenClawCliLine @("config", "unset", "tools.elevated.allowFrom.webchat")) + " || true",
    (New-OpenClawCliLine @("config", "set", "tools.elevated.allowFrom.webchat[0]", "*")) + " || true",
    (New-OpenClawCliLine @("config", "set", "tools.exec.ask", $(if ($alwaysAllowExec) { "off" } else { "on-miss" }))) + " || true",
    (New-OpenClawCliLine @("config", "set", "tools.exec.security", $(if ($alwaysAllowExec) { "full" } else { "allowlist" }))) + " || true",
    (New-OpenClawCliLine @("config", "set", "agents.defaults.cliBackends[codex-cli].command", "/home/node/.openclaw/tools/bin/codex")) + " || true",
    (New-OpenClawCliLine @("config", "set", "agents.defaults.cliBackends[codex-cli].env.OPENAI_API_KEY", '${OPENAI_API_KEY}')) + " || true",
    (New-OpenClawCliLine @("config", "set", "agents.defaults.memorySearch.enabled", "true", "--json")) + " || true",
    (New-OpenClawCliLine @("config", "set", "agents.defaults.memorySearch.provider", "openai")) + " || true",
    (New-OpenClawCliLine @("config", "unset", "agents.defaults.memorySearch.sources")) + " || true",
    (New-OpenClawCliLine @("config", "set", "agents.defaults.memorySearch.sources[0]", "memory")) + " || true",
    (New-OpenClawCliLine @("config", "set", "agents.defaults.memorySearch.sources[1]", "sessions")) + " || true",
    (New-OpenClawCliLine @("config", "set", "agents.defaults.memorySearch.experimental.sessionMemory", "true", "--json")) + " || true",
    (New-OpenClawCliLine @("config", "set", "agents.defaults.memorySearch.sync.onSessionStart", "true", "--json")) + " || true",
    (New-OpenClawCliLine @("config", "set", "agents.defaults.memorySearch.sync.onSearch", "true", "--json")) + " || true",
    (New-OpenClawCliLine @("config", "set", "browser.enabled", "true", "--json")) + " || true",
    (New-OpenClawCliLine @("config", "set", "browser.headless", "true", "--json")) + " || true",
    (New-OpenClawCliLine @("config", "set", "browser.noSandbox", "true", "--json")) + " || true"
) -Quiet | Out-Null
Set-ExecApprovalMode -OpenClawSrcDir $OpenClawSrcDir -AlwaysAllowExec $alwaysAllowExec
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @(
    "run", "--rm", "--entrypoint", "sh", "openclaw-cli", "-lc",
    'PROFILE_FILE=/home/node/.profile; if [ -f "$PROFILE_FILE" ]; then grep -Fq ''export PATH="$HOME/.local/bin:$HOME/.openclaw/tools/bin:$PATH"'' "$PROFILE_FILE" || echo ''export PATH="$HOME/.local/bin:$HOME/.openclaw/tools/bin:$PATH"'' >> "$PROFILE_FILE"; else echo ''export PATH="$HOME/.local/bin:$HOME/.openclaw/tools/bin:$PATH"'' > "$PROFILE_FILE"; fi'
) -IgnoreExitCode | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("up", "-d", "openclaw-gateway") | Out-Null
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "browser", "start", "--json") -IgnoreExitCode | Out-Null

Write-Step "Repairing local device pairing state"
Approve-LocalPendingDevicePairings -OpenClawSrcDir $OpenClawSrcDir
Initialize-AgentMainSessions -OpenClawSrcDir $OpenClawSrcDir
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "memory", "index", "--agent", "main") -IgnoreExitCode | Out-Null

Write-Step "Dashboard URL"
$configToken = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "gateway.auth.token") -Capture -IgnoreExitCode
if ($configToken.Code -eq 0) {
    $tokenLine = @($configToken.Output) | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -match "^[A-Za-z0-9._-]{16,}$" } | Select-Object -Last 1
    if ($tokenLine) {
        $env:OPENCLAW_GATEWAY_TOKEN = $tokenLine
    }
}
Write-Host (Ensure-TokenizedDashboardUrl -Url (Get-DefaultDashboardUrl))

Write-Step "Browser reset snippet (run in DevTools Console if mismatch persists)"
Write-Host 'localStorage.removeItem("openclaw.device.auth.v1");'
Write-Host 'localStorage.removeItem("openclaw-device-identity-v1");'
Write-Host 'localStorage.removeItem("openclaw.control.settings.v1");'
Write-Host "location.reload();"


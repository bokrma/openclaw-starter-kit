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

function Test-GatewayHttp {
    param([string]$Port)
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri "http://127.0.0.1:$Port/" -TimeoutSec 3
        return ($response.StatusCode -ge 200 -and $response.StatusCode -lt 500)
    }
    catch {
        return $false
    }
}

function Test-HttpStatus200 {
    param([string]$Url)
    try {
        $response = Invoke-WebRequest -UseBasicParsing -Uri $Url -TimeoutSec 5
        return ($response.StatusCode -eq 200)
    }
    catch {
        return $false
    }
}

function Get-GatewayContainerStatus {
    param([string]$OpenClawSrcDir)
    $raw = @()
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
        $raw = & $script:ComposeCommand[0] @composeSuffix @composeProjectArgs @composeEnvArgs -f docker-compose.safe.yml ps openclaw-gateway --format json 2>$null
        if ($LASTEXITCODE -ne 0) {
            return ""
        }
    }
    finally {
        Pop-Location
    }
    $line = @($raw) | Where-Object { $_ -and $_.ToString().Trim() -ne "" } | Select-Object -Last 1
    if (-not $line) {
        return ""
    }
    try {
        $obj = $line.ToString() | ConvertFrom-Json
        if ($obj.Status) {
            return $obj.Status.ToString()
        }
    }
    catch {}
    return $line.ToString()
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

function Invoke-MissionControlCompose {
    param(
        [string]$MissionControlSrcDir,
        [string[]]$ComposeArgs,
        [switch]$Capture,
        [switch]$IgnoreExitCode
    )
    Push-Location $MissionControlSrcDir
    try {
        $composeSuffix = @($script:ComposeCommand | Select-Object -Skip 1)
        $projectName = if ($script:ComposeProjectName) { "$($script:ComposeProjectName)-mission-control" } else { "openclaw-mission-control" }
        $composeProjectArgs = @("-p", $projectName)
        $composeEnvArgs = @()
        $missionControlEnv = Join-Path $MissionControlSrcDir ".env"
        if (Test-Path $missionControlEnv) {
            $composeEnvArgs = @("--env-file", $missionControlEnv)
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
                $output = & $script:ComposeCommand[0] @composeSuffix @composeProjectArgs @composeEnvArgs -f compose.yml @ComposeArgs 2>&1
            }
            else {
                & $script:ComposeCommand[0] @composeSuffix @composeProjectArgs @composeEnvArgs -f compose.yml @ComposeArgs
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
        throw "Mission Control docker compose failed (exit $code): $($ComposeArgs -join ' ')"
    }
    return [PSCustomObject]@{
        Code = $code
        Output = $output
    }
}

function Invoke-CommandCenterCompose {
    param(
        [string]$RootDir,
        [string[]]$ComposeArgs,
        [switch]$Capture,
        [switch]$IgnoreExitCode
    )
    $composeFile = Join-Path $RootDir "command-center.compose.yml"
    if (-not (Test-Path $composeFile)) {
        throw "Command Center compose file missing at $composeFile"
    }
    $composeSuffix = @($script:ComposeCommand | Select-Object -Skip 1)
    $projectName = if ($script:ComposeProjectName) { "$($script:ComposeProjectName)-command-center" } else { "openclaw-command-center" }
    $composeProjectArgs = @("-p", $projectName)
    $composeEnvArgs = @("--env-file", $EnvFile)
    $nativeErrorPref = $null
    $errorPref = $ErrorActionPreference
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $nativeErrorPref = $PSNativeCommandUseErrorActionPreference
        $PSNativeCommandUseErrorActionPreference = $false
    }
    $ErrorActionPreference = "Continue"
    try {
        if ($Capture) {
            $output = & $script:ComposeCommand[0] @composeSuffix @composeProjectArgs @composeEnvArgs -f $composeFile @ComposeArgs 2>&1
        }
        else {
            & $script:ComposeCommand[0] @composeSuffix @composeProjectArgs @composeEnvArgs -f $composeFile @ComposeArgs
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
    if (-not $IgnoreExitCode -and $code -ne 0) {
        throw "Command Center docker compose failed (exit $code): $($ComposeArgs -join ' ')"
    }
    return [PSCustomObject]@{
        Code = $code
        Output = $output
    }
}

$RootDir = $PSScriptRoot
$EnvFile = Join-Path $RootDir ".env"
$SafeComposeTemplate = Join-Path $RootDir "docker-compose.safe.yml"
$UnitTestFile = Join-Path (Join-Path $RootDir "tests") "start.unit.ps1"
$script:ComposeCommand = Resolve-ComposeCommand

if (-not (Test-Path $EnvFile)) {
    throw ".env not found. Run start.ps1 first."
}

if (Test-Path $UnitTestFile) {
    Write-Step "Unit tests"
    & $UnitTestFile
}

Import-DotEnv -Path $EnvFile

$OpenClawSrcDir = if ($env:OPENCLAW_SRC_DIR) { $env:OPENCLAW_SRC_DIR } else { Join-Path (Join-Path $RootDir "vendor") "openclaw" }
if (-not (Test-Path $OpenClawSrcDir)) {
    throw "OpenClaw source not found at $OpenClawSrcDir. Run start.ps1 first."
}
$script:ComposeEnvFile = Join-Path $OpenClawSrcDir ".env"
if (-not (Test-Path $script:ComposeEnvFile)) {
    Copy-Item -Path $EnvFile -Destination $script:ComposeEnvFile -Force
}
if (-not $env:COMPOSE_PROJECT_NAME) { $env:COMPOSE_PROJECT_NAME = "openclaw-easy" }
$script:ComposeProjectName = $env:COMPOSE_PROJECT_NAME
if (-not $env:OPENCLAW_SAFE_PROJECT_NAME) { $env:OPENCLAW_SAFE_PROJECT_NAME = $script:ComposeProjectName }

$safeComposeTarget = Join-Path $OpenClawSrcDir "docker-compose.safe.yml"
if (-not (Test-Path $SafeComposeTemplate)) {
    throw "Missing starter compose template: $SafeComposeTemplate"
}
Copy-Item -Path $SafeComposeTemplate -Destination $safeComposeTarget -Force
Write-Step "Synced docker-compose.safe.yml into cloned OpenClaw repo"

Write-Step "Gateway container status"
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("ps") | Out-Null

Write-Step "Gateway health"
$port = if ($env:OPENCLAW_GATEWAY_PORT) { $env:OPENCLAW_GATEWAY_PORT } else { "18789" }
$gatewayReady = $false
for ($attempt = 1; $attempt -le 30; $attempt++) {
    if (Test-GatewayHttp -Port $port) {
        $gatewayReady = $true
        break
    }
    if ($attempt -eq 1 -or ($attempt % 5) -eq 0) {
        $status = Get-GatewayContainerStatus -OpenClawSrcDir $OpenClawSrcDir
        if ($status) {
            Write-Host "[openclaw-easy] gateway status: $status"
        }
    }
    Start-Sleep -Seconds 2
}
if (-not $gatewayReady) {
    Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("logs", "--tail=120", "openclaw-gateway") -IgnoreExitCode | Out-Null
    throw "Gateway HTTP endpoint is not reachable at http://127.0.0.1:$port/"
}

Write-Step "Control UI auth bypass settings"
$allowInsecure = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "gateway.controlUi.allowInsecureAuth") -Capture -IgnoreExitCode
$disableDeviceAuth = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "gateway.controlUi.dangerouslyDisableDeviceAuth") -Capture -IgnoreExitCode
$allowValue = @($allowInsecure.Output) | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Where-Object { $_ -eq "true" } | Select-Object -First 1
$disableValue = @($disableDeviceAuth.Output) | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Where-Object { $_ -eq "true" } | Select-Object -First 1
if (-not $allowValue -or -not $disableValue) {
    throw "Control UI auth bypass is not enabled (gateway.controlUi.allowInsecureAuth=true and gateway.controlUi.dangerouslyDisableDeviceAuth=true are required)."
}

Write-Step "Elevated shell defaults"
$bashEnabledRaw = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "commands.bash") -Capture -IgnoreExitCode
$elevatedEnabledRaw = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "tools.elevated.enabled") -Capture -IgnoreExitCode
$elevatedWebRaw = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "tools.elevated.allowFrom.webchat[0]") -Capture -IgnoreExitCode
$bashEnabled = @($bashEnabledRaw.Output) | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Where-Object { $_ -eq "true" } | Select-Object -First 1
$elevatedEnabled = @($elevatedEnabledRaw.Output) | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Where-Object { $_ -eq "true" } | Select-Object -First 1
$elevatedWeb = @($elevatedWebRaw.Output) | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ } | Select-Object -Last 1
if (-not $bashEnabled -or -not $elevatedEnabled -or $elevatedWeb -ne "*") {
    throw "Elevated shell defaults are not set correctly. Expected commands.bash=true, tools.elevated.enabled=true, tools.elevated.allowFrom.webchat[0]=*."
}

Write-Step "Codex auth wiring"
$codexBackendCmdRaw = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "agents.defaults.cliBackends[codex-cli].command") -Capture -IgnoreExitCode
$codexBackendCmd = @($codexBackendCmdRaw.Output) | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ } | Select-Object -Last 1
if ($codexBackendCmd -ne "/home/node/.openclaw/tools/bin/codex") {
    throw "Codex backend command is not set correctly. Expected /home/node/.openclaw/tools/bin/codex."
}
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("exec", "-T", "openclaw-gateway", "sh", "-lc", '[ -n "$OPENAI_API_KEY" ]') | Out-Null

Write-Step "Gateway sudo/apt probe"
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("exec", "-T", "openclaw-gateway", "sh", "-lc", "command -v apt-get >/dev/null && (apt-get --version >/dev/null || (command -v sudo >/dev/null && sudo -n apt-get --version >/dev/null))") | Out-Null

Write-Step "Container mount isolation"
$gatewayIdResult = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("ps", "-q", "openclaw-gateway") -Capture -IgnoreExitCode
$gatewayContainerId = @($gatewayIdResult.Output) | ForEach-Object { $_.ToString().Trim() } | Where-Object { $_ -match "^[0-9a-f]{12,}$" } | Select-Object -First 1
if (-not $gatewayContainerId) {
    throw "Could not resolve openclaw-gateway container id for mount isolation check."
}
$mountsJson = & docker inspect --format "{{json .Mounts}}" $gatewayContainerId 2>$null
if ($LASTEXITCODE -ne 0 -or -not $mountsJson) {
    throw "Could not inspect openclaw-gateway mounts for isolation check."
}
try {
    $mounts = $mountsJson | ConvertFrom-Json
    $bindMounts = @($mounts | Where-Object { $_.Type -eq "bind" })
    if ($bindMounts.Count -gt 0) {
        throw "openclaw-gateway has bind mounts. For container-only isolation, bind mounts are not allowed."
    }
}
catch {
    if ($_ -is [System.Management.Automation.RuntimeException]) {
        throw
    }
    throw "Could not parse openclaw-gateway mounts for isolation check."
}

Write-Step "Memory defaults"
$memoryEnabledRaw = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "agents.defaults.memorySearch.enabled") -Capture -IgnoreExitCode
$memoryProviderRaw = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "agents.defaults.memorySearch.provider") -Capture -IgnoreExitCode
$memorySource0Raw = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "agents.defaults.memorySearch.sources[0]") -Capture -IgnoreExitCode
$memorySource1Raw = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "agents.defaults.memorySearch.sources[1]") -Capture -IgnoreExitCode
$sessionMemoryRaw = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "agents.defaults.memorySearch.experimental.sessionMemory") -Capture -IgnoreExitCode
$syncStartRaw = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "agents.defaults.memorySearch.sync.onSessionStart") -Capture -IgnoreExitCode
$syncSearchRaw = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "agents.defaults.memorySearch.sync.onSearch") -Capture -IgnoreExitCode

$memoryEnabled = @($memoryEnabledRaw.Output) | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Where-Object { $_ -eq "true" } | Select-Object -First 1
$memoryProvider = @($memoryProviderRaw.Output) | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Last 1
$memorySource0 = @($memorySource0Raw.Output) | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Last 1
$memorySource1 = @($memorySource1Raw.Output) | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Where-Object { $_ } | Select-Object -Last 1
$sessionMemory = @($sessionMemoryRaw.Output) | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Where-Object { $_ -eq "true" } | Select-Object -First 1
$syncStart = @($syncStartRaw.Output) | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Where-Object { $_ -eq "true" } | Select-Object -First 1
$syncSearch = @($syncSearchRaw.Output) | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Where-Object { $_ -eq "true" } | Select-Object -First 1

if (-not $memoryEnabled -or $memoryProvider -ne "openai" -or $memorySource0 -ne "memory" -or $memorySource1 -ne "sessions" -or -not $sessionMemory -or -not $syncStart -or -not $syncSearch) {
    throw "Memory defaults are not set correctly. Expected enabled=true, provider=openai, sources=[memory,sessions], experimental.sessionMemory=true, sync.onSessionStart=true, sync.onSearch=true."
}

Write-Step "Memory command probe"
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "memory", "status", "--agent", "main", "--json") | Out-Null

Write-Step "Browser defaults"
$browserEnabledRaw = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "browser.enabled") -Capture -IgnoreExitCode
$browserHeadlessRaw = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "browser.headless") -Capture -IgnoreExitCode
$browserNoSandboxRaw = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "config", "get", "browser.noSandbox") -Capture -IgnoreExitCode
$browserEnabled = @($browserEnabledRaw.Output) | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Where-Object { $_ -eq "true" } | Select-Object -First 1
$browserHeadless = @($browserHeadlessRaw.Output) | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Where-Object { $_ -eq "true" } | Select-Object -First 1
$browserNoSandbox = @($browserNoSandboxRaw.Output) | ForEach-Object { $_.ToString().Trim().ToLowerInvariant() } | Where-Object { $_ -eq "true" } | Select-Object -First 1
if (-not $browserEnabled -or -not $browserHeadless -or -not $browserNoSandbox) {
    throw "Browser defaults are not set correctly. Expected browser.enabled=true, browser.headless=true, browser.noSandbox=true."
}

Write-Step "Browser control service"
$browserProbe = Test-BrowserControlService -OpenClawSrcDir $OpenClawSrcDir
if (-not $browserProbe.Ready) {
    throw "Browser control service probe failed: $($browserProbe.Detail)"
}

$agentManifestPath = Join-Path (Join-Path (Join-Path $RootDir "openclaw-agents") "agents") "manifest.json"
if (-not (Test-Path $agentManifestPath)) {
    throw "Agent manifest is missing: $agentManifestPath"
}
$agentManifestRaw = Get-Content -Path $agentManifestPath -Raw
$agentManifest = $agentManifestRaw | ConvertFrom-Json
$agentManifestEntries = @(
    foreach ($item in @($agentManifest.agents)) {
        [PSCustomObject]@{
            id = "$($item.id)".Trim()
            name = "$($item.name)".Trim()
            default = [bool]$item.default
        }
    }
)
$agentManifestJson = $agentManifestEntries | ConvertTo-Json -Compress

Write-Step "Checking agent pack + coordinator wiring"
$agentCheckScript = @'
import { loadConfig } from "/app/dist/config/config.js";
import { loadSessionStore } from "/app/dist/config/sessions.js";
import { resolveAgentMainSessionKey } from "/app/dist/config/sessions/main-session.js";
import { resolveGatewaySessionStoreTarget } from "/app/dist/gateway/session-utils.js";
import { normalizeAgentId } from "/app/dist/routing/session-key.js";

const manifestAgentsRaw = JSON.parse(process.env.OPENCLAW_AGENT_MANIFEST ?? "[]");
const manifestAgents = Array.isArray(manifestAgentsRaw) ? manifestAgentsRaw : [];
const required = manifestAgents
  .map((item) => normalizeAgentId(String(item?.id ?? "")))
  .filter((id) => Boolean(id));

const cfg = loadConfig();
const agents = Array.isArray(cfg.agents?.list) ? cfg.agents.list : [];
const byId = new Map();
for (const entry of agents) {
  const id = normalizeAgentId(String(entry?.id ?? ""));
  if (!id) continue;
  byId.set(id, entry);
}

const issues = [];
if (required.length === 0) {
  issues.push("agent manifest is empty; expected at least one agent");
}
const missingAgents = required.filter((id) => !byId.has(id));
if (missingAgents.length > 0) {
  issues.push(`missing agents: ${missingAgents.join(", ")}`);
}

const main = byId.get("main");
const mainName = String(main?.name ?? "").trim();
const defaultManifestAgent =
  manifestAgents.find((item) => item?.default === true) ??
  manifestAgents.find((item) => normalizeAgentId(String(item?.id ?? "")) === "main");
const expectedMainName = String(defaultManifestAgent?.name ?? "Jarvis").trim();
if (mainName !== expectedMainName) {
  issues.push(
    `main agent name should be ${expectedMainName || "Jarvis"} (found: ${mainName || "<empty>"})`,
  );
}
const allowAgents = Array.isArray(main?.subagents?.allowAgents)
  ? main.subagents.allowAgents.map((value) => String(value).trim())
  : [];
if (!allowAgents.includes("*")) {
  issues.push('main agent must allow cross-agent orchestration via subagents.allowAgents=["*"]');
}

const missingSessions = [];
for (const id of required) {
  const key = resolveAgentMainSessionKey({ cfg, agentId: id });
  const target = resolveGatewaySessionStoreTarget({ cfg, key });
  const store = loadSessionStore(target.storePath);
  const storeKey = target.storeKeys[0] ?? key;
  if (!store[storeKey]) {
    missingSessions.push(storeKey);
  }
}
if (missingSessions.length > 0) {
  issues.push(`missing agent main sessions: ${missingSessions.join(", ")}`);
}

if (issues.length > 0) {
  for (const issue of issues) {
    console.error(issue);
  }
  process.exit(1);
}

console.log("ok");
'@
$agentCheckShell = @'
set -eu
cat > /tmp/openclaw-agent-check.mjs <<'"'"'NODE'"'"'
__OPENCLAW_AGENT_CHECK_SCRIPT__
NODE
cat > /tmp/openclaw-agent-manifest.json <<'"'"'JSON'"'"'
__OPENCLAW_AGENT_MANIFEST_JSON__
JSON
OPENCLAW_AGENT_MANIFEST="$(cat /tmp/openclaw-agent-manifest.json)" node /tmp/openclaw-agent-check.mjs
'@
$agentCheckShell = $agentCheckShell.Replace("__OPENCLAW_AGENT_CHECK_SCRIPT__", $agentCheckScript)
$agentCheckShell = $agentCheckShell.Replace("__OPENCLAW_AGENT_MANIFEST_JSON__", $agentManifestJson)

$agentCheckResult = Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @(
    "run", "--rm", "--entrypoint", "sh", "openclaw-cli", "-lc", $agentCheckShell
) -Capture -IgnoreExitCode
if ($agentCheckResult.Code -ne 0) {
    foreach ($line in @($agentCheckResult.Output)) {
        Write-Host $line
    }
    throw "Agent pack + coordinator wiring validation failed."
}

$supermemoryEnabled = if ($env:OPENCLAW_ENABLE_SUPERMEMORY) { $env:OPENCLAW_ENABLE_SUPERMEMORY } elseif ($env:SUPERMEMORY_OPENCLAW_API_KEY) { "true" } else { "false" }
if ($supermemoryEnabled -eq "true") {
    Write-Step "Supermemory plugin status"
    Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "plugins", "info", "openclaw-supermemory") | Out-Null
}
else {
    Write-Step "Supermemory plugin check skipped (disabled)"
}

Write-Step "Checking required skills/tools"
$checkScript = @'
set -eu
required="gmail github automation-workflows playwright-mcp summarize weather skill-creator openclaw-github-assistant github-mcp github-cli github-automation-pro downloads agent-council agentlens aster bidclub claude-optimised create-agent-skills anthropic-frontend-design ui-audit 2captcha agent-zero-bridge agent-browser-2 dating local-places clawexchange clawdwork deep-research web-qa-bot verify-on-browser home-assistant playwright-cli quality-manager-qmr skill-scaffold tdd-guide cto-advisor evolver coding-agent"
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

if [ -d /home/node/.openclaw/workspace/tmp/openclaw-community-skills ]; then
  echo "ok: openclaw community skills repo synced"
else
  echo "missing: openclaw community skills repo clone"
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
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "--entrypoint", "sh", "openclaw-cli", "-lc", $checkScript) | Out-Null

Write-Step "Checking required CLIs"
$cliScript = @'
set -eu
/home/node/.openclaw/tools/bin/clawhub -V || /home/node/.openclaw/tools/bin/clawhub --cli-version
/home/node/.openclaw/tools/bin/openclaw --version
/home/node/.openclaw/tools/bin/claude --version
/home/node/.openclaw/tools/bin/codex --version
/home/node/.openclaw/tools/bin/agent-browser --version
/home/node/.openclaw/tools/bin/playwright --version
python3 --version
python3 -m pip --version
echo "$PATH" | grep -F "/home/node/.local/bin" >/dev/null
echo "$PATH" | grep -F "/home/node/.openclaw/tools/bin" >/dev/null
'@
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "--entrypoint", "sh", "openclaw-cli", "-lc", $cliScript) | Out-Null

Write-Step "agent-browser CLI smoke test"
$agentBrowserScript = @'
set -eu
node dist/index.js browser status --json >/dev/null
/home/node/.openclaw/tools/bin/agent-browser open https://example.com >/dev/null 2>&1 || true
/home/node/.openclaw/tools/bin/agent-browser close >/dev/null 2>&1 || true
'@
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("exec", "-T", "openclaw-gateway", "sh", "-lc", $agentBrowserScript) | Out-Null

Write-Step "Dashboard URL"
Invoke-Compose -OpenClawSrcDir $OpenClawSrcDir -ComposeArgs @("run", "--rm", "openclaw-cli", "dashboard", "--no-open") | Out-Null

if (Is-Truthy -Value $env:OPENCLAW_ENABLE_MISSION_CONTROL) {
    Write-Step "Mission Control dashboard"
    $MissionControlSrcDir = if ($env:OPENCLAW_MISSION_CONTROL_SRC_DIR) { $env:OPENCLAW_MISSION_CONTROL_SRC_DIR } else { Join-Path (Join-Path $RootDir "vendor") "openclaw-mission-control" }
    if (-not (Test-Path $MissionControlSrcDir)) {
        throw "Mission Control source not found at $MissionControlSrcDir"
    }
    if (-not (Test-Path (Join-Path $MissionControlSrcDir "compose.yml"))) {
        throw "Mission Control compose file missing at $MissionControlSrcDir/compose.yml"
    }
    Invoke-MissionControlCompose -MissionControlSrcDir $MissionControlSrcDir -ComposeArgs @("ps") | Out-Null
    $missionControlFrontendPort = if ($env:OPENCLAW_MISSION_CONTROL_FRONTEND_PORT) { $env:OPENCLAW_MISSION_CONTROL_FRONTEND_PORT } else { "3000" }
    $missionControlUrl = "http://127.0.0.1:$missionControlFrontendPort/"
    if (-not (Test-HttpStatus200 -Url $missionControlUrl)) {
        $mcLogs = Invoke-MissionControlCompose -MissionControlSrcDir $MissionControlSrcDir -ComposeArgs @("logs", "--tail=120", "frontend", "backend") -Capture -IgnoreExitCode
        foreach ($line in @($mcLogs.Output)) {
            Write-Host $line
        }
        throw "Mission Control dashboard check failed. Expected HTTP 200 at $missionControlUrl"
    }
}

if (Is-Truthy -Value $env:OPENCLAW_ENABLE_COMMAND_CENTER) {
    Write-Step "Command Center dashboard"
    $commandCenterCompose = Join-Path $RootDir "command-center.compose.yml"
    if (-not (Test-Path $commandCenterCompose)) {
        throw "Command Center compose file missing at $commandCenterCompose"
    }
    Invoke-CommandCenterCompose -RootDir $RootDir -ComposeArgs @("ps") | Out-Null
    $commandCenterPort = if ($env:OPENCLAW_COMMAND_CENTER_PORT) { $env:OPENCLAW_COMMAND_CENTER_PORT } else { "3340" }
    $commandCenterUrl = "http://127.0.0.1:$commandCenterPort/"
    if (-not (Test-HttpStatus200 -Url $commandCenterUrl)) {
        $ccLogs = Invoke-CommandCenterCompose -RootDir $RootDir -ComposeArgs @("logs", "--tail=120", "openclaw-command-center") -Capture -IgnoreExitCode
        foreach ($line in @($ccLogs.Output)) {
            Write-Host $line
        }
        throw "Command Center dashboard check failed. Expected HTTP 200 at $commandCenterUrl"
    }
}

Write-Step "Verification passed"


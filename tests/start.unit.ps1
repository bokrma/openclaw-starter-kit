$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$startScript = Join-Path $rootDir "start.ps1"

$env:OPENCLAW_EASY_TEST_MODE = "1"
. $startScript
Remove-Item Env:OPENCLAW_EASY_TEST_MODE -ErrorAction SilentlyContinue

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

function Assert-Equal {
    param(
        [string]$Expected,
        [string]$Actual,
        [string]$Message
    )
    if ($Expected -ne $Actual) {
        throw "Assertion failed: $Message. Expected '$Expected', got '$Actual'."
    }
}

$token = New-HexToken
Assert-True ($token.Length -eq 64) "New-HexToken should generate 64 hex chars"
Assert-True ($token -match "^[0-9a-f]{64}$") "New-HexToken should be lowercase hex"

$ansi = "$([char]27)[36mDashboard URL:$([char]27)[39m http://127.0.0.1:18789/"
$stripped = Strip-Ansi $ansi
Assert-Equal "Dashboard URL: http://127.0.0.1:18789/" $stripped "Strip-Ansi should remove ANSI sequences"

$oldPort = $env:OPENCLAW_GATEWAY_PORT
$oldToken = $env:OPENCLAW_GATEWAY_TOKEN

$env:OPENCLAW_GATEWAY_PORT = "19999"
$env:OPENCLAW_GATEWAY_TOKEN = "abc123"
Assert-Equal "http://127.0.0.1:19999/#token=abc123" (Get-DefaultDashboardUrl) "Get-DefaultDashboardUrl should include token"
Assert-Equal "http://127.0.0.1:19999/#token=abc123" (Ensure-TokenizedDashboardUrl "http://127.0.0.1:19999/") "Ensure-TokenizedDashboardUrl should append token"
Assert-Equal "http://127.0.0.1:19999/#token=existing" (Ensure-TokenizedDashboardUrl "http://127.0.0.1:19999/#token=existing") "Ensure-TokenizedDashboardUrl should keep existing token"
$plugins = Parse-ChannelPluginList "telegram, whatsapp  telegram"
Assert-True ($plugins.Count -eq 2) "Parse-ChannelPluginList should dedupe plugin ids"
Assert-Equal "telegram" $plugins[0] "Parse-ChannelPluginList should keep order"
Assert-Equal "whatsapp" $plugins[1] "Parse-ChannelPluginList should keep order"

$detectedRepo = Find-LocalOpenClawRepo -BaseDir $rootDir
if ($detectedRepo) {
    Assert-True (Test-Path (Join-Path $detectedRepo "Dockerfile")) "Find-LocalOpenClawRepo should return an OpenClaw root"
}

$env:OPENCLAW_GATEWAY_TOKEN = ""
Assert-Equal "http://127.0.0.1:19999/" (Get-DefaultDashboardUrl) "Get-DefaultDashboardUrl should fallback without token"

if ($null -ne $oldPort) { $env:OPENCLAW_GATEWAY_PORT = $oldPort } else { Remove-Item Env:OPENCLAW_GATEWAY_PORT -ErrorAction SilentlyContinue }
if ($null -ne $oldToken) { $env:OPENCLAW_GATEWAY_TOKEN = $oldToken } else { Remove-Item Env:OPENCLAW_GATEWAY_TOKEN -ErrorAction SilentlyContinue }

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("openclaw-easy-unit-" + [System.Guid]::NewGuid().ToString() + ".env")
@(
    "OPENAI_API_KEY=old",
    "OTHER=1",
    "OPENAI_API_KEY=duplicate"
) | Set-Content -Path $tmp -Encoding ascii

Upsert-DotEnvValue -Path $tmp -Key "OPENAI_API_KEY" -Value "new"
$lines = Get-Content -Path $tmp
$openAiLines = @($lines | Where-Object { $_ -match "^OPENAI_API_KEY=" })

Assert-True ($openAiLines.Count -eq 1) "Upsert-DotEnvValue should keep one key entry"
Assert-Equal "OPENAI_API_KEY=new" $openAiLines[0] "Upsert-DotEnvValue should write latest value"

Assert-True (Test-PrivateOrLoopbackIp "127.0.0.1") "Loopback IPv4 should be local"
Assert-True (Test-PrivateOrLoopbackIp "::1") "Loopback IPv6 should be local"
Assert-True (Test-PrivateOrLoopbackIp "172.24.0.1") "Docker subnet should be local"
Assert-True (Test-PrivateOrLoopbackIp "192.168.1.50") "Private LAN should be local"
Assert-True (-not (Test-PrivateOrLoopbackIp "8.8.8.8")) "Public IP should not be local"

$resolvedContainerId = Resolve-ContainerId @(
    "Run 'docker compose COMMAND --help' for more information on a command."
    "7f38a4a309bc"
)
Assert-Equal "7f38a4a309bc" $resolvedContainerId "Resolve-ContainerId should ignore non-id lines"
Assert-Equal "" (Resolve-ContainerId @("Usage: docker compose [OPTIONS] COMMAND")) "Resolve-ContainerId should return empty when no id exists"

$invokeComposeParams = (Get-Command Invoke-Compose).Parameters.Keys
Assert-True ($invokeComposeParams -contains "ComposeArgs") "Invoke-Compose should expose ComposeArgs parameter"
Assert-True (-not ($invokeComposeParams -contains "Args")) "Invoke-Compose should not use reserved Args parameter"

$verifyScriptText = Get-Content -Path (Join-Path $rootDir "verify.ps1") -Raw
Assert-True ($verifyScriptText -match '\[string\[\]\]\$ComposeArgs') "verify.ps1 should use ComposeArgs parameter"
Assert-True (-not ($verifyScriptText -match '\[string\[\]\]\$Args')) "verify.ps1 should not use reserved Args parameter"

$repairScriptText = Get-Content -Path (Join-Path $rootDir "repair-auth.ps1") -Raw
Assert-True ($repairScriptText -match '\[string\[\]\]\$ComposeArgs') "repair-auth.ps1 should use ComposeArgs parameter"
Assert-True (-not ($repairScriptText -match '\[string\[\]\]\$Args')) "repair-auth.ps1 should not use reserved Args parameter"
Assert-True ($repairScriptText -match "dist/infra/device-pairing\.js") "repair-auth.ps1 should use infra device-pairing module"
Assert-True (-not ($repairScriptText -match "dist/plugin-sdk/index\.js")) "repair-auth.ps1 should not import device pairing from plugin-sdk"
Assert-True ($repairScriptText -match 'gateway\.controlUi\.allowInsecureAuth", "true", "--json"') "repair-auth.ps1 should enable control UI insecure auth bypass"
Assert-True ($repairScriptText -match 'gateway\.controlUi\.dangerouslyDisableDeviceAuth", "true", "--json"') "repair-auth.ps1 should disable control UI device auth pairing"
Assert-True ($repairScriptText -match 'agents\.list\[\$i\]\.subagents\.allowAgents\[0\]", "\*"') "repair-auth.ps1 should preserve Jarvis cross-agent orchestration"
Assert-True ($repairScriptText -match 'tools\.agentToAgent\.enabled", "true", "--json"') "repair-auth.ps1 should enable agent-to-agent"
Assert-True ($repairScriptText -match 'commands\.bash", "true", "--json"') "repair-auth.ps1 should enable bash command"
Assert-True ($repairScriptText -match 'tools\.elevated\.enabled", "true", "--json"') "repair-auth.ps1 should enable elevated tooling"
Assert-True ($repairScriptText -match 'tools\.elevated\.allowFrom\.webchat\[0\]", "\*"') "repair-auth.ps1 should allow elevated tooling from webchat channel"
Assert-True ($repairScriptText -match 'OPENCLAW_ALWAYS_ALLOW_EXEC') "repair-auth.ps1 should read OPENCLAW_ALWAYS_ALLOW_EXEC"
Assert-True ($repairScriptText -match 'tools\.exec\.ask", \$\(if \(\$alwaysAllowExec\) \{ "off" \} else \{ "on-miss" \}\)') "repair-auth.ps1 should toggle tools.exec.ask from env"
Assert-True ($repairScriptText -match 'tools\.exec\.security", \$\(if \(\$alwaysAllowExec\) \{ "full" \} else \{ "allowlist" \}\)') "repair-auth.ps1 should toggle tools.exec.security from env"
Assert-True ($repairScriptText -match 'agents\.defaults\.cliBackends\[codex-cli\]\.command", "/home/node/\.openclaw/tools/bin/codex"') "repair-auth.ps1 should set codex backend command path"
Assert-True ($repairScriptText -match 'agents\.defaults\.cliBackends\[codex-cli\]\.env\.OPENAI_API_KEY' -and $repairScriptText -match '\$\{OPENAI_API_KEY\}') "repair-auth.ps1 should wire codex backend OPENAI_API_KEY from env reference"
Assert-True ($repairScriptText -match "Initialize-AgentMainSessions") "repair-auth.ps1 should bootstrap agent main sessions"
Assert-True ($repairScriptText -match 'agents\.defaults\.memorySearch\.enabled", "true", "--json"') "repair-auth.ps1 should enable memory search"
Assert-True ($repairScriptText -match 'agents\.defaults\.memorySearch\.sources\[0\]", "memory"') "repair-auth.ps1 should set memory source"
Assert-True ($repairScriptText -match 'agents\.defaults\.memorySearch\.sources\[1\]", "sessions"') "repair-auth.ps1 should set sessions source"
Assert-True ($repairScriptText -match 'memory", "index", "--agent", "main"') "repair-auth.ps1 should run memory index for main"
Assert-True ($repairScriptText -match '\.local/bin:\$HOME/\.openclaw/tools/bin') "repair-auth.ps1 should persist ~/.local/bin and ~/.openclaw/tools/bin PATH in profile"
Assert-True ($repairScriptText -match 'config", "set", "browser\.enabled", "true", "--json"') "repair-auth.ps1 should ensure browser.enabled"
Assert-True ($repairScriptText -match 'config", "set", "browser\.headless", "true", "--json"') "repair-auth.ps1 should ensure browser.headless"
Assert-True ($repairScriptText -match 'config", "set", "browser\.noSandbox", "true", "--json"') "repair-auth.ps1 should ensure browser.noSandbox"
Assert-True ($repairScriptText -match '"browser", "start", "--json"') "repair-auth.ps1 should attempt browser start after auth repair"

$doctorScriptText = Get-Content -Path (Join-Path $rootDir "doctor.ps1") -Raw
Assert-True ($doctorScriptText -match "Running start") "doctor.ps1 should run start phase"
Assert-True ($doctorScriptText -match "Running verify") "doctor.ps1 should run verify phase"
Assert-True ($doctorScriptText -match '"browser", "status", "--json"') "doctor.ps1 should run browser status probe"
Assert-True ($doctorScriptText -match 'Write-Step "PASS"') "doctor.ps1 should print PASS summary"

$startScriptText = Get-Content -Path (Join-Path $rootDir "start.ps1") -Raw
$missionControlSeedScript = Join-Path $rootDir "scripts/mission_control/seed_starter_pack.py"
$missionControlSeedScriptText = if (Test-Path $missionControlSeedScript) { Get-Content -Path $missionControlSeedScript -Raw } else { "" }
Assert-True ($startScriptText -match 'agents\.defaults\.model\.primary", "openai/gpt-5\.2"') "start.ps1 should default to openai/gpt-5.2"
Assert-True ($startScriptText -match 'agents\.defaults\.model\.fallbacks\[0\]", "openai/gpt-5-mini"') "start.ps1 should set openai/gpt-5-mini fallback"
Assert-True (-not ($startScriptText -match "openai/gpt-5\.2-codex")) "start.ps1 should not default to openai/gpt-5.2-codex"
Assert-True ($startScriptText -match 'OPENCLAW_DOCKER_APT_PACKAGES = "chromium git python3 python3-pip sudo"') "start.ps1 should default apt packages with python3, pip, and sudo"
Assert-True ($startScriptText -match 'python3-pip') "start.ps1 should enforce python3-pip apt package"
Assert-True ($startScriptText -match 'sudo') "start.ps1 should enforce sudo apt package"
Assert-True ($startScriptText -match 'npm i -g @anthropic-ai/claude-code @openai/codex playwright --prefix "\$TOOLS_DIR"') "start.ps1 should install playwright CLI tool in tools prefix"
Assert-True ($startScriptText -match 'cat > "\$TOOLS_DIR/bin/openclaw"') "start.ps1 should create openclaw CLI wrapper"
Assert-True ($startScriptText -match 'cat > "\$TOOLS_DIR/bin/agent-browser"') "start.ps1 should create agent-browser CLI wrapper"
Assert-True ($startScriptText -match 'install --with-deps chromium') "start.ps1 should install playwright chromium browser with deps fallback"
Assert-True ($startScriptText -match 'https://github\.com/openclaw/skills') "start.ps1 should clone openclaw community skills repo"
Assert-True ($startScriptText -match 'openclaw-community-skills') "start.ps1 should stage openclaw community skills in workspace tmp"
Assert-True ($startScriptText -match 'nextfrontierbuilds/web-qa-bot') "start.ps1 should include requested community skill list"
Assert-True ($startScriptText -match 'install "\$slug" --force') "start.ps1 should force-install skills for non-interactive setup"
Assert-True ($startScriptText -match "dist/infra/device-pairing\.js") "start.ps1 should use infra device-pairing module"
Assert-True (-not ($startScriptText -match "dist/plugin-sdk/index\.js")) "start.ps1 should not import device pairing from plugin-sdk"
Assert-True ($startScriptText -match 'gateway\.controlUi\.allowInsecureAuth", "true", "--json"') "start.ps1 should enable control UI insecure auth bypass"
Assert-True ($startScriptText -match 'gateway\.controlUi\.dangerouslyDisableDeviceAuth", "true", "--json"') "start.ps1 should disable control UI device auth pairing"
Assert-True ($startScriptText -match 'agents\.list\[\$i\]\.identity\.name') "start.ps1 should assign per-agent identity names"
Assert-True ($startScriptText -match 'agents\.list\[\$i\]\.subagents\.allowAgents\[0\]", "\*"') "start.ps1 should configure Jarvis to orchestrate all agents"
Assert-True ($startScriptText -match 'tools\.agentToAgent\.enabled", "true", "--json"') "start.ps1 should enable agent-to-agent"
Assert-True ($startScriptText -match 'commands\.bash", "true", "--json"') "start.ps1 should enable bash command"
Assert-True ($startScriptText -match 'tools\.elevated\.enabled", "true", "--json"') "start.ps1 should enable elevated tooling"
Assert-True ($startScriptText -match 'tools\.elevated\.allowFrom\.webchat\[0\]", "\*"') "start.ps1 should allow elevated tooling from webchat channel"
Assert-True ($startScriptText -match 'OPENCLAW_ALWAYS_ALLOW_EXEC') "start.ps1 should expose OPENCLAW_ALWAYS_ALLOW_EXEC env toggle"
Assert-True ($startScriptText -match 'tools\.exec\.ask", "off"') "start.ps1 should support always-allow mode with tools.exec.ask=off"
Assert-True ($startScriptText -match 'tools\.exec\.security", "full"') "start.ps1 should support always-allow mode with tools.exec.security=full"
Assert-True ($startScriptText -match 'agents\.defaults\.cliBackends\[codex-cli\]\.command", "/home/node/\.openclaw/tools/bin/codex"') "start.ps1 should set codex backend command path"
Assert-True ($startScriptText -match 'agents\.defaults\.cliBackends\[codex-cli\]\.env\.OPENAI_API_KEY' -and $startScriptText -match '\$\{OPENAI_API_KEY\}') "start.ps1 should wire codex backend OPENAI_API_KEY from env reference"
Assert-True ($startScriptText -match "Initialize-AgentMainSessions") "start.ps1 should bootstrap agent main sessions"
Assert-True ($startScriptText -match 'agents\.defaults\.memorySearch\.enabled", "true", "--json"') "start.ps1 should enable memory search"
Assert-True ($startScriptText -match 'agents\.defaults\.memorySearch\.provider", "openai"') "start.ps1 should set memory provider to openai"
Assert-True ($startScriptText -match 'agents\.defaults\.memorySearch\.sources\[0\]", "memory"') "start.ps1 should set memory source"
Assert-True ($startScriptText -match 'agents\.defaults\.memorySearch\.sources\[1\]", "sessions"') "start.ps1 should set sessions source"
Assert-True ($startScriptText -match 'agents\.defaults\.memorySearch\.experimental\.sessionMemory", "true", "--json"') "start.ps1 should enable session memory"
Assert-True ($startScriptText -match 'memory", "index", "--agent", "main"') "start.ps1 should run memory index for main"
Assert-True ($startScriptText -match '\.local/bin:\$HOME/\.openclaw/tools/bin') "start.ps1 should persist ~/.local/bin and ~/.openclaw/tools/bin PATH in profile"
Assert-True ($startScriptText -match 'OPENCLAW_USE_LOCAL_SOURCE=true but source directory is not a valid OpenClaw repo') "start.ps1 should auto-fallback when local source path is invalid"
Assert-True ($startScriptText -match 'config", "set", "browser\.enabled", "true", "--json"') "start.ps1 should enable browser by default"
Assert-True ($startScriptText -match 'config", "set", "browser\.headless", "true", "--json"') "start.ps1 should force browser headless mode in Docker"
Assert-True ($startScriptText -match 'config", "set", "browser\.noSandbox", "true", "--json"') "start.ps1 should force browser noSandbox mode in Docker"
Assert-True ($startScriptText -match "Warming browser control service") "start.ps1 should warm browser control service during setup"
Assert-True ($startScriptText -match "Test-BrowserControlService") "start.ps1 warmup should run browser control probe"
Assert-True ($startScriptText -match 'OPENCLAW_ENABLE_MISSION_CONTROL = "true"') "start.ps1 should enable Mission Control by default"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_REPO_URL') "start.ps1 should expose Mission Control repo env"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN') "start.ps1 should manage Mission Control local auth token"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_AUTOCONFIG_GATEWAY') "start.ps1 should expose Mission Control gateway auto-config env"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_SYNC_TEMPLATES') "start.ps1 should expose Mission Control template sync env"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_SYNC_MANIFEST_AGENTS') "start.ps1 should expose Mission Control manifest agent sync env"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_GATEWAY_WORKSPACE_ROOT') "start.ps1 should expose Mission Control gateway workspace env"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_GATEWAY_ID') "start.ps1 should expose Mission Control gateway id env"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_MANIFEST_AGENT_BOARD_ID') "start.ps1 should expose Mission Control manifest agent board id env"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_MANIFEST_AGENT_BOARD_SLUG') "start.ps1 should expose Mission Control manifest agent board slug env"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_SEED_BOARD') "start.ps1 should expose Mission Control board seed toggle"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_SEED_BOARD_PACK') "start.ps1 should expose Mission Control board pack seed toggle"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE') "start.ps1 should expose Mission Control board config file env"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_JSON') "start.ps1 should expose Mission Control board config json env"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_FILE') "start.ps1 should expose Mission Control board pack config file env"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_JSON') "start.ps1 should expose Mission Control board pack config json env"
Assert-True ($startScriptText -match 'OPENCLAW_MISSION_CONTROL_BASE_URL') "start.ps1 should expose Mission Control base URL override env"
Assert-True ($startScriptText -match "Starting Mission Control") "start.ps1 should start Mission Control"
Assert-True ($startScriptText -match "Mission Control health check") "start.ps1 should run Mission Control health check"
Assert-True ($startScriptText -match "Test-HttpStatus200") "start.ps1 should validate Mission Control URL with HTTP 200"
Assert-True ($startScriptText -match 'BASE_URL') "start.ps1 should write BASE_URL into Mission Control backend env"
Assert-True ($startScriptText -match "backend") "start.ps1 should manage Mission Control backend env files"
Assert-True ($startScriptText -match "\.env\.example") "start.ps1 should update Mission Control backend .env.example"
Assert-True ($startScriptText -match "Resolve-AvailablePort") "start.ps1 should auto-resolve busy Mission Control ports"
Assert-True ($startScriptText -match "Mission Control redis port .* is busy; using") "start.ps1 should report Mission Control port conflict remapping"
Assert-True ($startScriptText -match "Mission Control gateway auto-config") "start.ps1 should auto-register Mission Control gateway details"
Assert-True ($startScriptText -match "MC_WORKSPACE_ROOT") "start.ps1 should pass workspace_root during Mission Control gateway registration"
Assert-True ($startScriptText -match "MISSION_CONTROL_GATEWAY_URL=") "start.ps1 should parse and persist Mission Control gateway URL"
Assert-True ($startScriptText -match "Patch-MissionControlGatewayScopes") "start.ps1 should patch Mission Control gateway scopes for compatibility"
Assert-True ($startScriptText -match '\"operator\.read\"') "start.ps1 should ensure Mission Control requests operator.read scope"
Assert-True ($startScriptText -match '\"openclaw-control-ui\"') "start.ps1 should force Mission Control client id to control-ui for auth compatibility"
Assert-True ($startScriptText -match "def _gateway_origin") "start.ps1 should patch Mission Control gateway origin helper"
Assert-True ($startScriptText -match "origin=_gateway_origin\(gateway_url\)") "start.ps1 should set websocket origin when Mission Control calls the gateway"
Assert-True ($startScriptText -match "Patch-MissionControlOnboardingRecovery") "start.ps1 should patch Mission Control onboarding recovery guard"
Assert-True ($startScriptText -match "onboarding\.recover\.dispatch_failed") "start.ps1 should inject onboarding recovery re-dispatch logic"
Assert-True ($startScriptText -match "Patch-MissionControlOnboardingSessionIsolation") "start.ps1 should patch Mission Control onboarding session isolation"
Assert-True ($startScriptText -match "board-onboarding") "start.ps1 should isolate onboarding session key per board"
Assert-True ($startScriptText -match "Patch-MissionControlOnboardingAgentLabels") "start.ps1 should patch Mission Control onboarding agent labels"
Assert-True ($startScriptText -match 'agent_name=f"Gateway Agent \{str\(board.id\)\[:8\]\}"') "start.ps1 should enforce unique onboarding agent labels per board"
Assert-True ($startScriptText -match "Repair-MissionControlOnboardingSessions") "start.ps1 should repair legacy onboarding session keys"
Assert-True ($startScriptText -match "MISSION_CONTROL_ONBOARDING_SESSIONKEY_MIGRATED=") "start.ps1 should log onboarding session-key migration count"
Assert-True ($startScriptText -match "MC_SYNC_TEMPLATES") "start.ps1 should pass Mission Control template-sync toggle into auto-config script"
Assert-True ($startScriptText -match "/templates/sync") "start.ps1 should call Mission Control templates sync endpoint during auto-config"
Assert-True ($startScriptText -match "MISSION_CONTROL_GATEWAY_SYNC=") "start.ps1 should log Mission Control template sync summary"
Assert-True ($startScriptText -match "Mission Control board seed") "start.ps1 should run Mission Control board seed step"
Assert-True ($startScriptText -match "MISSION_CONTROL_BOARD_ACTION=") "start.ps1 should capture board seed action"
Assert-True ($startScriptText -match "MC_BOARD_CONFIG_B64") "start.ps1 should pass board config JSON payload to Mission Control seed logic"
Assert-True ($startScriptText -match "MC_BOARD_PACK_CONFIG_B64") "start.ps1 should pass board pack JSON payload to Mission Control seed logic"
Assert-True ($startScriptText -match "scripts/mission_control/seed_starter_pack\.py") "start.ps1 should execute shared Mission Control seed script"
Assert-True ($startScriptText -match "Mission Control manifest agent sync") "start.ps1 should sync Mission Control manifest agents"
Assert-True ($startScriptText -match "MISSION_CONTROL_MANIFEST_AGENT_SYNC=") "start.ps1 should log Mission Control manifest agent sync summary"
Assert-True (Test-Path $missionControlSeedScript) "Mission Control seed script should exist"
Assert-True ($missionControlSeedScriptText -match "/boards") "Mission Control seed script should call boards API endpoints"
Assert-True ($missionControlSeedScriptText -match "Perspective:") "Mission Control seed script should map perspective into board description"
Assert-True ($startScriptText -match 'OPENCLAW_ENABLE_COMMAND_CENTER = "false"') "start.ps1 should disable Command Center by default"
Assert-True ($startScriptText -match "OPENCLAW_COMMAND_CENTER_REPO_URL") "start.ps1 should expose Command Center repo env"
Assert-True ($startScriptText -match "OPENCLAW_COMMAND_CENTER_PORT") "start.ps1 should expose Command Center port env"
Assert-True ($startScriptText -match "Invoke-CommandCenterCompose") "start.ps1 should use command center compose helper"
Assert-True ($startScriptText -match "Starting OpenClaw Command Center") "start.ps1 should start Command Center when enabled"
Assert-True ($startScriptText -match "OpenClaw Command Center health check") "start.ps1 should run Command Center health check"
Assert-True ($startScriptText -match "OpenClaw Command Center URL:") "start.ps1 should print Command Center URL"
Assert-True ($startScriptText -match "OPENCLAW_SAFE_PROJECT_NAME") "start.ps1 should persist OPENCLAW_SAFE_PROJECT_NAME for shared safe network/volume"

$verifyScriptText = Get-Content -Path (Join-Path $rootDir "verify.ps1") -Raw
Assert-True ($verifyScriptText -match "python3 -m pip --version") "verify.ps1 should probe pip availability"
Assert-True ($verifyScriptText -match "/home/node/\.local/bin") "verify.ps1 should verify ~/.local/bin is on PATH"
Assert-True ($verifyScriptText -match "/home/node/\.openclaw/tools/bin") "verify.ps1 should verify ~/.openclaw/tools/bin is on PATH"
Assert-True ($verifyScriptText -match "/home/node/\.openclaw/tools/bin/playwright --version") "verify.ps1 should probe playwright CLI availability"
Assert-True ($verifyScriptText -match "/home/node/\.openclaw/tools/bin/openclaw --version") "verify.ps1 should probe openclaw CLI availability"
Assert-True ($verifyScriptText -match "/home/node/\.openclaw/tools/bin/agent-browser --version") "verify.ps1 should probe agent-browser CLI availability"
Assert-True ($verifyScriptText -match "agent-browser open https://example\.com") "verify.ps1 should run agent-browser open smoke test"
Assert-True ($verifyScriptText -match 'browser", "status", "--json"') "verify.ps1 should run browser status smoke probe"
Assert-True ($verifyScriptText -match "agent-browser close") "verify.ps1 should run agent-browser close smoke test"
Assert-True ($verifyScriptText -match "openclaw community skills repo synced") "verify.ps1 should verify openclaw community skills repo sync"
Assert-True ($verifyScriptText -match "commands\.bash") "verify.ps1 should check bash command config"
Assert-True ($verifyScriptText -match "tools\.elevated\.enabled") "verify.ps1 should check elevated tooling config"
Assert-True ($verifyScriptText -match "tools\.elevated\.allowFrom\.webchat\[0\]") "verify.ps1 should check elevated allowFrom webchat config"
Assert-True ($verifyScriptText -match 'config", "get", "browser\.enabled"') "verify.ps1 should check browser.enabled default"
Assert-True ($verifyScriptText -match 'config", "get", "browser\.headless"') "verify.ps1 should check browser.headless default"
Assert-True ($verifyScriptText -match 'config", "get", "browser\.noSandbox"') "verify.ps1 should check browser.noSandbox default"
Assert-True ($verifyScriptText -match "Test-BrowserControlService") "verify.ps1 should validate browser control service start"
Assert-True ($verifyScriptText -match "agents\.defaults\.cliBackends\[codex-cli\]\.command") "verify.ps1 should check codex backend command wiring"
Assert-True ($verifyScriptText -match '\[ -n "\$OPENAI_API_KEY" \]') "verify.ps1 should ensure OPENAI_API_KEY is present in gateway runtime env"
Assert-True ($verifyScriptText -match "command -v apt-get >/dev/null") "verify.ps1 should probe gateway apt availability"
Assert-True ($verifyScriptText -match "Container mount isolation") "verify.ps1 should check container mount isolation"
Assert-True ($verifyScriptText -match 'bind mounts') "verify.ps1 should reject bind mounts for gateway isolation"
Assert-True ($verifyScriptText -match "Mission Control dashboard") "verify.ps1 should verify Mission Control when enabled"
Assert-True ($verifyScriptText -match "Invoke-MissionControlCompose") "verify.ps1 should run Mission Control compose probes"
Assert-True ($verifyScriptText -match "Expected HTTP 200") "verify.ps1 should enforce HTTP 200 on Mission Control URL"
Assert-True ($verifyScriptText -match "Command Center dashboard") "verify.ps1 should verify Command Center when enabled"
Assert-True ($verifyScriptText -match "Invoke-CommandCenterCompose") "verify.ps1 should run Command Center compose probes"
Assert-True ($verifyScriptText -match "Command Center dashboard check failed\. Expected HTTP 200") "verify.ps1 should enforce HTTP 200 on Command Center URL"

$starterComposeText = Get-Content -Path (Join-Path $rootDir "docker-compose.safe.yml") -Raw
Assert-True ($starterComposeText -match "/home/node/\.local/bin:/home/node/\.openclaw/tools/bin") "starter compose should include ~/.local/bin in PATH"
Assert-True ($starterComposeText -match "PLAYWRIGHT_BROWSERS_PATH: /home/node/\.cache/ms-playwright") "starter compose should pin PLAYWRIGHT_BROWSERS_PATH for gateway and CLI"
Assert-True (($starterComposeText -split "read_only: true").Count -eq 2) "starter compose should keep read_only only for CLI service"

$commandCenterComposeText = Get-Content -Path (Join-Path $rootDir "command-center.compose.yml") -Raw
Assert-True ($commandCenterComposeText -match "OPENCLAW_SAFE_PROJECT_NAME") "command-center compose should use OPENCLAW_SAFE_PROJECT_NAME to attach shared resources"

$doctorCmdText = Get-Content -Path (Join-Path $rootDir "doctor.cmd") -Raw
Assert-True ($doctorCmdText -match "doctor\.ps1") "doctor.cmd should call doctor.ps1"

$doctorShText = Get-Content -Path (Join-Path $rootDir "doctor.sh") -Raw
Assert-True ($doctorShText -match 'start\.sh') "doctor.sh should run start.sh"
Assert-True ($doctorShText -match 'verify\.sh') "doctor.sh should run verify.sh"
Assert-True ($doctorShText -match "browser status --json") "doctor.sh should probe browser status"
Assert-True ($doctorShText -match 'log "PASS"') "doctor.sh should print PASS summary"

Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
Write-Host "[openclaw-easy] start.unit.ps1 passed"

#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf "Assertion failed: %s. Expected '%s', got '%s'.\n" "$message" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_match() {
  local value="$1"
  local regex="$2"
  local message="$3"
  if [[ ! "$value" =~ $regex ]]; then
    printf "Assertion failed: %s. Value '%s' did not match '%s'.\n" "$message" "$value" "$regex" >&2
    exit 1
  fi
}

export OPENCLAW_EASY_TEST_MODE=1
# shellcheck source=/dev/null
source "$ROOT_DIR/start.sh"
unset OPENCLAW_EASY_TEST_MODE

token="$(generate_token)"
assert_eq "64" "${#token}" "generate_token should return 64 hex chars"
assert_match "$token" '^[0-9a-f]{64}$' "generate_token should return lowercase hex"

export OPENCLAW_GATEWAY_PORT=18888
export OPENCLAW_GATEWAY_TOKEN=abc123
assert_eq "http://127.0.0.1:18888/#token=abc123" "$(default_dashboard_url)" "default_dashboard_url should include token"
assert_eq "http://127.0.0.1:18888/#token=abc123" "$(ensure_dashboard_url_token "http://127.0.0.1:18888/")" "ensure_dashboard_url_token should append token"
assert_eq "http://127.0.0.1:18888/#token=existing" "$(ensure_dashboard_url_token "http://127.0.0.1:18888/#token=existing")" "ensure_dashboard_url_token should keep existing token"
plugins="$(parse_channel_plugin_list 'telegram, whatsapp telegram')"
assert_eq $'telegram\nwhatsapp' "$plugins" "parse_channel_plugin_list should dedupe plugin ids and keep order"

detected_repo="$(detect_local_openclaw_repo "$ROOT_DIR" || true)"
if [[ -n "$detected_repo" ]]; then
  assert_eq "0" "$(test -f "$detected_repo/Dockerfile"; echo $?)" "detect_local_openclaw_repo should return an OpenClaw root"
fi

unset OPENCLAW_GATEWAY_TOKEN
assert_eq "http://127.0.0.1:18888/" "$(default_dashboard_url)" "default_dashboard_url should fallback without token"

tmp="$(mktemp)"
cat >"$tmp" <<'EOF'
OPENAI_API_KEY=old
OTHER=1
OPENAI_API_KEY=duplicate
EOF

upsert_env "$tmp" "OPENAI_API_KEY" "new"
openai_count="$(grep -c '^OPENAI_API_KEY=' "$tmp" || true)"
assert_eq "1" "$openai_count" "upsert_env should keep one key entry"
assert_eq "OPENAI_API_KEY=new" "$(grep '^OPENAI_API_KEY=' "$tmp")" "upsert_env should write latest value"

is_private_or_loopback_ip "127.0.0.1"
is_private_or_loopback_ip "::1"
is_private_or_loopback_ip "172.24.0.1"
is_private_or_loopback_ip "192.168.1.44"
if is_private_or_loopback_ip "8.8.8.8"; then
  echo "Assertion failed: public IP should not be local" >&2
  exit 1
fi

if grep -Fq '[string[]]$Args' "$ROOT_DIR/verify.ps1" "$ROOT_DIR/repair-auth.ps1"; then
  echo "Assertion failed: verify/repair scripts should use ComposeArgs, not reserved Args" >&2
  exit 1
fi

if grep -Fq 'openai/gpt-5.2-codex' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should not default to openai/gpt-5.2-codex" >&2
  exit 1
fi

if ! grep -Fq 'install "$slug" --force' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should force-install skills for non-interactive setup" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES:-chromium git python3 python3-pip sudo}"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should default apt packages with python3, pip, and sudo" >&2
  exit 1
fi

if ! grep -Fq 'python3-pip' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should enforce python3-pip apt package" >&2
  exit 1
fi

if ! grep -Fq 'python3-pip sudo' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should enforce sudo apt package" >&2
  exit 1
fi

if ! grep -Fq 'npm i -g @anthropic-ai/claude-code @openai/codex playwright --prefix "$TOOLS_DIR"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should install playwright CLI tool in tools prefix" >&2
  exit 1
fi

if ! grep -Fq 'cat > "$TOOLS_DIR/bin/openclaw"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should create openclaw CLI wrapper" >&2
  exit 1
fi

if ! grep -Fq 'cat > "$TOOLS_DIR/bin/agent-browser"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should create agent-browser CLI wrapper" >&2
  exit 1
fi

if ! grep -Fq 'install --with-deps chromium' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should install playwright chromium browser with deps fallback" >&2
  exit 1
fi

if ! grep -Fq 'https://github.com/openclaw/skills' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should clone openclaw community skills repo" >&2
  exit 1
fi

if ! grep -Fq 'openclaw-community-skills' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should stage openclaw community skills in workspace tmp" >&2
  exit 1
fi

if ! grep -Fq 'nextfrontierbuilds/web-qa-bot' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should include requested community skill list" >&2
  exit 1
fi

if ! grep -Fq 'dist/infra/device-pairing.js' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should use infra device-pairing module" >&2
  exit 1
fi

if grep -Fq 'dist/plugin-sdk/index.js' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should not import device pairing from plugin-sdk" >&2
  exit 1
fi

if ! grep -Fq 'gateway.controlUi.allowInsecureAuth true --json' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should enable control UI insecure auth bypass" >&2
  exit 1
fi

if ! grep -Fq 'gateway.controlUi.dangerouslyDisableDeviceAuth true --json' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should disable control UI device auth pairing" >&2
  exit 1
fi

if ! grep -Fq 'agents.list[$index].identity.name' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should assign per-agent identity names" >&2
  exit 1
fi

if ! grep -Fq 'agents.list[$index].subagents.allowAgents[0]' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should configure Jarvis cross-agent orchestration" >&2
  exit 1
fi

if ! grep -Fq 'tools.agentToAgent.enabled true --json' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should enable agent-to-agent" >&2
  exit 1
fi

if ! grep -Fq 'config set commands.bash true --json' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should enable bash command" >&2
  exit 1
fi

if ! grep -Fq 'config set tools.elevated.enabled true --json' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should enable elevated tooling" >&2
  exit 1
fi

if ! grep -Fq 'tools.elevated.allowFrom.webchat[0]' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should allow elevated tooling from webchat channel" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_ALWAYS_ALLOW_EXEC="${OPENCLAW_ALWAYS_ALLOW_EXEC:-false}"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should expose OPENCLAW_ALWAYS_ALLOW_EXEC env toggle" >&2
  exit 1
fi

if ! grep -Fq 'config set tools.exec.ask off' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should support always-allow mode via tools.exec.ask=off" >&2
  exit 1
fi

if ! grep -Fq 'config set tools.exec.security full' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should support always-allow mode via tools.exec.security=full" >&2
  exit 1
fi

if ! grep -Fq 'agents.defaults.cliBackends[codex-cli].command' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should set codex backend command path" >&2
  exit 1
fi

if ! grep -Fq 'agents.defaults.cliBackends[codex-cli].env.OPENAI_API_KEY' "$ROOT_DIR/start.sh" || ! grep -Fq "'\${OPENAI_API_KEY}'" "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should wire codex backend OPENAI_API_KEY from env reference" >&2
  exit 1
fi

if ! grep -Fq 'bootstrap_agent_main_sessions' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should bootstrap agent main sessions" >&2
  exit 1
fi

if ! grep -Fq 'agents.defaults.memorySearch.enabled true --json' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should enable memory search" >&2
  exit 1
fi

if ! grep -Fq 'agents.defaults.memorySearch.provider openai' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should set memory provider to openai" >&2
  exit 1
fi

if ! grep -Fq 'agents.defaults.memorySearch.sources[0]' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should set memory source" >&2
  exit 1
fi

if ! grep -Fq 'agents.defaults.memorySearch.sources[1]' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should set sessions source" >&2
  exit 1
fi

if ! grep -Fq 'agents.defaults.memorySearch.experimental.sessionMemory true --json' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should enable session memory" >&2
  exit 1
fi

if ! grep -Fq 'memory index --agent main' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should run memory index for main" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_USE_LOCAL_SOURCE=true but source directory is not a valid OpenClaw repo' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should auto-fallback when local source path is invalid" >&2
  exit 1
fi

if ! grep -Fq 'config set browser.enabled true --json' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should enable browser by default" >&2
  exit 1
fi

if ! grep -Fq 'config set browser.headless true --json' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should force browser headless mode in Docker" >&2
  exit 1
fi

if ! grep -Fq 'config set browser.noSandbox true --json' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should force browser noSandbox mode in Docker" >&2
  exit 1
fi

if ! grep -Fq 'log "Warming browser control service"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should warm browser control service during setup" >&2
  exit 1
fi

if ! grep -Fq 'test_browser_control_service' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh warmup should run browser control probe" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_ENABLE_MISSION_CONTROL="${OPENCLAW_ENABLE_MISSION_CONTROL:-true}"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should enable Mission Control by default" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_MISSION_CONTROL_REPO_URL' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should expose Mission Control repo env" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should manage Mission Control local auth token" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_MISSION_CONTROL_AUTOCONFIG_GATEWAY' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should expose Mission Control gateway auto-config env" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_MISSION_CONTROL_SYNC_TEMPLATES' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should expose Mission Control template sync env" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_MISSION_CONTROL_GATEWAY_ID' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should expose Mission Control gateway id env" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_MISSION_CONTROL_SEED_BOARD' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should expose Mission Control board seed toggle" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should expose Mission Control board config file env" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_JSON' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should expose Mission Control board config json env" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_MISSION_CONTROL_GATEWAY_WORKSPACE_ROOT' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should expose Mission Control gateway workspace env" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_MISSION_CONTROL_BASE_URL' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should expose Mission Control base URL override env" >&2
  exit 1
fi

if ! grep -Fq 'log "Starting Mission Control"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should start Mission Control" >&2
  exit 1
fi

if ! grep -Fq 'log "Mission Control health check"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should run Mission Control health check" >&2
  exit 1
fi

if ! grep -Fq 'mission_control_http_200' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should validate Mission Control URL with HTTP 200" >&2
  exit 1
fi

if ! grep -Fq 'upsert_env "$mission_control_env_file" "BASE_URL"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should write BASE_URL into Mission Control backend env" >&2
  exit 1
fi

if ! grep -Fq 'backend/.env.example' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should update Mission Control backend .env.example" >&2
  exit 1
fi

if ! grep -Fq 'resolve_available_port' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should auto-resolve busy Mission Control ports" >&2
  exit 1
fi

if ! grep -Fq 'Mission Control redis port %s is busy; using %s.' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should report Mission Control port conflict remapping" >&2
  exit 1
fi

if ! grep -Fq 'log "Mission Control gateway auto-config"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should auto-register Mission Control gateway details" >&2
  exit 1
fi

if ! grep -Fq 'MC_WORKSPACE_ROOT=${OPENCLAW_MISSION_CONTROL_GATEWAY_WORKSPACE_ROOT}' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should pass workspace_root during Mission Control gateway registration" >&2
  exit 1
fi

if ! grep -Fq 'MISSION_CONTROL_GATEWAY_URL=' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should parse Mission Control gateway URL output" >&2
  exit 1
fi

if ! grep -Fq 'patch_mission_control_gateway_scopes' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should patch Mission Control gateway scopes for compatibility" >&2
  exit 1
fi

if ! grep -Fq '"operator.read"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should ensure Mission Control requests operator.read scope" >&2
  exit 1
fi

if ! grep -Fq '"openclaw-control-ui"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should force Mission Control client id to control-ui for auth compatibility" >&2
  exit 1
fi

if ! grep -Fq 'def _gateway_origin' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should patch Mission Control gateway origin helper" >&2
  exit 1
fi

if ! grep -Fq 'origin=_gateway_origin(gateway_url)' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should set websocket origin when Mission Control calls the gateway" >&2
  exit 1
fi

if ! grep -Fq 'patch_mission_control_onboarding_recovery' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should patch Mission Control onboarding recovery guard" >&2
  exit 1
fi

if ! grep -Fq 'onboarding.recover.dispatch_failed' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should inject onboarding recovery re-dispatch logic" >&2
  exit 1
fi

if ! grep -Fq 'patch_mission_control_onboarding_session_isolation' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should patch Mission Control onboarding session isolation" >&2
  exit 1
fi

if ! grep -Fq 'board-onboarding' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should isolate onboarding session key per board" >&2
  exit 1
fi

if ! grep -Fq 'patch_mission_control_onboarding_agent_labels' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should patch Mission Control onboarding agent labels" >&2
  exit 1
fi

if ! grep -Fq 'agent_name=f"Gateway Agent {str(board.id)[:8]}"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should enforce unique onboarding agent labels per board" >&2
  exit 1
fi

if ! grep -Fq 'repair_mission_control_onboarding_sessions' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should repair legacy onboarding session keys" >&2
  exit 1
fi

if ! grep -Fq 'MISSION_CONTROL_ONBOARDING_SESSIONKEY_MIGRATED=' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should log onboarding session-key migration count" >&2
  exit 1
fi

if ! grep -Fq 'MC_SYNC_TEMPLATES=${OPENCLAW_MISSION_CONTROL_SYNC_TEMPLATES}' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should pass Mission Control template-sync toggle into auto-config script" >&2
  exit 1
fi

if ! grep -Fq '/templates/sync' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should call Mission Control templates sync endpoint during auto-config" >&2
  exit 1
fi

if ! grep -Fq 'MISSION_CONTROL_GATEWAY_SYNC=' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should log Mission Control template sync summary" >&2
  exit 1
fi

if ! grep -Fq 'Mission Control board seed' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should run Mission Control board seed step" >&2
  exit 1
fi

if ! grep -Fq 'MISSION_CONTROL_BOARD_ACTION=' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should capture board seed action" >&2
  exit 1
fi

if ! grep -Fq 'MC_BOARD_CONFIG_B64' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should pass board config JSON payload to Mission Control seed logic" >&2
  exit 1
fi

if ! grep -Fq 'Perspective:\n' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should map perspective into board description" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_ENABLE_COMMAND_CENTER="${OPENCLAW_ENABLE_COMMAND_CENTER:-false}"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should disable Command Center by default" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_SAFE_PROJECT_NAME="${OPENCLAW_SAFE_PROJECT_NAME:-$COMPOSE_PROJECT_NAME}"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should persist OPENCLAW_SAFE_PROJECT_NAME for shared safe network/volume" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_COMMAND_CENTER_REPO_URL' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should expose Command Center repo env" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_COMMAND_CENTER_PORT' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should expose Command Center port env" >&2
  exit 1
fi

if ! grep -Fq 'command_center_compose' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should use command center compose helper" >&2
  exit 1
fi

if ! grep -Fq 'log "Starting OpenClaw Command Center"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should start Command Center when enabled" >&2
  exit 1
fi

if ! grep -Fq 'log "OpenClaw Command Center health check"' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should run Command Center health check" >&2
  exit 1
fi

if ! grep -Fq 'OpenClaw Command Center URL' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should print Command Center URL" >&2
  exit 1
fi

if ! grep -Fq '.local/bin:$HOME/.openclaw/tools/bin' "$ROOT_DIR/start.sh"; then
  echo "Assertion failed: start.sh should persist ~/.local/bin and ~/.openclaw/tools/bin PATH in profile" >&2
  exit 1
fi

if ! grep -Fq 'dist/infra/device-pairing.js' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should use infra device-pairing module" >&2
  exit 1
fi

if grep -Fq 'dist/plugin-sdk/index.js' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should not import device pairing from plugin-sdk" >&2
  exit 1
fi

if ! grep -Fq 'gateway.controlUi.allowInsecureAuth true --json' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should enable control UI insecure auth bypass" >&2
  exit 1
fi

if ! grep -Fq 'gateway.controlUi.dangerouslyDisableDeviceAuth true --json' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should disable control UI device auth pairing" >&2
  exit 1
fi

if ! grep -Fq 'agents.list[0].subagents.allowAgents[0]' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should preserve Jarvis cross-agent orchestration" >&2
  exit 1
fi

if ! grep -Fq 'tools.agentToAgent.enabled true --json' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should enable agent-to-agent" >&2
  exit 1
fi

if ! grep -Fq 'config set commands.bash true --json' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should enable bash command" >&2
  exit 1
fi

if ! grep -Fq 'config set tools.elevated.enabled true --json' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should enable elevated tooling" >&2
  exit 1
fi

if ! grep -Fq 'tools.elevated.allowFrom.webchat[0]' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should allow elevated tooling from webchat channel" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_ALWAYS_ALLOW_EXEC=' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should read OPENCLAW_ALWAYS_ALLOW_EXEC" >&2
  exit 1
fi

if ! grep -Fq 'config set tools.exec.ask off' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should support always-allow mode via tools.exec.ask=off" >&2
  exit 1
fi

if ! grep -Fq 'config set tools.exec.security full' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should support always-allow mode via tools.exec.security=full" >&2
  exit 1
fi

if ! grep -Fq 'agents.defaults.cliBackends[codex-cli].command' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should set codex backend command path" >&2
  exit 1
fi

if ! grep -Fq 'agents.defaults.cliBackends[codex-cli].env.OPENAI_API_KEY' "$ROOT_DIR/repair-auth.sh" || ! grep -Fq "'\${OPENAI_API_KEY}'" "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should wire codex backend OPENAI_API_KEY from env reference" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_AGENT_SESSION_SEED=' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should bootstrap agent main sessions" >&2
  exit 1
fi

if ! grep -Fq 'agents.defaults.memorySearch.enabled true --json' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should enable memory search" >&2
  exit 1
fi

if ! grep -Fq 'agents.defaults.memorySearch.sources[0]' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should set memory source" >&2
  exit 1
fi

if ! grep -Fq 'agents.defaults.memorySearch.sources[1]' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should set sessions source" >&2
  exit 1
fi

if ! grep -Fq 'memory index --agent main' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should run memory index for main" >&2
  exit 1
fi

if ! grep -Fq 'config set browser.enabled true --json' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should ensure browser.enabled" >&2
  exit 1
fi

if ! grep -Fq 'config set browser.headless true --json' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should ensure browser.headless" >&2
  exit 1
fi

if ! grep -Fq 'config set browser.noSandbox true --json' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should ensure browser.noSandbox" >&2
  exit 1
fi

if ! grep -Fq 'browser start --json' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should attempt browser start after auth repair" >&2
  exit 1
fi

if ! grep -Fq 'Write-Step "PASS"' "$ROOT_DIR/doctor.ps1"; then
  echo "Assertion failed: doctor.ps1 should print PASS summary" >&2
  exit 1
fi

if ! grep -Fq 'Running start' "$ROOT_DIR/doctor.ps1"; then
  echo "Assertion failed: doctor.ps1 should run start phase" >&2
  exit 1
fi

if ! grep -Fq 'Running verify' "$ROOT_DIR/doctor.ps1"; then
  echo "Assertion failed: doctor.ps1 should run verify phase" >&2
  exit 1
fi

if ! grep -Fq '"browser", "status", "--json"' "$ROOT_DIR/doctor.ps1"; then
  echo "Assertion failed: doctor.ps1 should run browser status probe" >&2
  exit 1
fi

if ! grep -Fq 'doctor.ps1' "$ROOT_DIR/doctor.cmd"; then
  echo "Assertion failed: doctor.cmd should call doctor.ps1" >&2
  exit 1
fi

if ! grep -Fq '/start.sh' "$ROOT_DIR/doctor.sh"; then
  echo "Assertion failed: doctor.sh should run start.sh" >&2
  exit 1
fi

if ! grep -Fq '/verify.sh' "$ROOT_DIR/doctor.sh"; then
  echo "Assertion failed: doctor.sh should run verify.sh" >&2
  exit 1
fi

if ! grep -Fq 'browser status --json' "$ROOT_DIR/doctor.sh"; then
  echo "Assertion failed: doctor.sh should probe browser status" >&2
  exit 1
fi

if ! grep -Fq 'log "PASS"' "$ROOT_DIR/doctor.sh"; then
  echo "Assertion failed: doctor.sh should print PASS summary" >&2
  exit 1
fi

if ! grep -Fq '.local/bin:$HOME/.openclaw/tools/bin' "$ROOT_DIR/repair-auth.sh"; then
  echo "Assertion failed: repair-auth.sh should persist ~/.local/bin and ~/.openclaw/tools/bin PATH in profile" >&2
  exit 1
fi

if ! grep -Fq 'python3 -m pip --version' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should probe pip availability" >&2
  exit 1
fi

if ! grep -Fq '/home/node/.openclaw/tools/bin' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should verify ~/.openclaw/tools/bin in PATH" >&2
  exit 1
fi

if ! grep -Fq '/home/node/.openclaw/tools/bin/playwright --version' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should probe playwright CLI availability" >&2
  exit 1
fi

if ! grep -Fq '/home/node/.openclaw/tools/bin/openclaw --version' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should probe openclaw CLI availability" >&2
  exit 1
fi

if ! grep -Fq '/home/node/.openclaw/tools/bin/agent-browser --version' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should probe agent-browser CLI availability" >&2
  exit 1
fi

if ! grep -Fq 'agent-browser open https://example.com' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should run agent-browser open smoke test" >&2
  exit 1
fi

if ! grep -Fq 'browser status --json' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should run browser status smoke probe" >&2
  exit 1
fi

if ! grep -Fq 'agent-browser close' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should run agent-browser close smoke test" >&2
  exit 1
fi

if ! grep -Fq 'openclaw community skills repo synced' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should verify openclaw community skills repo sync" >&2
  exit 1
fi

if ! grep -Fq '/home/node/.local/bin:/home/node/.openclaw/tools/bin' "$ROOT_DIR/docker-compose.safe.yml"; then
  echo "Assertion failed: starter compose should include ~/.local/bin in PATH" >&2
  exit 1
fi

if ! grep -Fq 'PLAYWRIGHT_BROWSERS_PATH: /home/node/.cache/ms-playwright' "$ROOT_DIR/docker-compose.safe.yml"; then
  echo "Assertion failed: starter compose should pin PLAYWRIGHT_BROWSERS_PATH for gateway and CLI" >&2
  exit 1
fi

if ! grep -Fq 'OPENCLAW_SAFE_PROJECT_NAME' "$ROOT_DIR/command-center.compose.yml"; then
  echo "Assertion failed: command-center compose should use OPENCLAW_SAFE_PROJECT_NAME to attach shared resources" >&2
  exit 1
fi

if ! grep -Fq 'command -v apt-get >/dev/null' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should probe gateway sudo and apt" >&2
  exit 1
fi

if ! grep -Fq 'config get commands.bash' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should check bash command config" >&2
  exit 1
fi

if ! grep -Fq 'config get browser.enabled' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should check browser.enabled default" >&2
  exit 1
fi

if ! grep -Fq 'config get browser.headless' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should check browser.headless default" >&2
  exit 1
fi

if ! grep -Fq 'config get browser.noSandbox' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should check browser.noSandbox default" >&2
  exit 1
fi

if ! grep -Fq 'test_browser_control_service' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should validate browser control service start" >&2
  exit 1
fi

if ! grep -Fq 'Mission Control dashboard' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should verify Mission Control when enabled" >&2
  exit 1
fi

if ! grep -Fq 'Expected HTTP 200' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should enforce HTTP 200 on Mission Control URL" >&2
  exit 1
fi

if ! grep -Fq 'Command Center dashboard' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should verify Command Center when enabled" >&2
  exit 1
fi

if ! grep -Fq 'command_center_compose' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should run Command Center compose probes" >&2
  exit 1
fi

if ! grep -Fq 'Command Center dashboard check failed. Expected HTTP 200' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should enforce HTTP 200 on Command Center URL" >&2
  exit 1
fi

if ! grep -Fq 'config get tools.elevated.enabled' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should check elevated tooling config" >&2
  exit 1
fi

if ! grep -Fq "config get 'agents.defaults.cliBackends[codex-cli].command'" "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should check codex backend command wiring" >&2
  exit 1
fi

if ! grep -Fq '[ -n "$OPENAI_API_KEY" ]' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should ensure OPENAI_API_KEY is present in gateway runtime env" >&2
  exit 1
fi

if ! grep -Fq 'Container mount isolation' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should check container mount isolation" >&2
  exit 1
fi

if ! grep -Fq '"Type":"bind"' "$ROOT_DIR/verify.sh"; then
  echo "Assertion failed: verify.sh should reject bind mounts for gateway isolation" >&2
  exit 1
fi

rm -f "$tmp"
printf "[openclaw-easy] start.unit.sh passed\n"

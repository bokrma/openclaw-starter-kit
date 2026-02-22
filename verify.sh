#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
SAFE_COMPOSE_TEMPLATE="$ROOT_DIR/docker-compose.safe.yml"
UNIT_TEST_FILE="$ROOT_DIR/tests/start.unit.sh"
COMPOSE_CMD=()

log() {
  printf "\n[openclaw-easy] %s\n" "$*"
}

fail() {
  printf "\n[openclaw-easy] ERROR: %s\n" "$*" >&2
  exit 1
}

maybe_delegate_to_powershell() {
  local uname_out
  uname_out="$(uname -s 2>/dev/null || true)"
  local is_wsl="false"
  if [[ -n "${WSL_DISTRO_NAME:-}" ]] || grep -qi microsoft /proc/version 2>/dev/null; then
    is_wsl="true"
  fi
  case "$uname_out" in
    CYGWIN*|MINGW*|MSYS*)
      local ps_file="$ROOT_DIR/verify.ps1"
      if command -v cygpath >/dev/null 2>&1; then
        ps_file="$(cygpath -w "$ps_file")"
      fi
      if command -v pwsh >/dev/null 2>&1; then
        exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$ps_file" "$@"
      elif command -v powershell.exe >/dev/null 2>&1; then
        exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps_file" "$@"
      fi
      ;;
  esac
  if [[ "$is_wsl" == "true" ]]; then
    local ps_file="$ROOT_DIR/verify.ps1"
    if command -v cygpath >/dev/null 2>&1; then
      ps_file="$(cygpath -w "$ps_file")"
    else
      ps_file="$(wslpath -w "$ps_file" 2>/dev/null || printf "%s" "$ps_file")"
    fi
    if command -v powershell.exe >/dev/null 2>&1; then
      exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps_file" "$@"
    elif command -v pwsh >/dev/null 2>&1; then
      exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$ps_file" "$@"
    fi
  fi
}

resolve_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    return
  fi
  fail "Docker Compose not found. Install Docker Compose v2 (docker compose) or docker-compose."
}

lowercase() {
  printf "%s" "${1:-}" | tr '[:upper:]' '[:lower:]'
}

is_truthy() {
  local value
  value="$(lowercase "${1:-}" | xargs)"
  [[ "$value" == "1" || "$value" == "true" || "$value" == "yes" || "$value" == "on" ]]
}

maybe_delegate_to_powershell "$@"

if [[ ! -f "$ENV_FILE" ]]; then
  fail ".env not found. Run start.sh first."
fi

if [[ -f "$UNIT_TEST_FILE" ]]; then
  log "Unit tests"
  bash "$UNIT_TEST_FILE"
fi

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  line="${line#$'\ufeff'}"
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
  if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    export "${line%%=*}=${line#*=}"
  fi
done <"$ENV_FILE"

OPENCLAW_SRC_DIR="${OPENCLAW_SRC_DIR:-$ROOT_DIR/vendor/openclaw}"
if [[ ! -f "$OPENCLAW_SRC_DIR/.env" ]]; then
  cp "$ENV_FILE" "$OPENCLAW_SRC_DIR/.env"
fi

if [[ ! -d "$OPENCLAW_SRC_DIR" ]]; then
  fail "OpenClaw source not found at $OPENCLAW_SRC_DIR. Run start.sh first."
fi

if [[ ! -f "$SAFE_COMPOSE_TEMPLATE" ]]; then
  fail "Missing starter compose template: $SAFE_COMPOSE_TEMPLATE"
fi
cp "$SAFE_COMPOSE_TEMPLATE" "$OPENCLAW_SRC_DIR/docker-compose.safe.yml"
log "Synced docker-compose.safe.yml into cloned OpenClaw repo"

resolve_compose
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-openclaw-easy}"
export OPENCLAW_SAFE_PROJECT_NAME="${OPENCLAW_SAFE_PROJECT_NAME:-$COMPOSE_PROJECT_NAME}"

compose() {
  (
    cd "$OPENCLAW_SRC_DIR"
    "${COMPOSE_CMD[@]}" -p "${COMPOSE_PROJECT_NAME}" --env-file "$OPENCLAW_SRC_DIR/.env" -f docker-compose.safe.yml "$@"
  )
}

gateway_http_ok() {
  curl -fsS --max-time 3 "http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/" >/dev/null 2>&1
}

gateway_container_status() {
  compose ps openclaw-gateway --format json 2>/dev/null | sed -n 's/.*"Status":"\([^"]*\)".*/\1/p' | tail -n 1
}

test_browser_control_service() {
  local status_out
  status_out="$(compose exec -T openclaw-gateway node dist/index.js browser status --json 2>/dev/null | tr -d '\r' || true)"
  if [[ -z "$status_out" ]]; then
    printf "probe failed (no response from gateway CLI)\n"
    return 1
  fi
  if printf "%s" "$status_out" | grep -Eq '"enabled"[[:space:]]*:[[:space:]]*true'; then
    local profile
    profile="$(printf "%s" "$status_out" | sed -E 's/.*"profile"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/' || true)"
    if [[ "$profile" == "$status_out" ]]; then
      profile="unknown"
    fi
    printf "profiles=%s\n" "$profile"
    return 0
  fi
  printf "browser disabled\n"
  return 1
}

mission_control_compose() {
  (
    cd "$OPENCLAW_MISSION_CONTROL_SRC_DIR"
    "${COMPOSE_CMD[@]}" -p "${COMPOSE_PROJECT_NAME}-mission-control" --env-file "$OPENCLAW_MISSION_CONTROL_SRC_DIR/.env" -f compose.yml "$@"
  )
}

mission_control_http_200() {
  local url="${1:-}"
  [[ -n "$url" ]] || return 1
  local code
  code="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "$url" || true)"
  [[ "$code" == "200" ]]
}

command_center_compose() {
  (
    cd "$ROOT_DIR"
    "${COMPOSE_CMD[@]}" -p "${COMPOSE_PROJECT_NAME}-command-center" --env-file "$ENV_FILE" -f command-center.compose.yml "$@"
  )
}

command_center_http_200() {
  local url="${1:-}"
  [[ -n "$url" ]] || return 1
  local code
  code="$(curl -sS -o /dev/null -w "%{http_code}" --max-time 5 "$url" || true)"
  [[ "$code" == "200" ]]
}

log "Gateway container status"
compose ps

log "Gateway health"
export OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
gateway_ready=false
for attempt in $(seq 1 30); do
  if gateway_http_ok; then
    gateway_ready=true
    break
  fi
  if [[ "$attempt" -eq 1 || $((attempt % 5)) -eq 0 ]]; then
    status="$(gateway_container_status || true)"
    if [[ -n "$status" ]]; then
      printf "[openclaw-easy] gateway status: %s\n" "$status"
    fi
  fi
  sleep 2
done
if [[ "$gateway_ready" != "true" ]]; then
  compose logs --tail=120 openclaw-gateway || true
  fail "Gateway HTTP endpoint is not reachable at http://127.0.0.1:${OPENCLAW_GATEWAY_PORT}/"
fi

log "Control UI auth bypass settings"
allow_insecure="$(compose run --rm openclaw-cli config get gateway.controlUi.allowInsecureAuth 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"
disable_device_auth="$(compose run --rm openclaw-cli config get gateway.controlUi.dangerouslyDisableDeviceAuth 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"
if [[ "$(lowercase "$allow_insecure")" != "true" || "$(lowercase "$disable_device_auth")" != "true" ]]; then
  fail "Control UI auth bypass is not enabled (gateway.controlUi.allowInsecureAuth=true and gateway.controlUi.dangerouslyDisableDeviceAuth=true are required)."
fi

log "Elevated shell defaults"
bash_enabled="$(compose run --rm openclaw-cli config get commands.bash 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"
elevated_enabled="$(compose run --rm openclaw-cli config get tools.elevated.enabled 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"
elevated_web="$(compose run --rm openclaw-cli config get 'tools.elevated.allowFrom.webchat[0]' 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"
if [[ "$(lowercase "$bash_enabled")" != "true" || "$(lowercase "$elevated_enabled")" != "true" || "$elevated_web" != "*" ]]; then
  fail "Elevated shell defaults are not set correctly. Expected commands.bash=true, tools.elevated.enabled=true, tools.elevated.allowFrom.webchat[0]=*."
fi

log "Codex auth wiring"
codex_backend_cmd="$(compose run --rm openclaw-cli config get 'agents.defaults.cliBackends[codex-cli].command' 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"
if [[ "$codex_backend_cmd" != "/home/node/.openclaw/tools/bin/codex" ]]; then
  fail "Codex backend command is not set correctly. Expected /home/node/.openclaw/tools/bin/codex."
fi
compose exec -T openclaw-gateway sh -lc '[ -n "$OPENAI_API_KEY" ]'

log "Gateway sudo/apt probe"
compose exec -T openclaw-gateway sh -lc 'command -v apt-get >/dev/null && (apt-get --version >/dev/null || (command -v sudo >/dev/null && sudo -n apt-get --version >/dev/null))'

log "Container mount isolation"
gateway_container_id="$(compose ps -q openclaw-gateway 2>/dev/null | tr -d '\r' | head -n 1)"
if [[ -z "$gateway_container_id" ]]; then
  fail "Could not resolve openclaw-gateway container id for mount isolation check."
fi
mounts_json="$(docker inspect --format '{{json .Mounts}}' "$gateway_container_id" 2>/dev/null || true)"
if [[ -z "$mounts_json" ]]; then
  fail "Could not inspect openclaw-gateway mounts for isolation check."
fi
if printf "%s" "$mounts_json" | grep -F '"Type":"bind"' >/dev/null; then
  fail "openclaw-gateway has bind mounts. For container-only isolation, bind mounts are not allowed."
fi

log "Memory defaults"
memory_enabled="$(compose run --rm openclaw-cli config get agents.defaults.memorySearch.enabled 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"
memory_provider="$(compose run --rm openclaw-cli config get agents.defaults.memorySearch.provider 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"
memory_source_0="$(compose run --rm openclaw-cli config get 'agents.defaults.memorySearch.sources[0]' 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"
memory_source_1="$(compose run --rm openclaw-cli config get 'agents.defaults.memorySearch.sources[1]' 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"
session_memory="$(compose run --rm openclaw-cli config get agents.defaults.memorySearch.experimental.sessionMemory 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"
sync_on_start="$(compose run --rm openclaw-cli config get agents.defaults.memorySearch.sync.onSessionStart 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"
sync_on_search="$(compose run --rm openclaw-cli config get agents.defaults.memorySearch.sync.onSearch 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"

if [[ "$(lowercase "$memory_enabled")" != "true" || "$(lowercase "$memory_provider")" != "openai" || "$(lowercase "$memory_source_0")" != "memory" || "$(lowercase "$memory_source_1")" != "sessions" || "$(lowercase "$session_memory")" != "true" || "$(lowercase "$sync_on_start")" != "true" || "$(lowercase "$sync_on_search")" != "true" ]]; then
  fail "Memory defaults are not set correctly. Expected enabled=true, provider=openai, sources=[memory,sessions], experimental.sessionMemory=true, sync.onSessionStart=true, sync.onSearch=true."
fi

log "Memory command probe"
compose run --rm openclaw-cli memory status --agent main --json >/dev/null

log "Browser defaults"
browser_enabled="$(compose run --rm openclaw-cli config get browser.enabled 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"
browser_headless="$(compose run --rm openclaw-cli config get browser.headless 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"
browser_no_sandbox="$(compose run --rm openclaw-cli config get browser.noSandbox 2>/dev/null | tr -d '\r' | tail -n 1 | xargs || true)"
if [[ "$(lowercase "$browser_enabled")" != "true" || "$(lowercase "$browser_headless")" != "true" || "$(lowercase "$browser_no_sandbox")" != "true" ]]; then
  fail "Browser defaults are not set correctly. Expected browser.enabled=true, browser.headless=true, browser.noSandbox=true."
fi

log "Browser control service"
browser_probe="$(test_browser_control_service || true)"
if [[ -z "$browser_probe" || "$browser_probe" != profiles=* ]]; then
  fail "Browser control service probe failed: ${browser_probe:-unknown}"
fi

  tmp_js="$(mktemp "$ROOT_DIR/.tmp_manifest_XXXXXX.mjs")"
  cat <<'NODE' > "$tmp_js"
import fs from "node:fs";

const raw = fs.readFileSync("/work/openclaw-agents/agents/manifest.json", "utf8");
const manifest = JSON.parse(raw);
const agents = Array.isArray(manifest.agents) ? manifest.agents : [];
const compact = agents.map((item) => ({
  id: String(item?.id ?? "").trim(),
  name: String(item?.name ?? "").trim(),
  default: item?.default === true,
}));
console.log(JSON.stringify(compact));
NODE
  agent_manifest_json="$(compose run --rm \
    --volume "$ROOT_DIR:/work:ro" \
    --volume "$tmp_js:/app/check_manifest.mjs:ro" \
    --entrypoint node \
    openclaw-cli /app/check_manifest.mjs 2>/dev/null | tr -d '\r' | tail -n 1)"
  rm -f "$tmp_js"
if [[ -z "$agent_manifest_json" ]]; then
  fail "Agent manifest is missing or unreadable: $ROOT_DIR/openclaw-agents/agents/manifest.json"
fi

  log "Checking agent pack + coordinator wiring"
  agents_json="$(compose run --rm openclaw-cli config get agents.list --json 2>/dev/null | tr -d '\r' || true)"
  if [[ -z "$agents_json" || "$agents_json" == "null" ]]; then
    fail "No agents registered in configuration."
  fi

  issues=()
  # check for manifest agents
  while IFS='|' read -r id name workspace is_default; do
    [[ -n "$id" ]] || continue
    # check if in agents_json
    if ! printf "%s" "$agents_json" | grep -F "\"id\": \"$id\"" >/dev/null; then
      issues+=("Agent $id ($name) is missing from configuration list.")
    fi
    # check for session file
    session_file="/home/node/.openclaw/agents/$id/sessions/sessions.json"
    if ! compose exec -T openclaw-gateway [ -f "$session_file" ] 2>/dev/null; then
       issues+=("Agent $id ($name) is missing main session file.")
    fi
  done < <(while IFS= read -r line; do
             # Use the node logic to extract rows from manifest (already refactored to be robust)
             printf "%s\n" "$line"
           done < <(cat <<'NODE' | compose run --rm --volume "$ROOT_DIR:/work:ro" --entrypoint node -e OPENCLAW_AGENT_MANIFEST_PATH=/work/openclaw-agents/agents/manifest.json openclaw-cli --input-type=module
import fs from "node:fs";
const raw = fs.readFileSync(process.env.OPENCLAW_AGENT_MANIFEST_PATH, "utf8");
const manifest = JSON.parse(raw);
const agents = Array.isArray(manifest.agents) ? manifest.agents : [];
for (const item of agents) {
  const id = String(item?.id ?? "").trim();
  if (!id) continue;
  const name = String(item?.name ?? id).trim();
  const workspace = String(item?.workspace ?? "").trim();
  const isDefault = item?.default === true ? "true" : "false";
  console.log(`${id}|${name}|${workspace}|${isDefault}`);
}
NODE
))

  # check for orchestration wiring in main agent
  if ! printf "%s" "$agents_json" | tr -d '\n ' | grep -F '"id":"main"' | grep -F '"allowAgents":["*"]' >/dev/null; then
    issues+=("Main agent orchestration not enabled (allowAgents should include '*').")
  fi

  if [[ "${#issues[@]}" -gt 0 ]]; then
    for issue in "${issues[@]}"; do
      printf "[openclaw-easy] ISSUE: %s\n" "$issue"
    done
    fail "Agent pack wiring check failed."
  fi

if [[ "${OPENCLAW_ENABLE_SUPERMEMORY:-}" == "true" ]] || [[ -n "${SUPERMEMORY_OPENCLAW_API_KEY:-}" ]]; then
  log "Supermemory plugin status"
  compose run --rm openclaw-cli plugins info openclaw-supermemory
else
  log "Supermemory plugin check skipped (disabled)"
fi

  log "Checking required skills/tools"
  skills_probe_script="$(cat <<'SH'
set -eu
required="gmail github automation-workflows playwright-mcp summarize weather skill-creator openclaw-github-assistant github-mcp github-cli github-automation-pro agent-council agentlens aster bidclub claude-optimised create-agent-skills anthropic-frontend-design ui-audit 2captcha agent-zero-bridge agent-browser-2 dating local-places clawexchange clawdwork deep-research web-qa-bot verify-on-browser home-assistant quality-manager-qmr skill-scaffold tdd-guide cto-advisor evolver coding-agent"
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
SH
)"
  compose run --rm --entrypoint sh openclaw-cli -lc "$skills_probe_script"

  log "Checking required CLIs"
  clis_probe_script="$(cat <<'SH'
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
SH
)"
  compose run --rm --entrypoint sh openclaw-cli -lc "$clis_probe_script"

  log "agent-browser CLI smoke test"
  compose exec -T openclaw-gateway node dist/index.js browser status --json >/dev/null
  compose exec -T openclaw-gateway /home/node/.openclaw/tools/bin/agent-browser open https://example.com >/dev/null 2>&1 || true
  compose exec -T openclaw-gateway /home/node/.openclaw/tools/bin/agent-browser close >/dev/null 2>&1 || true

log "Dashboard URL"
compose run --rm openclaw-cli dashboard --no-open

if is_truthy "${OPENCLAW_ENABLE_MISSION_CONTROL:-false}"; then
  log "Mission Control dashboard"
  OPENCLAW_MISSION_CONTROL_SRC_DIR="${OPENCLAW_MISSION_CONTROL_SRC_DIR:-$ROOT_DIR/vendor/openclaw-mission-control}"
  if [[ ! -d "$OPENCLAW_MISSION_CONTROL_SRC_DIR" ]]; then
    fail "Mission Control source not found at $OPENCLAW_MISSION_CONTROL_SRC_DIR"
  fi
  if [[ ! -f "$OPENCLAW_MISSION_CONTROL_SRC_DIR/compose.yml" ]]; then
    fail "Mission Control compose file missing at $OPENCLAW_MISSION_CONTROL_SRC_DIR/compose.yml"
  fi
  mission_control_compose ps >/dev/null
  mission_control_url="http://127.0.0.1:${OPENCLAW_MISSION_CONTROL_FRONTEND_PORT:-3000}/"
  if ! mission_control_http_200 "$mission_control_url"; then
    mission_control_compose logs --tail=120 frontend backend || true
    fail "Mission Control dashboard check failed. Expected HTTP 200 at $mission_control_url"
  fi
fi

if is_truthy "${OPENCLAW_ENABLE_COMMAND_CENTER:-false}"; then
  log "Command Center dashboard"
  if [[ ! -f "$ROOT_DIR/command-center.compose.yml" ]]; then
    fail "Command Center compose file missing at $ROOT_DIR/command-center.compose.yml"
  fi
  command_center_compose ps >/dev/null
  command_center_url="http://127.0.0.1:${OPENCLAW_COMMAND_CENTER_PORT:-3340}/"
  if ! command_center_http_200 "$command_center_url"; then
    command_center_compose logs --tail=120 openclaw-command-center || true
    fail "Command Center dashboard check failed. Expected HTTP 200 at $command_center_url"
  fi
fi

log "Verification passed"


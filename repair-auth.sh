#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
SAFE_COMPOSE_TEMPLATE="$ROOT_DIR/docker-compose.safe.yml"
COMPOSE_CMD=()

log() {
  printf "\n[openclaw-easy] %s\n" "$*"
}

is_truthy() {
  local value
  value="$(printf "%s" "${1:-}" | tr '[:upper:]' '[:lower:]' | xargs)"
  [[ "$value" == "1" || "$value" == "true" || "$value" == "yes" || "$value" == "on" ]]
}

fail() {
  printf "\n[openclaw-easy] ERROR: %s\n" "$*" >&2
  exit 1
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

if [[ ! -f "$ENV_FILE" ]]; then
  fail ".env not found. Run start.sh first."
fi

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  line="${line#$'\ufeff'}"
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
  if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    export "${line%%=*}=${line#*=}"
  fi
done <"$ENV_FILE"

if [[ -z "${OPENCLAW_ALWAYS_ALLOW_EXEC:-}" ]]; then
  OPENCLAW_ALWAYS_ALLOW_EXEC="false"
  export OPENCLAW_ALWAYS_ALLOW_EXEC
  tmp_env="$(mktemp)"
  if [[ -f "$ENV_FILE" ]]; then
    awk -F= '$1 != "OPENCLAW_ALWAYS_ALLOW_EXEC" { print $0 }' "$ENV_FILE" >"$tmp_env"
  fi
  printf "OPENCLAW_ALWAYS_ALLOW_EXEC=%s\n" "$OPENCLAW_ALWAYS_ALLOW_EXEC" >>"$tmp_env"
  mv "$tmp_env" "$ENV_FILE"
fi
exec_mode="prompt"
if is_truthy "${OPENCLAW_ALWAYS_ALLOW_EXEC:-false}"; then
  exec_mode="allow"
fi

if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
  if command -v openssl >/dev/null 2>&1; then
    OPENCLAW_GATEWAY_TOKEN="$(openssl rand -hex 32)"
  else
    OPENCLAW_GATEWAY_TOKEN="$(python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
)"
  fi
  export OPENCLAW_GATEWAY_TOKEN
  tmp_env="$(mktemp)"
  if [[ -f "$ENV_FILE" ]]; then
    awk -F= '$1 != "OPENCLAW_GATEWAY_TOKEN" { print $0 }' "$ENV_FILE" >"$tmp_env"
  fi
  printf "OPENCLAW_GATEWAY_TOKEN=%s\n" "$OPENCLAW_GATEWAY_TOKEN" >>"$tmp_env"
  mv "$tmp_env" "$ENV_FILE"
  log "Generated OPENCLAW_GATEWAY_TOKEN and saved it to .env"
fi

OPENCLAW_SRC_DIR="${OPENCLAW_SRC_DIR:-$ROOT_DIR/vendor/openclaw}"
if [[ ! -d "$OPENCLAW_SRC_DIR" ]]; then
  fail "OpenClaw source not found at $OPENCLAW_SRC_DIR. Run start.sh first."
fi
cp "$ENV_FILE" "$OPENCLAW_SRC_DIR/.env"
if [[ -f "$SAFE_COMPOSE_TEMPLATE" ]]; then
  cp "$SAFE_COMPOSE_TEMPLATE" "$OPENCLAW_SRC_DIR/docker-compose.safe.yml"
fi

resolve_compose
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-openclaw-easy}"

compose() {
  (
    cd "$OPENCLAW_SRC_DIR"
    "${COMPOSE_CMD[@]}" -p "$COMPOSE_PROJECT_NAME" --env-file "$OPENCLAW_SRC_DIR/.env" -f docker-compose.safe.yml "$@"
  )
}

default_dashboard_url() {
  local port
  port="${OPENCLAW_GATEWAY_PORT:-18789}"
  if [[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    printf "http://127.0.0.1:%s/#token=%s\n" "$port" "$OPENCLAW_GATEWAY_TOKEN"
  else
    printf "http://127.0.0.1:%s/\n" "$port"
  fi
}

ensure_dashboard_url_token() {
  local raw_url="${1:-}"
  if [[ -z "$raw_url" ]]; then
    raw_url="$(default_dashboard_url)"
  fi
  if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    printf "%s\n" "$raw_url"
    return
  fi
  if [[ "$raw_url" == *"token="* ]]; then
    printf "%s\n" "$raw_url"
    return
  fi
  if [[ "$raw_url" == *"#"* ]]; then
    if [[ "$raw_url" == *"#" || "$raw_url" == *"&" ]]; then
      printf "%stoken=%s\n" "$raw_url" "$OPENCLAW_GATEWAY_TOKEN"
    else
      printf "%s&token=%s\n" "$raw_url" "$OPENCLAW_GATEWAY_TOKEN"
    fi
    return
  fi
  printf "%s#token=%s\n" "$raw_url" "$OPENCLAW_GATEWAY_TOKEN"
}

log "Starting gateway"
compose up -d openclaw-gateway

log "Reapplying gateway auth token"
compose run --rm openclaw-cli config set gateway.mode local
compose run --rm openclaw-cli config set gateway.auth.mode token
compose run --rm openclaw-cli config set gateway.auth.token "$OPENCLAW_GATEWAY_TOKEN"
compose run --rm openclaw-cli config set gateway.controlUi.allowInsecureAuth true --json
compose run --rm openclaw-cli config set gateway.controlUi.dangerouslyDisableDeviceAuth true --json
compose run --rm openclaw-cli config set 'agents.list[0].subagents.allowAgents[0]' "*" >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set tools.agentToAgent.enabled true --json >/dev/null 2>&1 || true
compose run --rm openclaw-cli config unset tools.agentToAgent.allow >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set 'tools.agentToAgent.allow[0]' "*" >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set commands.bash true --json >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set tools.elevated.enabled true --json >/dev/null 2>&1 || true
compose run --rm openclaw-cli config unset tools.elevated.allowFrom.web >/dev/null 2>&1 || true
compose run --rm openclaw-cli config unset tools.elevated.allowFrom.webchat >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set 'tools.elevated.allowFrom.webchat[0]' "*" >/dev/null 2>&1 || true
if [[ "$exec_mode" == "allow" ]]; then
  compose run --rm openclaw-cli config set tools.exec.ask off >/dev/null 2>&1 || true
  compose run --rm openclaw-cli config set tools.exec.security full >/dev/null 2>&1 || true
else
  compose run --rm openclaw-cli config set tools.exec.ask on-miss >/dev/null 2>&1 || true
  compose run --rm openclaw-cli config set tools.exec.security allowlist >/dev/null 2>&1 || true
fi
compose run --rm openclaw-cli config set "agents.defaults.cliBackends[codex-cli].command" "/home/node/.openclaw/tools/bin/codex" >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set "agents.defaults.cliBackends[codex-cli].env.OPENAI_API_KEY" '${OPENAI_API_KEY}' >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set agents.defaults.memorySearch.enabled true --json >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set agents.defaults.memorySearch.provider openai >/dev/null 2>&1 || true
compose run --rm openclaw-cli config unset agents.defaults.memorySearch.sources >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set 'agents.defaults.memorySearch.sources[0]' memory >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set 'agents.defaults.memorySearch.sources[1]' sessions >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set agents.defaults.memorySearch.experimental.sessionMemory true --json >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set agents.defaults.memorySearch.sync.onSessionStart true --json >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set agents.defaults.memorySearch.sync.onSearch true --json >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set browser.enabled true --json >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set browser.headless true --json >/dev/null 2>&1 || true
compose run --rm openclaw-cli config set browser.noSandbox true --json >/dev/null 2>&1 || true
compose run --rm --entrypoint sh openclaw-cli -lc 'PROFILE_FILE=/home/node/.profile; if [ -f "$PROFILE_FILE" ]; then grep -Fq '\''export PATH="$HOME/.local/bin:$HOME/.openclaw/tools/bin:$PATH"'\'' "$PROFILE_FILE" || echo '\''export PATH="$HOME/.local/bin:$HOME/.openclaw/tools/bin:$PATH"'\'' >> "$PROFILE_FILE"; else echo '\''export PATH="$HOME/.local/bin:$HOME/.openclaw/tools/bin:$PATH"'\'' > "$PROFILE_FILE"; fi' >/dev/null 2>&1 || true
if [[ "$exec_mode" == "allow" ]]; then
  compose run --rm openclaw-cli config set tools.exec.ask off >/dev/null 2>&1 || true
  compose run --rm openclaw-cli config set tools.exec.security full >/dev/null 2>&1 || true
else
  compose run --rm openclaw-cli config set tools.exec.ask on-miss >/dev/null 2>&1 || true
  compose run --rm openclaw-cli config set tools.exec.security allowlist >/dev/null 2>&1 || true
fi
compose up -d openclaw-gateway
compose run --rm openclaw-cli browser start --json >/dev/null 2>&1 || true

log "Repairing local device pairing state"
compose exec -T openclaw-gateway node --input-type=module -e '
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
' || true

compose run --rm --entrypoint node \
  -e OPENCLAW_AGENT_SESSION_SEED='[{"id":"main","name":"Jarvis"},{"id":"dev","name":"Dev Agent"},{"id":"backend","name":"Backend Engineer"},{"id":"frontend","name":"Frontend Engineer (React)"},{"id":"designer","name":"Designer"},{"id":"ux","name":"UI/UX Expert"},{"id":"db","name":"Database Engineer"},{"id":"pm","name":"PM Agent"},{"id":"qa","name":"QA Agent"},{"id":"research","name":"Research Agent"},{"id":"ops","name":"Ops Agent"},{"id":"growth","name":"Growth Agent"},{"id":"finance","name":"Financial Expert"},{"id":"stocks","name":"Stock Analyzer"},{"id":"creative","name":"Creative Agent"},{"id":"motivation","name":"Motivation Agent"}]' \
  openclaw-cli --input-type=module -e '
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
' >/dev/null 2>&1 || true
compose run --rm openclaw-cli memory index --agent main >/dev/null 2>&1 || true

token_line="$(compose run --rm openclaw-cli config get gateway.auth.token 2>/dev/null | sed -n 's/^[[:space:]]*//;s/[[:space:]]*$//;/^[A-Za-z0-9._-]\{16,\}$/p' | tail -n 1 || true)"
if [[ -n "$token_line" ]]; then
  export OPENCLAW_GATEWAY_TOKEN="$token_line"
fi

log "Dashboard URL"
ensure_dashboard_url_token "$(default_dashboard_url)"

log "Browser reset snippet (run in DevTools Console if mismatch persists)"
echo 'localStorage.removeItem("openclaw.device.auth.v1");'
echo 'localStorage.removeItem("openclaw-device-identity-v1");'
echo 'localStorage.removeItem("openclaw.control.settings.v1");'
echo "location.reload();"


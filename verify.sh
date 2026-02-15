#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
OPENCLAW_SRC_DIR="${OPENCLAW_SRC_DIR:-$ROOT_DIR/vendor/openclaw}"
SAFE_COMPOSE_TEMPLATE="$ROOT_DIR/docker-compose.safe.yml"
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

maybe_delegate_to_powershell "$@"

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

if [[ ! -d "$OPENCLAW_SRC_DIR" ]]; then
  fail "OpenClaw source not found at $OPENCLAW_SRC_DIR. Run start.sh first."
fi

if [[ ! -f "$OPENCLAW_SRC_DIR/docker-compose.safe.yml" ]]; then
  if [[ ! -f "$SAFE_COMPOSE_TEMPLATE" ]]; then
    fail "Missing starter compose template: $SAFE_COMPOSE_TEMPLATE"
  fi
  cp "$SAFE_COMPOSE_TEMPLATE" "$OPENCLAW_SRC_DIR/docker-compose.safe.yml"
  log "Provisioned docker-compose.safe.yml in cloned OpenClaw repo"
fi

resolve_compose

compose() {
  (
    cd "$OPENCLAW_SRC_DIR"
    "${COMPOSE_CMD[@]}" -f docker-compose.safe.yml "$@"
  )
}

log "Gateway container status"
compose ps

log "Gateway health"
compose exec openclaw-gateway node dist/index.js health --json

log "Supermemory plugin status"
compose run --rm openclaw-cli plugins info openclaw-supermemory

log "Checking required skills/tools"
compose run --rm --entrypoint sh openclaw-cli -lc '
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
'

log "Checking required CLIs"
compose run --rm --entrypoint sh openclaw-cli -lc '
set -eu
/home/node/.openclaw/tools/bin/clawhub -V || /home/node/.openclaw/tools/bin/clawhub --cli-version
/home/node/.openclaw/tools/bin/claude --version
/home/node/.openclaw/tools/bin/codex --version
'

log "Dashboard URL"
compose run --rm openclaw-cli dashboard --no-open

log "Verification passed"

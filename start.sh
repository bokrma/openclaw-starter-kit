#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
ENV_EXAMPLE_FILE="$ROOT_DIR/.env.example"
SAFE_COMPOSE_TEMPLATE="$ROOT_DIR/docker-compose.safe.yml"
COMPOSE_CMD=()
COMPOSE_HINT=""

log() {
  printf "\n[openclaw-easy] %s\n" "$*"
}

fail() {
  printf "\n[openclaw-easy] ERROR: %s\n" "$*" >&2
  exit 1
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing dependency: $1"
  fi
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
      local ps_file="$ROOT_DIR/start.ps1"
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
    local ps_file="$ROOT_DIR/start.ps1"
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

require_env() {
  local key="$1"
  if [[ -z "${!key:-}" ]]; then
    fail "Missing required value: $key (set it in .env)"
  fi
}

resolve_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
    COMPOSE_HINT="docker compose"
    return
  fi
  if command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
    COMPOSE_HINT="docker-compose"
    return
  fi
  fail "Docker Compose not found. Install Docker Compose v2 (docker compose) or docker-compose."
}

upsert_env() {
  local file="$1"
  local key="$2"
  local value="$3"
  local tmp
  tmp="$(mktemp)"

  if [[ -f "$file" ]]; then
    awk -v k="$key" -F= '$1 != k { print $0 }' "$file" >"$tmp"
  fi
  printf "%s=%s\n" "$key" "$value" >>"$tmp"
  mv "$tmp" "$file"
}

generate_token() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 32
  else
    python3 - <<'PY'
import secrets
print(secrets.token_hex(32))
PY
  fi
}

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$ENV_EXAMPLE_FILE" "$ENV_FILE"
    fail "Created .env. Fill OPENAI_API_KEY and SUPERMEMORY_API_KEY, then run start.sh again."
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#$'\ufeff'}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      export "${line%%=*}=${line#*=}"
    fi
  done <"$ENV_FILE"
}

clone_or_update_openclaw() {
  local repo_url="${OPENCLAW_REPO_URL:-https://github.com/openclaw/openclaw.git}"
  local repo_branch="${OPENCLAW_REPO_BRANCH:-v2026.2.14}"
  local src_dir="${OPENCLAW_SRC_DIR:-$ROOT_DIR/vendor/openclaw}"

  export OPENCLAW_REPO_URL="$repo_url"
  export OPENCLAW_REPO_BRANCH="$repo_branch"
  export OPENCLAW_SRC_DIR="$src_dir"

  if [[ -d "$src_dir/.git" ]]; then
    log "Updating OpenClaw source: $src_dir"
    if ! git -C "$src_dir" fetch --tags --force origin; then
      log "Update failed, recloning OpenClaw source"
      rm -rf "$src_dir"
      git clone --depth 1 --branch "$repo_branch" "$repo_url" "$src_dir"
      return
    fi
    if git -C "$src_dir" show-ref --verify --quiet "refs/remotes/origin/$repo_branch"; then
      if ! git -C "$src_dir" checkout "$repo_branch" || ! git -C "$src_dir" pull --rebase origin "$repo_branch"; then
        log "Update failed, recloning OpenClaw source"
        rm -rf "$src_dir"
        git clone --depth 1 --branch "$repo_branch" "$repo_url" "$src_dir"
      fi
    elif ! git -C "$src_dir" checkout --force "$repo_branch"; then
      log "Update failed, recloning OpenClaw source"
      rm -rf "$src_dir"
      git clone --depth 1 --branch "$repo_branch" "$repo_url" "$src_dir"
    fi
  else
    log "Cloning OpenClaw source: $repo_url ($repo_branch)"
    mkdir -p "$(dirname "$src_dir")"
    git clone --depth 1 --branch "$repo_branch" "$repo_url" "$src_dir"
  fi
}

ensure_safe_compose_file() {
  local target="$OPENCLAW_SRC_DIR/docker-compose.safe.yml"
  if [[ -f "$target" ]]; then
    return
  fi
  if [[ ! -f "$SAFE_COMPOSE_TEMPLATE" ]]; then
    fail "Missing starter compose template: $SAFE_COMPOSE_TEMPLATE"
  fi
  cp "$SAFE_COMPOSE_TEMPLATE" "$target"
  log "Provisioned docker-compose.safe.yml in cloned OpenClaw repo"
}

compose() {
  (
    cd "$OPENCLAW_SRC_DIR"
    "${COMPOSE_CMD[@]}" -f docker-compose.safe.yml "$@"
  )
}

configure_agents() {
  local agents_json
  agents_json="$(cat <<'JSON'
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
JSON
)"

  compose run --rm openclaw-cli config set agents.defaults.model.primary openai/gpt-5.2-codex
  compose run --rm openclaw-cli config set agents.defaults.model.fallbacks '["openai-codex/gpt-5.2-codex"]' --json
  compose run --rm openclaw-cli config set agents.defaults.maxConcurrent 10 --json
  compose run --rm openclaw-cli config set agents.list "$agents_json" --json
}

main() {
  maybe_delegate_to_powershell "$@"
  require_cmd docker
  require_cmd git
  resolve_compose

  load_env
  require_env OPENAI_API_KEY
  require_env SUPERMEMORY_API_KEY

  if [[ -z "${SUPERMEMORY_OPENCLAW_API_KEY:-}" ]]; then
    SUPERMEMORY_OPENCLAW_API_KEY="$SUPERMEMORY_API_KEY"
    export SUPERMEMORY_OPENCLAW_API_KEY
    upsert_env "$ENV_FILE" "SUPERMEMORY_OPENCLAW_API_KEY" "$SUPERMEMORY_OPENCLAW_API_KEY"
  else
    export SUPERMEMORY_OPENCLAW_API_KEY
  fi

  export OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-openclaw:local}"
  export OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
  export OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES:-chromium git}"
  if [[ " ${OPENCLAW_DOCKER_APT_PACKAGES} " != *" chromium "* ]]; then
    OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES} chromium"
  fi
  if [[ " ${OPENCLAW_DOCKER_APT_PACKAGES} " != *" git "* ]]; then
    OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES} git"
  fi

  if [[ -z "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    OPENCLAW_GATEWAY_TOKEN="$(generate_token)"
    export OPENCLAW_GATEWAY_TOKEN
    upsert_env "$ENV_FILE" "OPENCLAW_GATEWAY_TOKEN" "$OPENCLAW_GATEWAY_TOKEN"
    log "Generated OPENCLAW_GATEWAY_TOKEN and saved it to .env"
  else
    export OPENCLAW_GATEWAY_TOKEN
  fi

  clone_or_update_openclaw
  ensure_safe_compose_file

  log "Building OpenClaw image"
  docker build \
    --build-arg "OPENCLAW_DOCKER_APT_PACKAGES=${OPENCLAW_DOCKER_APT_PACKAGES}" \
    -t "$OPENCLAW_IMAGE" \
    -f "$OPENCLAW_SRC_DIR/Dockerfile" \
    "$OPENCLAW_SRC_DIR"

  log "Initializing gateway + auth"
  compose run --rm openclaw-cli config set gateway.mode local
  compose run --rm openclaw-cli config set gateway.auth.mode token
  compose run --rm openclaw-cli config set gateway.auth.token "$OPENCLAW_GATEWAY_TOKEN"
  compose run --rm openclaw-cli onboard \
    --non-interactive --accept-risk \
    --auth-choice openai-api-key \
    --openai-api-key "$OPENAI_API_KEY" \
    --skip-channels --skip-skills --skip-health --skip-ui --no-install-daemon
  compose run --rm openclaw-cli config set gateway.mode local
  compose run --rm openclaw-cli config set gateway.auth.mode token
  compose run --rm openclaw-cli config set gateway.auth.token "$OPENCLAW_GATEWAY_TOKEN"

  log "Applying defaults (CLI backends, concurrency, agent pack)"
  compose run --rm openclaw-cli config set "agents.defaults.cliBackends[claude-cli].command" "/home/node/.openclaw/tools/bin/claude"
  compose run --rm openclaw-cli config set "agents.defaults.cliBackends[codex-cli].command" "/home/node/.openclaw/tools/bin/codex"
  compose run --rm openclaw-cli config set agents.defaults.subagents.maxConcurrent 8 --json
  configure_agents

  log "Installing and configuring Supermemory plugin"
  if ! compose run --rm openclaw-cli plugins info openclaw-supermemory --json >/dev/null 2>&1; then
    compose run --rm openclaw-cli plugins install @supermemory/openclaw-supermemory
  fi
  compose run --rm openclaw-cli config set plugins.entries.openclaw-supermemory.enabled true --json
  compose run --rm openclaw-cli config set plugins.entries.openclaw-supermemory.config.apiKey '${SUPERMEMORY_OPENCLAW_API_KEY}'

  log "Bootstrapping tools + skills"
  compose run --rm --entrypoint sh openclaw-cli -lc '
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
'

  log "Finalizing CLI backend commands"
  compose run --rm openclaw-cli config set "agents.defaults.cliBackends[claude-cli].command" "/home/node/.openclaw/tools/bin/claude"
  compose run --rm openclaw-cli config set "agents.defaults.cliBackends[codex-cli].command" "/home/node/.openclaw/tools/bin/codex"

  log "Starting gateway"
  compose up -d openclaw-gateway
  sleep 2

  log "Health check"
  compose exec openclaw-gateway node dist/index.js health --json

  local dashboard
  local dashboard_url
  dashboard="$(compose run --rm openclaw-cli dashboard --no-open || true)"
  dashboard_url="$(printf "%s\n" "$dashboard" | sed -n "s/.*Dashboard URL:[[:space:]]*//p" | tail -n 1)"

  log "Setup complete"
  if [[ -n "$dashboard_url" ]]; then
    printf "[openclaw-easy] Open this URL:\n%s\n" "$dashboard_url"
  else
    printf "[openclaw-easy] Run this to print your URL:\n(cd \"%s\" && %s -f docker-compose.safe.yml run --rm openclaw-cli dashboard --no-open)\n" "$OPENCLAW_SRC_DIR" "$COMPOSE_HINT"
  fi
}

main "$@"

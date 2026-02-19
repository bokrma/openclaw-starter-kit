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

prompt_env_value() {
  local key="$1"
  local required="$2"
  local allow_skip="$3"
  local description="$4"
  local current="${!key:-}"

  if [[ -n "$current" ]]; then
    return 0
  fi

  if [[ ! -t 0 ]]; then
    if [[ "$required" == "true" ]]; then
      fail "Missing required value: $key (set it in .env)"
    fi
    export "$key="
    upsert_env "$ENV_FILE" "$key" ""
    return 0
  fi

  log "$description"
  if [[ "$allow_skip" == "true" ]]; then
    printf "[openclaw-easy] Press Enter or type skip to leave it empty.\n"
  fi
  while true; do
    printf "[openclaw-easy] %s: " "$key"
    IFS= read -r input_value
    if [[ -n "$input_value" && "$input_value" != "skip" ]]; then
      export "$key=$input_value"
      upsert_env "$ENV_FILE" "$key" "$input_value"
      return 0
    fi
    if [[ "$allow_skip" == "true" ]]; then
      export "$key="
      upsert_env "$ENV_FILE" "$key" ""
      return 0
    fi
    printf "[openclaw-easy] %s is required.\n" "$key"
  done
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

is_truthy() {
  local value
  value="$(printf "%s" "${1:-}" | tr '[:upper:]' '[:lower:]' | xargs)"
  [[ "$value" == "1" || "$value" == "true" || "$value" == "yes" || "$value" == "on" ]]
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

normalize_port() {
  local raw="${1:-}"
  local fallback="${2:-1}"
  if [[ "$raw" =~ ^[0-9]+$ ]] && ((raw >= 1 && raw <= 65535)); then
    printf "%s\n" "$raw"
    return
  fi
  printf "%s\n" "$fallback"
}

host_port_available() {
  local port="${1:-}"
  if [[ -z "$port" ]]; then
    return 1
  fi
  if (exec 9<>"/dev/tcp/127.0.0.1/${port}") 2>/dev/null; then
    exec 9>&-
    exec 9<&-
    return 1
  fi
  return 0
}

reserved_has_port() {
  local reserved="${1:-}"
  local candidate="${2:-}"
  [[ "$reserved" == *"|${candidate}|"* ]]
}

resolve_available_port() {
  local preferred="${1:-}"
  local reserved="${2:-|}"
  local candidate
  if ! reserved_has_port "$reserved" "$preferred" && host_port_available "$preferred"; then
    printf "%s\n" "$preferred"
    return 0
  fi
  for offset in $(seq 1 500); do
    candidate=$((preferred + offset))
    if ((candidate > 65535)); then
      break
    fi
    if reserved_has_port "$reserved" "$candidate"; then
      continue
    fi
    if host_port_available "$candidate"; then
      printf "%s\n" "$candidate"
      return 0
    fi
  done
  return 1
}

load_env() {
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$ENV_EXAMPLE_FILE" "$ENV_FILE"
    log "Created .env from .env.example"
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

is_valid_openclaw_repo() {
  local candidate="${1:-}"
  [[ -n "$candidate" ]] || return 1
  [[ -f "$candidate/Dockerfile" ]] || return 1
  [[ -f "$candidate/openclaw.mjs" ]] || return 1
  [[ -d "$candidate/src" ]] || return 1
  [[ -d "$candidate/ui" ]] || return 1
  return 0
}

clone_or_update_openclaw() {
  local repo_url="${OPENCLAW_REPO_URL:-https://github.com/openclaw/openclaw.git}"
  local repo_branch="${OPENCLAW_REPO_BRANCH:-main}"
  local src_dir="${OPENCLAW_SRC_DIR:-$ROOT_DIR/vendor/openclaw}"

  export OPENCLAW_REPO_URL="$repo_url"
  export OPENCLAW_REPO_BRANCH="$repo_branch"
  export OPENCLAW_SRC_DIR="$src_dir"

  if [[ "${OPENCLAW_USE_LOCAL_SOURCE:-false}" == "true" ]]; then
    if [[ ! -d "$src_dir" ]]; then
      fail "OPENCLAW_USE_LOCAL_SOURCE=true but source directory not found: $src_dir"
    fi
    if ! is_valid_openclaw_repo "$src_dir"; then
      local fallback_src
      fallback_src="$ROOT_DIR/vendor/openclaw"
      log "OPENCLAW_USE_LOCAL_SOURCE=true but source directory is not a valid OpenClaw repo: $src_dir"
      log "Falling back to managed clone at: $fallback_src"
      OPENCLAW_USE_LOCAL_SOURCE=false
      export OPENCLAW_USE_LOCAL_SOURCE
      upsert_env "$ENV_FILE" "OPENCLAW_USE_LOCAL_SOURCE" "$OPENCLAW_USE_LOCAL_SOURCE"
      src_dir="$fallback_src"
      OPENCLAW_SRC_DIR="$src_dir"
      export OPENCLAW_SRC_DIR
      upsert_env "$ENV_FILE" "OPENCLAW_SRC_DIR" "$OPENCLAW_SRC_DIR"
    else
      log "Using local OpenClaw source: $src_dir"
      return
    fi
  fi

  clone_with_retry() {
    local url="$1"
    local branch="$2"
    local dest="$3"
    local attempt
    for attempt in 1 2 3; do
      rm -rf "$dest"
      if git clone --depth 1 --branch "$branch" "$url" "$dest"; then
        return 0
      fi
      sleep $((attempt * 2))
    done
    return 1
  }

  if [[ -d "$src_dir/.git" ]]; then
    log "Updating OpenClaw source: $src_dir"
    if ! git -C "$src_dir" fetch --depth 1 --force origin "$repo_branch"; then
      log "Update failed, recloning OpenClaw source"
      clone_with_retry "$repo_url" "$repo_branch" "$src_dir" || fail "git clone failed after retries."
      return
    fi
    if ! git -C "$src_dir" checkout --force FETCH_HEAD; then
      log "Update failed, recloning OpenClaw source"
      clone_with_retry "$repo_url" "$repo_branch" "$src_dir" || fail "git clone failed after retries."
    fi
  else
    log "Cloning OpenClaw source: $repo_url ($repo_branch)"
    mkdir -p "$(dirname "$src_dir")"
    clone_with_retry "$repo_url" "$repo_branch" "$src_dir" || fail "git clone failed after retries."
  fi
}

clone_or_update_mission_control() {
  local repo_url="${OPENCLAW_MISSION_CONTROL_REPO_URL:-https://github.com/abhi1693/openclaw-mission-control.git}"
  local repo_branch="${OPENCLAW_MISSION_CONTROL_REPO_BRANCH:-master}"
  local src_dir="${OPENCLAW_MISSION_CONTROL_SRC_DIR:-$ROOT_DIR/vendor/openclaw-mission-control}"

  export OPENCLAW_MISSION_CONTROL_REPO_URL="$repo_url"
  export OPENCLAW_MISSION_CONTROL_REPO_BRANCH="$repo_branch"
  export OPENCLAW_MISSION_CONTROL_SRC_DIR="$src_dir"

  clone_with_retry() {
    local url="$1"
    local branch="$2"
    local dest="$3"
    local attempt
    for attempt in 1 2 3; do
      rm -rf "$dest"
      if git clone --depth 1 --branch "$branch" "$url" "$dest"; then
        return 0
      fi
      sleep $((attempt * 2))
    done
    return 1
  }

  if [[ -d "$src_dir/.git" ]]; then
    log "Updating Mission Control source: $src_dir"
    if ! git -C "$src_dir" fetch --depth 1 --force origin "$repo_branch"; then
      log "Mission Control update failed, recloning"
      clone_with_retry "$repo_url" "$repo_branch" "$src_dir" || fail "Mission Control git clone failed after retries."
      return
    fi
    if ! git -C "$src_dir" checkout --force FETCH_HEAD; then
      log "Mission Control update failed, recloning"
      clone_with_retry "$repo_url" "$repo_branch" "$src_dir" || fail "Mission Control git clone failed after retries."
    fi
  else
    log "Cloning Mission Control source"
    mkdir -p "$(dirname "$src_dir")"
    clone_with_retry "$repo_url" "$repo_branch" "$src_dir" || fail "Mission Control git clone failed after retries."
  fi
}

clone_or_update_command_center() {
  local repo_url="${OPENCLAW_COMMAND_CENTER_REPO_URL:-https://github.com/jontsai/openclaw-command-center.git}"
  local repo_branch="${OPENCLAW_COMMAND_CENTER_REPO_BRANCH:-main}"
  local src_dir="${OPENCLAW_COMMAND_CENTER_SRC_DIR:-$ROOT_DIR/vendor/openclaw-command-center}"

  export OPENCLAW_COMMAND_CENTER_REPO_URL="$repo_url"
  export OPENCLAW_COMMAND_CENTER_REPO_BRANCH="$repo_branch"
  export OPENCLAW_COMMAND_CENTER_SRC_DIR="$src_dir"

  clone_with_retry() {
    local url="$1"
    local branch="$2"
    local dest="$3"
    local attempt
    for attempt in 1 2 3; do
      rm -rf "$dest"
      if git clone --depth 1 --branch "$branch" "$url" "$dest"; then
        return 0
      fi
      sleep $((attempt * 2))
    done
    return 1
  }

  if [[ -d "$src_dir/.git" ]]; then
    log "Updating Command Center source: $src_dir"
    if ! git -C "$src_dir" fetch --depth 1 --force origin "$repo_branch"; then
      log "Command Center update failed, recloning"
      clone_with_retry "$repo_url" "$repo_branch" "$src_dir" || fail "Command Center git clone failed after retries."
      return
    fi
    if ! git -C "$src_dir" checkout --force FETCH_HEAD; then
      log "Command Center update failed, recloning"
      clone_with_retry "$repo_url" "$repo_branch" "$src_dir" || fail "Command Center git clone failed after retries."
    fi
  else
    log "Cloning Command Center source"
    mkdir -p "$(dirname "$src_dir")"
    clone_with_retry "$repo_url" "$repo_branch" "$src_dir" || fail "Command Center git clone failed after retries."
  fi
}

patch_mission_control_gateway_scopes() {
  local src_dir="${1:-$OPENCLAW_MISSION_CONTROL_SRC_DIR}"
  local gateway_rpc_file="$src_dir/backend/app/services/openclaw/gateway_rpc.py"
  [[ -f "$gateway_rpc_file" ]] || return 0
  python3 - "$gateway_rpc_file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
updated = text
changed = False

scopes_pattern = re.compile(r"GATEWAY_OPERATOR_SCOPES\s*=\s*\((?:.|\n)*?\)\n")
scopes_match = scopes_pattern.search(updated)
if scopes_match is not None:
    replacement = """GATEWAY_OPERATOR_SCOPES = (
    "operator.admin",
    "operator.read",
    "operator.write",
    "operator.approvals",
    "operator.pairing",
)
"""
    next_text = updated[:scopes_match.start()] + replacement + updated[scopes_match.end():]
    if next_text != updated:
        updated = next_text
        changed = True

if '"id": "gateway-client"' in updated:
    updated = updated.replace('"id": "gateway-client"', '"id": "openclaw-control-ui"', 1)
    changed = True

if "def _gateway_origin(" not in updated:
    anchor = re.compile(
        r'def _redacted_url_for_log\(raw_url: str\) -> str:\n'
        r'\s+parsed = urlparse\(raw_url\)\n'
        r'\s+return str\(urlunparse\(parsed\._replace\(query="", fragment=""\)\)\)\n',
    )
    anchor_match = anchor.search(updated)
    if anchor_match is not None:
        helper = """
def _gateway_origin(raw_url: str) -> str:
    parsed = urlparse(raw_url)
    scheme = "https" if parsed.scheme == "wss" else "http"
    return str(urlunparse(parsed._replace(scheme=scheme, path="", params="", query="", fragment="")))

"""
        updated = updated[:anchor_match.end()] + helper + updated[anchor_match.end():]
        changed = True

connect_pattern = re.compile(
    r"async with websockets\.connect\(\s*gateway_url,\s*ping_interval=None\s*\) as ws:"
)
connect_replacement = """async with websockets.connect(
            gateway_url,
            ping_interval=None,
            origin=_gateway_origin(gateway_url),
        ) as ws:"""
next_text = connect_pattern.sub(connect_replacement, updated, count=1)
if next_text != updated:
    updated = next_text
    changed = True

if changed:
    path.write_text(updated, encoding="utf-8")
    print("[openclaw-easy] Patched Mission Control gateway RPC client for OpenClaw compatibility.")
PY
}

patch_mission_control_onboarding_recovery() {
  local src_dir="${1:-$OPENCLAW_MISSION_CONTROL_SRC_DIR}"
  local onboarding_file="$src_dir/backend/app/api/board_onboarding.py"
  [[ -f "$onboarding_file" ]] || return 0
  python3 - "$onboarding_file" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if "onboarding.recover.dispatch_failed" in text:
    sys.exit(0)

pattern = re.compile(
    r"if onboarding is None:\n"
    r"\s+raise HTTPException\(status_code=status\.HTTP_404_NOT_FOUND\)\n"
    r"\s+return onboarding",
    re.MULTILINE,
)

replacement = """if onboarding is None:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND)
    messages = list(onboarding.messages or [])
    has_assistant_message = any(
        isinstance(msg, dict)
        and msg.get("role") == "assistant"
        and isinstance(msg.get("content"), str)
        and bool(msg.get("content").strip())
        for msg in messages
    )
    last_user_content: str | None = None
    if messages:
        last_message = messages[-1]
        if isinstance(last_message, dict):
            raw_role = last_message.get("role")
            raw_content = last_message.get("content")
            if raw_role == "user" and isinstance(raw_content, str) and raw_content:
                last_user_content = raw_content
    if onboarding.status == "active" and not has_assistant_message and last_user_content:
        # Recovery path for sessions that started but never received first assistant question.
        try:
            dispatcher = BoardOnboardingMessagingService(session)
            await dispatcher.dispatch_answer(
                board=board,
                onboarding=onboarding,
                answer_text=last_user_content,
                correlation_id=f"onboarding.recover:{board.id}:{onboarding.id}",
            )
            onboarding.updated_at = utcnow()
            session.add(onboarding)
            await session.commit()
            await session.refresh(onboarding)
        except Exception:  # pragma: no cover - best-effort recovery guard.
            logger.warning(
                "onboarding.recover.dispatch_failed board_id=%s onboarding_id=%s",
                board.id,
                onboarding.id,
                exc_info=True,
            )
    return onboarding"""

updated, count = pattern.subn(replacement, text, count=1)
if count:
    path.write_text(updated, encoding="utf-8")
    print("[openclaw-easy] Patched Mission Control onboarding recovery guard.")
PY
}

patch_mission_control_onboarding_session_isolation() {
  local src_dir="${1:-$OPENCLAW_MISSION_CONTROL_SRC_DIR}"
  local service_file="$src_dir/backend/app/services/openclaw/onboarding_service.py"
  [[ -f "$service_file" ]] || return 0
  python3 - "$service_file" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
if ":board-onboarding:" in text:
    sys.exit(0)

needle = "session_key = GatewayAgentIdentity.session_key(gateway)"
replacement = """session_key = (
            f"{GatewayAgentIdentity.session_key(gateway)}:board-onboarding:{board.id}"
        )"""

if needle in text:
    path.write_text(text.replace(needle, replacement, 1), encoding="utf-8")
    print("[openclaw-easy] Patched Mission Control onboarding session isolation.")
PY
}

patch_mission_control_onboarding_agent_labels() {
  local src_dir="${1:-$OPENCLAW_MISSION_CONTROL_SRC_DIR}"
  local service_file="$src_dir/backend/app/services/openclaw/onboarding_service.py"
  [[ -f "$service_file" ]] || return 0
  python3 - "$service_file" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
needle = 'agent_name="Gateway Agent",'
replacement = 'agent_name=f"Gateway Agent {str(board.id)[:8]}",'
if replacement in text:
    sys.exit(0)
if needle in text:
    path.write_text(text.replace(needle, replacement), encoding="utf-8")
    print("[openclaw-easy] Patched Mission Control onboarding agent labels.")
PY
}

patch_mission_control_security_baselines() {
  local src_dir="${1:-$OPENCLAW_MISSION_CONTROL_SRC_DIR}"
  local compose_file="$src_dir/compose.yml"
  local backend_pyproject="$src_dir/backend/pyproject.toml"
  local backend_dockerfile="$src_dir/backend/Dockerfile"

  [[ -f "$compose_file" ]] && python3 - "$compose_file" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
updated = text
replacements = {
    "POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:-postgres}":
        "POSTGRES_PASSWORD: ${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in .env}",
    '- "${POSTGRES_PORT:-5432}:5432"':
        '- "127.0.0.1:${POSTGRES_PORT:-5432}:5432"',
    '- "${REDIS_PORT:-6379}:6379"':
        '- "127.0.0.1:${REDIS_PORT:-6379}:6379"',
    '- "${BACKEND_PORT:-8000}:8000"':
        '- "127.0.0.1:${BACKEND_PORT:-8000}:8000"',
    '- "${FRONTEND_PORT:-3000}:3000"':
        '- "127.0.0.1:${FRONTEND_PORT:-3000}:3000"',
    "${POSTGRES_PASSWORD:-postgres}@db:5432":
        "${POSTGRES_PASSWORD:?set POSTGRES_PASSWORD in .env}@db:5432",
}
for old, new in replacements.items():
    updated = updated.replace(old, new)
if updated != text:
    path.write_text(updated, encoding="utf-8")
    print("[openclaw-easy] Patched Mission Control compose security defaults.")
PY

  [[ -f "$backend_pyproject" ]] && python3 - "$backend_pyproject" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
updated = text.replace("clerk-backend-api==4.2.0", "clerk-backend-api==5.0.2")
if '"cryptography>=46.0.5,<47"' not in updated:
    updated = updated.replace(
        '"clerk-backend-api==5.0.2",',
        '"clerk-backend-api==5.0.2",\n    "cryptography>=46.0.5,<47",',
    )
if updated != text:
    path.write_text(updated, encoding="utf-8")
    print("[openclaw-easy] Patched Mission Control backend dependency baseline.")
PY

  [[ -f "$backend_dockerfile" ]] && python3 - "$backend_dockerfile" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
updated = text.replace("uv sync --frozen --no-dev", "uv sync --no-dev")
if updated != text:
    path.write_text(updated, encoding="utf-8")
    print("[openclaw-easy] Patched Mission Control backend Docker dependency sync mode.")
PY
}

repair_mission_control_onboarding_sessions() {
  mission_control_compose exec -T -e PYTHONWARNINGS=ignore::DeprecationWarning backend python - <<'PY'
import asyncio
from sqlalchemy import text
from app.db.session import async_session_maker

async def main():
    async with async_session_maker() as session:
        migrated = await session.execute(
            text(
                """
                update board_onboarding_sessions
                set session_key = session_key || chr(58) || 'board-onboarding' || chr(58) || board_id::text
                where session_key is not null
                  and position('board-onboarding' in session_key) = 0
                returning id
                """
            )
        )
        rows = migrated.fetchall()
        await session.commit()
        print(f"MISSION_CONTROL_ONBOARDING_SESSIONKEY_MIGRATED={len(rows)}")

asyncio.run(main())
PY
}

detect_local_openclaw_repo() {
  local base_dir="${1:-$ROOT_DIR}"
  local candidate
  candidate="$(cd "$base_dir/.." && pwd)"
  if is_valid_openclaw_repo "$candidate"; then
    printf "%s\n" "$candidate"
    return 0
  fi
  return 1
}

ensure_safe_compose_file() {
  local target="$OPENCLAW_SRC_DIR/docker-compose.safe.yml"
  if [[ ! -f "$SAFE_COMPOSE_TEMPLATE" ]]; then
    fail "Missing starter compose template: $SAFE_COMPOSE_TEMPLATE"
  fi
  cp "$SAFE_COMPOSE_TEMPLATE" "$target"
  log "Synced docker-compose.safe.yml into cloned OpenClaw repo"
}

sync_vendor_env_file() {
  cp "$ENV_FILE" "$OPENCLAW_SRC_DIR/.env"
  log "Synced .env into cloned OpenClaw repo"
}

compose() {
  (
    cd "$OPENCLAW_SRC_DIR"
    "${COMPOSE_CMD[@]}" -p "${COMPOSE_PROJECT_NAME}" --env-file "$OPENCLAW_SRC_DIR/.env" -f docker-compose.safe.yml "$@"
  )
}

stop_legacy_compose_projects() {
  local legacy
  for legacy in openclaw openclaw-easy-starter; do
    if [[ "$legacy" == "$COMPOSE_PROJECT_NAME" ]]; then
      continue
    fi
    (
      cd "$OPENCLAW_SRC_DIR"
      "${COMPOSE_CMD[@]}" -p "$legacy" --env-file "$OPENCLAW_SRC_DIR/.env" -f docker-compose.safe.yml down --remove-orphans >/dev/null 2>&1 || true
    )
  done
}

gateway_http_ok() {
  # Treat a reachable TCP listener as healthy; HTTP status/auth can vary.
  if (exec 3<>"/dev/tcp/127.0.0.1/${OPENCLAW_GATEWAY_PORT}") 2>/dev/null; then
    exec 3>&-
    exec 3<&-
    return 0
  fi
  return 1
}

gateway_container_status() {
  local container_id
  container_id="$(compose ps -q openclaw-gateway 2>/dev/null | tr -d '\r' | head -n 1)"
  if [[ -z "$container_id" ]]; then
    return 0
  fi
  docker inspect --format '{{.State.Status}}' "$container_id" 2>/dev/null || true
}

is_private_or_loopback_ip() {
  local ip
  ip="$(printf "%s" "${1:-}" | tr '[:upper:]' '[:lower:]' | xargs)"
  if [[ -z "$ip" ]]; then
    return 1
  fi
  [[ "$ip" == "127.0.0.1" ]] && return 0
  [[ "$ip" == "::1" ]] && return 0
  [[ "$ip" == 10.* ]] && return 0
  [[ "$ip" == 172.* ]] && return 0
  [[ "$ip" == 192.168.* ]] && return 0
  [[ "$ip" == fc* ]] && return 0
  [[ "$ip" == fd* ]] && return 0
  return 1
}

approve_local_pending_device_pairings() {
  local summary
  summary="$(compose exec -T openclaw-gateway node --input-type=module -e '
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
' 2>/dev/null || true)"
  local approved_count
  approved_count="$(printf "%s\n" "$summary" | sed -n 's/.*"approved":[[:space:]]*\([0-9][0-9]*\).*/\1/p' | tail -n 1)"
  if [[ -n "$approved_count" && "$approved_count" != "0" ]]; then
    printf "[openclaw-easy] Auto-approved %s local pending device pairing request(s).\n" "$approved_count"
  fi
}

default_dashboard_url() {
  if [[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ]]; then
    printf "http://127.0.0.1:%s/#token=%s\n" "${OPENCLAW_GATEWAY_PORT}" "${OPENCLAW_GATEWAY_TOKEN}"
  else
    printf "http://127.0.0.1:%s/\n" "${OPENCLAW_GATEWAY_PORT}"
  fi
}

parse_channel_plugin_list() {
  local raw="${1:-}"
  local seen="|"
  local out=()
  local token
  raw="${raw//,/ }"
  for token in $raw; do
    token="$(printf "%s" "$token" | xargs)"
    [[ -z "$token" ]] && continue
    if [[ "$seen" != *"|$token|"* ]]; then
      seen="${seen}${token}|"
      out+=("$token")
    fi
  done
  printf "%s\n" "${out[@]}"
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

test_browser_control_service() {
  local probe_out
  local detail
  probe_out="$(compose exec -T openclaw-gateway node dist/index.js browser status --json 2>&1 || true)"
  if [[ -z "$probe_out" ]]; then
    printf "probe returned no output\n"
    return 1
  fi
  if printf "%s\n" "$probe_out" | tr -d '\r' | grep -Eq '"enabled"[[:space:]]*:[[:space:]]*true' &&
    printf "%s\n" "$probe_out" | tr -d '\r' | grep -Eq '"(cdpHttp|running)"[[:space:]]*:[[:space:]]*true|"detectedBrowser"[[:space:]]*:[[:space:]]*"[^"]+"'; then
    detail="$(printf "%s\n" "$probe_out" | tr -d '\r' | tr '\n' ' ' | sed -E 's/.*"profile"[[:space:]]*:[[:space:]]*"([^"]+)".*/profile=\1/' )"
    if [[ "$detail" == "$probe_out" ]]; then
      detail="status=ok"
    fi
    printf "%s\n" "$detail"
    return 0
  fi
  printf "%s\n" "$probe_out" | tail -n 1
  return 1
}

clear_stale_browser_profile_locks() {
  compose run --rm --entrypoint sh openclaw-cli -lc '
set -eu
for dir in /home/node/.openclaw/browser/*/user-data; do
  [ -d "$dir" ] || continue
  rm -f "$dir/SingletonLock" "$dir/SingletonSocket" "$dir/SingletonCookie"
done
' >/dev/null 2>&1 || printf "[openclaw-easy] Could not clear stale browser profile locks (continuing).\n"
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

configure_agents() {
  local -a agent_rows=(
    "main|Jarvis"
    "dev|Dev Agent"
    "backend|Backend Engineer"
    "frontend|Frontend Engineer (React)"
    "designer|Designer"
    "ux|UI/UX Expert"
    "db|Database Engineer"
    "pm|PM Agent"
    "qa|QA Agent"
    "research|Research Agent"
    "ops|Ops Agent"
    "growth|Growth Agent"
    "finance|Financial Expert"
    "stocks|Stock Analyzer"
    "creative|Creative Agent"
    "motivation|Motivation Agent"
  )

  compose run --rm openclaw-cli config set agents.defaults.model.primary openai/gpt-5.2
  compose run --rm openclaw-cli config unset agents.defaults.model.fallbacks >/dev/null 2>&1 || true
  compose run --rm openclaw-cli config set 'agents.defaults.model.fallbacks[0]' openai/gpt-5-mini
  compose run --rm openclaw-cli config set agents.defaults.maxConcurrent 10 --json
  compose run --rm openclaw-cli config unset agents.list >/dev/null 2>&1 || true
  local index=0
  local row=""
  local agent_id=""
  local agent_name=""
  for row in "${agent_rows[@]}"; do
    agent_id="${row%%|*}"
    agent_name="${row#*|}"
    compose run --rm openclaw-cli config set "agents.list[$index].id" "$agent_id"
    compose run --rm openclaw-cli config set "agents.list[$index].name" "$agent_name"
    compose run --rm openclaw-cli config set "agents.list[$index].identity.name" "$agent_name"
    if [[ "$index" -eq 0 ]]; then
      compose run --rm openclaw-cli config set "agents.list[$index].default" true
      compose run --rm openclaw-cli config set "agents.list[$index].subagents.allowAgents[0]" "*"
    fi
    index=$((index + 1))
  done
  compose run --rm openclaw-cli config set tools.agentToAgent.enabled true --json
  compose run --rm openclaw-cli config unset tools.agentToAgent.allow >/dev/null 2>&1 || true
  compose run --rm openclaw-cli config set 'tools.agentToAgent.allow[0]' "*"
  compose run --rm openclaw-cli config set commands.bash true --json
  compose run --rm openclaw-cli config set tools.elevated.enabled true --json
  compose run --rm openclaw-cli config unset tools.elevated.allowFrom.web >/dev/null 2>&1 || true
  compose run --rm openclaw-cli config unset tools.elevated.allowFrom.webchat >/dev/null 2>&1 || true
  compose run --rm openclaw-cli config set 'tools.elevated.allowFrom.webchat[0]' "*"
}

configure_memory_defaults() {
  compose run --rm openclaw-cli config set agents.defaults.memorySearch.enabled true --json
  compose run --rm openclaw-cli config set agents.defaults.memorySearch.provider openai
  compose run --rm openclaw-cli config unset agents.defaults.memorySearch.sources >/dev/null 2>&1 || true
  compose run --rm openclaw-cli config set 'agents.defaults.memorySearch.sources[0]' memory
  compose run --rm openclaw-cli config set 'agents.defaults.memorySearch.sources[1]' sessions
  compose run --rm openclaw-cli config set agents.defaults.memorySearch.experimental.sessionMemory true --json
  compose run --rm openclaw-cli config set agents.defaults.memorySearch.sync.onSessionStart true --json
  compose run --rm openclaw-cli config set agents.defaults.memorySearch.sync.onSearch true --json
}

configure_exec_policy_mode() {
  local mode="${1:-prompt}"
  if [[ "$mode" == "allow" ]]; then
    compose run --rm openclaw-cli config set tools.exec.ask off
    compose run --rm openclaw-cli config set tools.exec.security full
  else
    compose run --rm openclaw-cli config set tools.exec.ask on-miss
    compose run --rm openclaw-cli config set tools.exec.security allowlist
  fi
}

sync_exec_approvals_mode() {
  local mode="${1:-prompt}"
  if [[ "$mode" == "allow" ]]; then
    compose run --rm openclaw-cli config set tools.exec.ask off >/dev/null 2>&1 || true
    compose run --rm openclaw-cli config set tools.exec.security full >/dev/null 2>&1 || true
  else
    compose run --rm openclaw-cli config set tools.exec.ask on-miss >/dev/null 2>&1 || true
    compose run --rm openclaw-cli config set tools.exec.security allowlist >/dev/null 2>&1 || true
  fi
}

bootstrap_agent_main_sessions() {
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
let bootstrapped = 0;

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
  bootstrapped += 1;
}

console.log(JSON.stringify({ requested: seed.length, bootstrapped }));
' >/dev/null 2>&1 || printf "[openclaw-easy] Could not bootstrap agent chat sessions (continuing).\n"
}

main() {
  maybe_delegate_to_powershell "$@"
  require_cmd docker
  require_cmd git
  resolve_compose

  load_env
  prompt_env_value OPENAI_API_KEY true false "OpenAI key is required to run onboarding."
  prompt_env_value SUPERMEMORY_API_KEY false true "Supermemory key is optional. Skip if you do not want Supermemory."

  if [[ -z "${SUPERMEMORY_OPENCLAW_API_KEY:-}" && -n "${SUPERMEMORY_API_KEY:-}" ]]; then
    SUPERMEMORY_OPENCLAW_API_KEY="$SUPERMEMORY_API_KEY"
    export SUPERMEMORY_OPENCLAW_API_KEY
    upsert_env "$ENV_FILE" "SUPERMEMORY_OPENCLAW_API_KEY" "$SUPERMEMORY_OPENCLAW_API_KEY"
  else
    export SUPERMEMORY_OPENCLAW_API_KEY
  fi

  if [[ -n "${SUPERMEMORY_OPENCLAW_API_KEY:-}" ]]; then
    export OPENCLAW_ENABLE_SUPERMEMORY=true
  else
    export OPENCLAW_ENABLE_SUPERMEMORY=false
  fi
  upsert_env "$ENV_FILE" "OPENCLAW_ENABLE_SUPERMEMORY" "$OPENCLAW_ENABLE_SUPERMEMORY"

  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-openclaw-easy}"
  upsert_env "$ENV_FILE" "COMPOSE_PROJECT_NAME" "$COMPOSE_PROJECT_NAME"
  export OPENCLAW_SAFE_PROJECT_NAME="${OPENCLAW_SAFE_PROJECT_NAME:-$COMPOSE_PROJECT_NAME}"
  upsert_env "$ENV_FILE" "OPENCLAW_SAFE_PROJECT_NAME" "$OPENCLAW_SAFE_PROJECT_NAME"

  export OPENCLAW_IMAGE="${OPENCLAW_IMAGE:-openclaw:local}"
  export OPENCLAW_GATEWAY_PORT="${OPENCLAW_GATEWAY_PORT:-18789}"
  export OPENCLAW_DEFAULT_CHANNEL_PLUGINS="${OPENCLAW_DEFAULT_CHANNEL_PLUGINS:-telegram,whatsapp}"
  export OPENCLAW_ALWAYS_ALLOW_EXEC="${OPENCLAW_ALWAYS_ALLOW_EXEC:-false}"
  upsert_env "$ENV_FILE" "OPENCLAW_ALWAYS_ALLOW_EXEC" "$OPENCLAW_ALWAYS_ALLOW_EXEC"
  export OPENCLAW_ENABLE_MISSION_CONTROL="${OPENCLAW_ENABLE_MISSION_CONTROL:-true}"
  upsert_env "$ENV_FILE" "OPENCLAW_ENABLE_MISSION_CONTROL" "$OPENCLAW_ENABLE_MISSION_CONTROL"
  export OPENCLAW_ENABLE_COMMAND_CENTER="${OPENCLAW_ENABLE_COMMAND_CENTER:-false}"
  upsert_env "$ENV_FILE" "OPENCLAW_ENABLE_COMMAND_CENTER" "$OPENCLAW_ENABLE_COMMAND_CENTER"
  export OPENCLAW_MISSION_CONTROL_REPO_URL="${OPENCLAW_MISSION_CONTROL_REPO_URL:-https://github.com/abhi1693/openclaw-mission-control.git}"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_REPO_URL" "$OPENCLAW_MISSION_CONTROL_REPO_URL"
  export OPENCLAW_MISSION_CONTROL_REPO_BRANCH="${OPENCLAW_MISSION_CONTROL_REPO_BRANCH:-master}"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_REPO_BRANCH" "$OPENCLAW_MISSION_CONTROL_REPO_BRANCH"
  export OPENCLAW_MISSION_CONTROL_SRC_DIR="${OPENCLAW_MISSION_CONTROL_SRC_DIR:-$ROOT_DIR/vendor/openclaw-mission-control}"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_SRC_DIR" "$OPENCLAW_MISSION_CONTROL_SRC_DIR"
  export OPENCLAW_MISSION_CONTROL_FRONTEND_PORT="${OPENCLAW_MISSION_CONTROL_FRONTEND_PORT:-3310}"
  export OPENCLAW_MISSION_CONTROL_BACKEND_PORT="${OPENCLAW_MISSION_CONTROL_BACKEND_PORT:-8310}"
  export OPENCLAW_MISSION_CONTROL_POSTGRES_PORT="${OPENCLAW_MISSION_CONTROL_POSTGRES_PORT:-55432}"
  export OPENCLAW_MISSION_CONTROL_REDIS_PORT="${OPENCLAW_MISSION_CONTROL_REDIS_PORT:-56379}"
  export OPENCLAW_MISSION_CONTROL_POSTGRES_DB="${OPENCLAW_MISSION_CONTROL_POSTGRES_DB:-mission_control}"
  export OPENCLAW_MISSION_CONTROL_POSTGRES_USER="${OPENCLAW_MISSION_CONTROL_POSTGRES_USER:-postgres}"
  export OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD="${OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD:-}"
  if [[ -z "${OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD:-}" || "${OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD}" == "postgres" ]]; then
    OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD="$(generate_token)"
    export OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD
    printf "[openclaw-easy] Generated secure Mission Control Postgres password.\n"
  fi
  export OPENCLAW_MISSION_CONTROL_AUTOCONFIG_GATEWAY="${OPENCLAW_MISSION_CONTROL_AUTOCONFIG_GATEWAY:-true}"
  export OPENCLAW_MISSION_CONTROL_SYNC_TEMPLATES="${OPENCLAW_MISSION_CONTROL_SYNC_TEMPLATES:-true}"
  export OPENCLAW_MISSION_CONTROL_GATEWAY_NAME="${OPENCLAW_MISSION_CONTROL_GATEWAY_NAME:-OpenClaw Docker Gateway}"
  export OPENCLAW_MISSION_CONTROL_GATEWAY_WORKSPACE_ROOT="${OPENCLAW_MISSION_CONTROL_GATEWAY_WORKSPACE_ROOT:-/home/node/.openclaw}"
  export OPENCLAW_MISSION_CONTROL_GATEWAY_ID="${OPENCLAW_MISSION_CONTROL_GATEWAY_ID:-}"
  export OPENCLAW_MISSION_CONTROL_GATEWAY_URL="${OPENCLAW_MISSION_CONTROL_GATEWAY_URL:-}"
  export OPENCLAW_MISSION_CONTROL_BASE_URL="${OPENCLAW_MISSION_CONTROL_BASE_URL:-}"
  export OPENCLAW_MISSION_CONTROL_SEED_BOARD="${OPENCLAW_MISSION_CONTROL_SEED_BOARD:-true}"
  export OPENCLAW_MISSION_CONTROL_BOARD_NAME="${OPENCLAW_MISSION_CONTROL_BOARD_NAME:-Main Board}"
  export OPENCLAW_MISSION_CONTROL_BOARD_SLUG="${OPENCLAW_MISSION_CONTROL_BOARD_SLUG:-main-board}"
  export OPENCLAW_MISSION_CONTROL_BOARD_DESCRIPTION="${OPENCLAW_MISSION_CONTROL_BOARD_DESCRIPTION:-Primary board for OpenClaw automation.}"
  export OPENCLAW_MISSION_CONTROL_BOARD_PERSPECTIVE="${OPENCLAW_MISSION_CONTROL_BOARD_PERSPECTIVE:-Pragmatic execution: prioritize outcomes, clear ownership, and fast feedback loops.}"
  export OPENCLAW_MISSION_CONTROL_BOARD_TYPE="${OPENCLAW_MISSION_CONTROL_BOARD_TYPE:-goal}"
  export OPENCLAW_MISSION_CONTROL_BOARD_OBJECTIVE="${OPENCLAW_MISSION_CONTROL_BOARD_OBJECTIVE:-}"
  export OPENCLAW_MISSION_CONTROL_BOARD_SUCCESS_METRICS_JSON="${OPENCLAW_MISSION_CONTROL_BOARD_SUCCESS_METRICS_JSON:-}"
  export OPENCLAW_MISSION_CONTROL_BOARD_TARGET_DATE="${OPENCLAW_MISSION_CONTROL_BOARD_TARGET_DATE:-}"
  export OPENCLAW_MISSION_CONTROL_BOARD_GOAL_CONFIRMED="${OPENCLAW_MISSION_CONTROL_BOARD_GOAL_CONFIRMED:-false}"
  export OPENCLAW_MISSION_CONTROL_BOARD_GOAL_SOURCE="${OPENCLAW_MISSION_CONTROL_BOARD_GOAL_SOURCE:-}"
  export OPENCLAW_MISSION_CONTROL_BOARD_GROUP_ID="${OPENCLAW_MISSION_CONTROL_BOARD_GROUP_ID:-}"
  export OPENCLAW_MISSION_CONTROL_BOARD_MAX_AGENTS="${OPENCLAW_MISSION_CONTROL_BOARD_MAX_AGENTS:-1}"
  export OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_JSON="${OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_JSON:-}"
  export OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE="${OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE:-}"
  export OPENCLAW_COMMAND_CENTER_REPO_URL="${OPENCLAW_COMMAND_CENTER_REPO_URL:-https://github.com/jontsai/openclaw-command-center.git}"
  upsert_env "$ENV_FILE" "OPENCLAW_COMMAND_CENTER_REPO_URL" "$OPENCLAW_COMMAND_CENTER_REPO_URL"
  export OPENCLAW_COMMAND_CENTER_REPO_BRANCH="${OPENCLAW_COMMAND_CENTER_REPO_BRANCH:-main}"
  upsert_env "$ENV_FILE" "OPENCLAW_COMMAND_CENTER_REPO_BRANCH" "$OPENCLAW_COMMAND_CENTER_REPO_BRANCH"
  export OPENCLAW_COMMAND_CENTER_SRC_DIR="${OPENCLAW_COMMAND_CENTER_SRC_DIR:-$ROOT_DIR/vendor/openclaw-command-center}"
  upsert_env "$ENV_FILE" "OPENCLAW_COMMAND_CENTER_SRC_DIR" "$OPENCLAW_COMMAND_CENTER_SRC_DIR"
  export OPENCLAW_COMMAND_CENTER_PORT="${OPENCLAW_COMMAND_CENTER_PORT:-3340}"
  export OPENCLAW_COMMAND_CENTER_AUTH_MODE="${OPENCLAW_COMMAND_CENTER_AUTH_MODE:-token}"
  export OPENCLAW_COMMAND_CENTER_TOKEN="${OPENCLAW_COMMAND_CENTER_TOKEN:-}"
  if [[ "${OPENCLAW_COMMAND_CENTER_AUTH_MODE,,}" == "token" && -z "${OPENCLAW_COMMAND_CENTER_TOKEN:-}" ]]; then
    OPENCLAW_COMMAND_CENTER_TOKEN="$(generate_token)"
    export OPENCLAW_COMMAND_CENTER_TOKEN
    printf "[openclaw-easy] Generated Command Center dashboard token.\n"
  fi
  export OPENCLAW_COMMAND_CENTER_ALLOWED_USERS="${OPENCLAW_COMMAND_CENTER_ALLOWED_USERS:-*}"
  export OPENCLAW_COMMAND_CENTER_ALLOWED_IPS="${OPENCLAW_COMMAND_CENTER_ALLOWED_IPS:-127.0.0.1,::1}"
  export OPENCLAW_COMMAND_CENTER_OPENCLAW_PROFILE="${OPENCLAW_COMMAND_CENTER_OPENCLAW_PROFILE:-}"
  gateway_reserved="$(normalize_port "${OPENCLAW_GATEWAY_PORT}" 18789)"
  requested_mc_frontend="$(normalize_port "${OPENCLAW_MISSION_CONTROL_FRONTEND_PORT}" 3310)"
  requested_mc_backend="$(normalize_port "${OPENCLAW_MISSION_CONTROL_BACKEND_PORT}" 8310)"
  requested_mc_postgres="$(normalize_port "${OPENCLAW_MISSION_CONTROL_POSTGRES_PORT}" 55432)"
  requested_mc_redis="$(normalize_port "${OPENCLAW_MISSION_CONTROL_REDIS_PORT}" 56379)"
  requested_command_center_port="$(normalize_port "${OPENCLAW_COMMAND_CENTER_PORT}" 3340)"
  reserved_ports="|${gateway_reserved}|"
  resolved_mc_frontend="$(resolve_available_port "$requested_mc_frontend" "$reserved_ports" || true)"
  if [[ -z "$resolved_mc_frontend" ]]; then
    fail "No available host port found near Mission Control frontend port ${requested_mc_frontend}."
  fi
  reserved_ports="${reserved_ports}${resolved_mc_frontend}|"
  resolved_mc_backend="$(resolve_available_port "$requested_mc_backend" "$reserved_ports" || true)"
  if [[ -z "$resolved_mc_backend" ]]; then
    fail "No available host port found near Mission Control backend port ${requested_mc_backend}."
  fi
  reserved_ports="${reserved_ports}${resolved_mc_backend}|"
  resolved_mc_postgres="$(resolve_available_port "$requested_mc_postgres" "$reserved_ports" || true)"
  if [[ -z "$resolved_mc_postgres" ]]; then
    fail "No available host port found near Mission Control postgres port ${requested_mc_postgres}."
  fi
  reserved_ports="${reserved_ports}${resolved_mc_postgres}|"
  resolved_mc_redis="$(resolve_available_port "$requested_mc_redis" "$reserved_ports" || true)"
  if [[ -z "$resolved_mc_redis" ]]; then
    fail "No available host port found near Mission Control redis port ${requested_mc_redis}."
  fi
  reserved_ports="${reserved_ports}${resolved_mc_redis}|"
  resolved_command_center_port="$(resolve_available_port "$requested_command_center_port" "$reserved_ports" || true)"
  if [[ -z "$resolved_command_center_port" ]]; then
    fail "No available host port found near Command Center port ${requested_command_center_port}."
  fi
  export OPENCLAW_MISSION_CONTROL_FRONTEND_PORT="$resolved_mc_frontend"
  export OPENCLAW_MISSION_CONTROL_BACKEND_PORT="$resolved_mc_backend"
  export OPENCLAW_MISSION_CONTROL_POSTGRES_PORT="$resolved_mc_postgres"
  export OPENCLAW_MISSION_CONTROL_REDIS_PORT="$resolved_mc_redis"
  export OPENCLAW_COMMAND_CENTER_PORT="$resolved_command_center_port"
  if [[ "$resolved_mc_frontend" != "$requested_mc_frontend" ]]; then
    printf "[openclaw-easy] Mission Control frontend port %s is busy; using %s.\n" "$requested_mc_frontend" "$resolved_mc_frontend"
  fi
  if [[ "$resolved_mc_backend" != "$requested_mc_backend" ]]; then
    printf "[openclaw-easy] Mission Control backend port %s is busy; using %s.\n" "$requested_mc_backend" "$resolved_mc_backend"
  fi
  if [[ "$resolved_mc_postgres" != "$requested_mc_postgres" ]]; then
    printf "[openclaw-easy] Mission Control postgres port %s is busy; using %s.\n" "$requested_mc_postgres" "$resolved_mc_postgres"
  fi
  if [[ "$resolved_mc_redis" != "$requested_mc_redis" ]]; then
    printf "[openclaw-easy] Mission Control redis port %s is busy; using %s.\n" "$requested_mc_redis" "$resolved_mc_redis"
  fi
  if [[ "$resolved_command_center_port" != "$requested_command_center_port" ]]; then
    printf "[openclaw-easy] Command Center port %s is busy; using %s.\n" "$requested_command_center_port" "$resolved_command_center_port"
  fi
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_FRONTEND_PORT" "$OPENCLAW_MISSION_CONTROL_FRONTEND_PORT"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BACKEND_PORT" "$OPENCLAW_MISSION_CONTROL_BACKEND_PORT"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_POSTGRES_PORT" "$OPENCLAW_MISSION_CONTROL_POSTGRES_PORT"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_REDIS_PORT" "$OPENCLAW_MISSION_CONTROL_REDIS_PORT"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_POSTGRES_DB" "$OPENCLAW_MISSION_CONTROL_POSTGRES_DB"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_POSTGRES_USER" "$OPENCLAW_MISSION_CONTROL_POSTGRES_USER"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD" "$OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_AUTOCONFIG_GATEWAY" "$OPENCLAW_MISSION_CONTROL_AUTOCONFIG_GATEWAY"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_SYNC_TEMPLATES" "$OPENCLAW_MISSION_CONTROL_SYNC_TEMPLATES"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_GATEWAY_NAME" "$OPENCLAW_MISSION_CONTROL_GATEWAY_NAME"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_GATEWAY_WORKSPACE_ROOT" "$OPENCLAW_MISSION_CONTROL_GATEWAY_WORKSPACE_ROOT"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_GATEWAY_ID" "$OPENCLAW_MISSION_CONTROL_GATEWAY_ID"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_GATEWAY_URL" "$OPENCLAW_MISSION_CONTROL_GATEWAY_URL"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BASE_URL" "$OPENCLAW_MISSION_CONTROL_BASE_URL"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_SEED_BOARD" "$OPENCLAW_MISSION_CONTROL_SEED_BOARD"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BOARD_NAME" "$OPENCLAW_MISSION_CONTROL_BOARD_NAME"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BOARD_SLUG" "$OPENCLAW_MISSION_CONTROL_BOARD_SLUG"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BOARD_DESCRIPTION" "$OPENCLAW_MISSION_CONTROL_BOARD_DESCRIPTION"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BOARD_PERSPECTIVE" "$OPENCLAW_MISSION_CONTROL_BOARD_PERSPECTIVE"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BOARD_TYPE" "$OPENCLAW_MISSION_CONTROL_BOARD_TYPE"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BOARD_OBJECTIVE" "$OPENCLAW_MISSION_CONTROL_BOARD_OBJECTIVE"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BOARD_SUCCESS_METRICS_JSON" "$OPENCLAW_MISSION_CONTROL_BOARD_SUCCESS_METRICS_JSON"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BOARD_TARGET_DATE" "$OPENCLAW_MISSION_CONTROL_BOARD_TARGET_DATE"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BOARD_GOAL_CONFIRMED" "$OPENCLAW_MISSION_CONTROL_BOARD_GOAL_CONFIRMED"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BOARD_GOAL_SOURCE" "$OPENCLAW_MISSION_CONTROL_BOARD_GOAL_SOURCE"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BOARD_GROUP_ID" "$OPENCLAW_MISSION_CONTROL_BOARD_GROUP_ID"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BOARD_MAX_AGENTS" "$OPENCLAW_MISSION_CONTROL_BOARD_MAX_AGENTS"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_JSON" "$OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_JSON"
  upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE" "$OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE"
  upsert_env "$ENV_FILE" "OPENCLAW_COMMAND_CENTER_PORT" "$OPENCLAW_COMMAND_CENTER_PORT"
  upsert_env "$ENV_FILE" "OPENCLAW_COMMAND_CENTER_AUTH_MODE" "$OPENCLAW_COMMAND_CENTER_AUTH_MODE"
  upsert_env "$ENV_FILE" "OPENCLAW_COMMAND_CENTER_TOKEN" "$OPENCLAW_COMMAND_CENTER_TOKEN"
  upsert_env "$ENV_FILE" "OPENCLAW_COMMAND_CENTER_ALLOWED_USERS" "$OPENCLAW_COMMAND_CENTER_ALLOWED_USERS"
  upsert_env "$ENV_FILE" "OPENCLAW_COMMAND_CENTER_ALLOWED_IPS" "$OPENCLAW_COMMAND_CENTER_ALLOWED_IPS"
  upsert_env "$ENV_FILE" "OPENCLAW_COMMAND_CENTER_OPENCLAW_PROFILE" "$OPENCLAW_COMMAND_CENTER_OPENCLAW_PROFILE"
  if [[ -z "${OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN:-}" ]]; then
    OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN="$(generate_token)$(generate_token)"
    export OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN
    upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN" "$OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN"
  fi
  local exec_mode="prompt"
  if is_truthy "${OPENCLAW_ALWAYS_ALLOW_EXEC}"; then
    exec_mode="allow"
  fi
  export OPENCLAW_REPO_URL="${OPENCLAW_REPO_URL:-https://github.com/openclaw/openclaw.git}"
  if [[ -z "${OPENCLAW_REPO_BRANCH:-}" || "${OPENCLAW_REPO_BRANCH:-}" == "v2026.2.14" ]]; then
    export OPENCLAW_REPO_BRANCH="main"
    upsert_env "$ENV_FILE" "OPENCLAW_REPO_BRANCH" "$OPENCLAW_REPO_BRANCH"
  fi
  if [[ "${OPENCLAW_USE_LOCAL_SOURCE:-auto}" == "auto" && -z "${OPENCLAW_SRC_DIR:-}" ]]; then
    if local_source="$(detect_local_openclaw_repo "$ROOT_DIR" 2>/dev/null)"; then
      export OPENCLAW_USE_LOCAL_SOURCE=true
      export OPENCLAW_SRC_DIR="$local_source"
      upsert_env "$ENV_FILE" "OPENCLAW_USE_LOCAL_SOURCE" "$OPENCLAW_USE_LOCAL_SOURCE"
      upsert_env "$ENV_FILE" "OPENCLAW_SRC_DIR" "$OPENCLAW_SRC_DIR"
    else
      export OPENCLAW_USE_LOCAL_SOURCE=false
    fi
  fi
  export OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES:-chromium git python3 python3-pip sudo}"
  if [[ " ${OPENCLAW_DOCKER_APT_PACKAGES} " != *" chromium "* ]]; then
    OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES} chromium"
  fi
  if [[ " ${OPENCLAW_DOCKER_APT_PACKAGES} " != *" git "* ]]; then
    OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES} git"
  fi
  if [[ " ${OPENCLAW_DOCKER_APT_PACKAGES} " != *" python3 "* ]]; then
    OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES} python3"
  fi
  if [[ " ${OPENCLAW_DOCKER_APT_PACKAGES} " != *" python3-pip "* ]]; then
    OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES} python3-pip"
  fi
  if [[ " ${OPENCLAW_DOCKER_APT_PACKAGES} " != *" sudo "* ]]; then
    OPENCLAW_DOCKER_APT_PACKAGES="${OPENCLAW_DOCKER_APT_PACKAGES} sudo"
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
  sync_vendor_env_file

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
  compose run --rm openclaw-cli config set gateway.controlUi.allowInsecureAuth true --json
  compose run --rm openclaw-cli config set gateway.controlUi.dangerouslyDisableDeviceAuth true --json
  compose run --rm openclaw-cli onboard \
    --non-interactive --accept-risk \
    --auth-choice openai-api-key \
    --openai-api-key "$OPENAI_API_KEY" \
    --skip-channels --skip-skills --skip-health --no-install-daemon
  compose run --rm openclaw-cli config set gateway.mode local
  compose run --rm openclaw-cli config set gateway.auth.mode token
  compose run --rm openclaw-cli config set gateway.auth.token "$OPENCLAW_GATEWAY_TOKEN"
  compose run --rm openclaw-cli config set gateway.controlUi.allowInsecureAuth true --json
  compose run --rm openclaw-cli config set gateway.controlUi.dangerouslyDisableDeviceAuth true --json

  log "Applying defaults (CLI backends, concurrency, agent pack)"
  compose run --rm openclaw-cli config set "agents.defaults.cliBackends[claude-cli].command" "/home/node/.openclaw/tools/bin/claude"
  compose run --rm openclaw-cli config set "agents.defaults.cliBackends[codex-cli].command" "/home/node/.openclaw/tools/bin/codex"
  compose run --rm openclaw-cli config set "agents.defaults.cliBackends[codex-cli].env.OPENAI_API_KEY" '${OPENAI_API_KEY}'
  compose run --rm openclaw-cli config set agents.defaults.subagents.maxConcurrent 8 --json
  configure_agents
  configure_exec_policy_mode "$exec_mode"
  sync_exec_approvals_mode "$exec_mode"
  configure_memory_defaults
  compose run --rm openclaw-cli config set browser.enabled true --json
  compose run --rm openclaw-cli config set browser.headless true --json
  compose run --rm openclaw-cli config set browser.noSandbox true --json
  compose run --rm openclaw-cli config set browser.defaultProfile openclaw

  if [[ "${OPENCLAW_ENABLE_SUPERMEMORY}" == "true" ]]; then
    log "Installing and configuring Supermemory plugin"
    if ! compose run --rm openclaw-cli plugins info openclaw-supermemory --json >/dev/null 2>&1; then
      compose run --rm openclaw-cli plugins install @supermemory/openclaw-supermemory
    fi
    compose run --rm openclaw-cli config set plugins.entries.openclaw-supermemory.enabled true --json
    compose run --rm openclaw-cli config set plugins.entries.openclaw-supermemory.config.apiKey '${SUPERMEMORY_OPENCLAW_API_KEY}'
  else
    log "Skipping Supermemory plugin (no key provided)"
    compose run --rm openclaw-cli config set plugins.entries.openclaw-supermemory.enabled false --json || true
  fi

  log "Bootstrapping tools + skills"
  compose run --rm --entrypoint sh openclaw-cli -lc '
set -eu
WORKSPACE=/home/node/.openclaw/workspace
TMP_DIR="$WORKSPACE/tmp"
SKILLS_DIR="$WORKSPACE/skills"
TOOLS_DIR=/home/node/.openclaw/tools
CLAWHUB_BIN="$TOOLS_DIR/bin/clawhub"

mkdir -p "$TMP_DIR" "$SKILLS_DIR" "$TOOLS_DIR"
PROFILE_FILE=/home/node/.profile
if [ -f "$PROFILE_FILE" ]; then
  grep -Fq 'export PATH="$HOME/.local/bin:$HOME/.openclaw/tools/bin:$PATH"' "$PROFILE_FILE" || echo 'export PATH="$HOME/.local/bin:$HOME/.openclaw/tools/bin:$PATH"' >> "$PROFILE_FILE"
else
  echo 'export PATH="$HOME/.local/bin:$HOME/.openclaw/tools/bin:$PATH"' > "$PROFILE_FILE"
fi

npm i -g clawhub --prefix "$TOOLS_DIR"
rm -f "$TOOLS_DIR/bin/claude" "$TOOLS_DIR/bin/codex" "$TOOLS_DIR/bin/playwright"
npm i -g @anthropic-ai/claude-code @openai/codex playwright --prefix "$TOOLS_DIR" --force

cat > "$TOOLS_DIR/bin/openclaw" <<'EOF'
#!/usr/bin/env sh
set -eu
exec node /app/dist/index.js "$@"
EOF
chmod +x "$TOOLS_DIR/bin/openclaw"

cat > "$TOOLS_DIR/bin/agent-browser" <<'EOF'
#!/usr/bin/env sh
set -eu

OPENCLAW_BIN=/home/node/.openclaw/tools/bin/openclaw
if [ ! -x $OPENCLAW_BIN ]; then
  OPENCLAW_BIN=openclaw
fi

cmd=${1-}
if [ $# -gt 0 ]; then
  shift
fi

case ${cmd-} in
  -h|--help|help|'')
    exec $OPENCLAW_BIN browser --help
    ;;
  -v|--version|version)
    exec $OPENCLAW_BIN --version
    ;;
  open)
    exec $OPENCLAW_BIN browser open $@
    ;;
  snapshot)
    if [ x${1-} = x-i ]; then
      shift
      exec $OPENCLAW_BIN browser snapshot --interactive $@
    fi
    exec $OPENCLAW_BIN browser snapshot $@
    ;;
  screenshot)
    exec $OPENCLAW_BIN browser screenshot $@
    ;;
  close)
    exec $OPENCLAW_BIN browser close $@
    ;;
  *)
    exec $OPENCLAW_BIN browser ${cmd-} $@
    ;;
esac
EOF
chmod +x "$TOOLS_DIR/bin/agent-browser"

export PLAYWRIGHT_BROWSERS_PATH=/home/node/.cache/ms-playwright
mkdir -p "$PLAYWRIGHT_BROWSERS_PATH"
if command -v sudo >/dev/null 2>&1; then
  sudo -n "$TOOLS_DIR/bin/playwright" install --with-deps chromium >/dev/null 2>&1 || "$TOOLS_DIR/bin/playwright" install chromium >/dev/null 2>&1 || true
else
  "$TOOLS_DIR/bin/playwright" install chromium >/dev/null 2>&1 || true
fi

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

rm -rf "$TMP_DIR/openclaw-community-skills"
git clone --depth 1 https://github.com/openclaw/skills "$TMP_DIR/openclaw-community-skills"
for pair in \
  gxsy886/downloads \
  itsahedge/agent-council \
  nguyenphutrong/agentlens \
  satyajiit/aster \
  jasonfdg/bidclub \
  hexnickk/claude-optimised \
  bowen31337/create-agent-skills \
  qrucio/anthropic-frontend-design \
  tommygeoco/ui-audit \
  adinvadim/2captcha \
  dowingard/agent-zero-bridge \
  murphykobe/agent-browser-2 \
  lucasgeeksinthewood/dating \
  steipete/local-places \
  tiborera/clawexchange \
  felo-sparticle/clawdwork \
  seyhunak/deep-research \
  nextfrontierbuilds/web-qa-bot \
  myestery/verify-on-browser \
  iahmadzain/home-assistant \
  gumadeiras/playwright-cli \
  alirezarezvani/quality-manager-qmr \
  nextfrontierbuilds/skill-scaffold \
  alirezarezvani/tdd-guide \
  alirezarezvani/cto-advisor \
  autogame-17/evolver \
  steipete/coding-agent
do
  owner="${pair%%/*}"
  skill="${pair##*/}"
  src="$TMP_DIR/openclaw-community-skills/skills/$owner/$skill"
  if [ -d "$src" ]; then
    rm -rf "$SKILLS_DIR/$skill"
    cp -a "$src" "$SKILLS_DIR/$skill"
  fi
done

rm -rf "$TMP_DIR/openclaw-supermemory"
git clone --depth 1 https://github.com/supermemoryai/openclaw-supermemory "$TMP_DIR/openclaw-supermemory"

export PATH="$TOOLS_DIR/bin:$PATH"
cd "$WORKSPACE"
for slug in gmail github automation-workflows playwright-mcp summarize weather skill-creator openclaw-github-assistant github-mcp github-cli github-automation-pro; do
  "$CLAWHUB_BIN" install "$slug" --force || "$CLAWHUB_BIN" update "$slug" || true
done

# ClawHub installs can replace wrappers; enforce executable bits again.
chmod +x "$TOOLS_DIR/bin/openclaw" "$TOOLS_DIR/bin/agent-browser" || true
'

  log "Finalizing CLI backend commands"
  compose run --rm openclaw-cli config set "agents.defaults.cliBackends[claude-cli].command" "/home/node/.openclaw/tools/bin/claude"
  compose run --rm openclaw-cli config set "agents.defaults.cliBackends[codex-cli].command" "/home/node/.openclaw/tools/bin/codex"
  compose run --rm openclaw-cli config set "agents.defaults.cliBackends[codex-cli].env.OPENAI_API_KEY" '${OPENAI_API_KEY}'

  log "Priming long-memory search index"
  compose run --rm openclaw-cli memory index --agent main >/dev/null 2>&1 || \
    printf "[openclaw-easy] Memory index warmup failed (continuing).\n"

  log "Enabling channel plugins for Control UI schema"
  while IFS= read -r plugin_id; do
    [[ -z "$plugin_id" ]] && continue
    compose run --rm openclaw-cli plugins enable "$plugin_id" >/dev/null 2>&1 || \
      printf "[openclaw-easy] Could not enable channel plugin '%s' (continuing).\n" "$plugin_id"
  done < <(parse_channel_plugin_list "$OPENCLAW_DEFAULT_CHANNEL_PLUGINS")

  log "Starting gateway"
  stop_legacy_compose_projects
  clear_stale_browser_profile_locks
  compose up -d openclaw-gateway >/dev/null 2>&1 || true
  sleep 2

  log "Health check"
  healthy=false
  for attempt in $(seq 1 60); do
    if [[ "$attempt" -eq 1 || $((attempt % 5)) -eq 0 ]]; then
      printf "[openclaw-easy] waiting for gateway port 127.0.0.1:%s (attempt %s/60)\n" "$OPENCLAW_GATEWAY_PORT" "$attempt"
    fi
    if gateway_http_ok; then
      healthy=true
      break
    fi
    if [[ "$attempt" -eq 1 || $((attempt % 4)) -eq 0 ]]; then
      compose up -d openclaw-gateway || true
      status="$(gateway_container_status || true)"
      if [[ -n "$status" ]]; then
        printf "[openclaw-easy] gateway status: %s\n" "$status"
      else
        printf "[openclaw-easy] gateway status: unknown\n"
      fi
    fi
    sleep 2
  done
  if [[ "$healthy" != "true" ]]; then
    printf "[openclaw-easy] gateway ps:\n"
    compose ps || true
    printf "[openclaw-easy] gateway logs (last 120 lines):\n"
    compose logs --tail=120 openclaw-gateway || true
    fail "Gateway health check failed after retries."
  fi

  log "Warming browser control service"
  browser_ready=false
  for attempt in $(seq 1 15); do
    probe_detail="$(test_browser_control_service || true)"
    if [[ -n "$probe_detail" && "$probe_detail" == profiles=* ]]; then
      browser_ready=true
      break
    fi
    if [[ "$attempt" -eq 1 || $((attempt % 5)) -eq 0 ]]; then
      printf "[openclaw-easy] browser probe retry %s/15: %s\n" "$attempt" "${probe_detail:-unknown}"
    fi
    sleep 2
  done
  if [[ "$browser_ready" != "true" ]]; then
    printf "[openclaw-easy] gateway logs (last 120 lines):\n"
    compose logs --tail=120 openclaw-gateway || true
    printf "[openclaw-easy] Browser warmup probe failed after retries (continuing).\n"
    printf "[openclaw-easy] Gateway is running; browser service may initialize on first browser action.\n"
  fi

  approve_local_pending_device_pairings
  bootstrap_agent_main_sessions

  mission_control_dashboard_url=""
  mission_control_registered_gateway_url=""
  mission_control_registered_gateway_id=""
  mission_control_seed_board_summary=""
  command_center_dashboard_url=""
  if is_truthy "${OPENCLAW_ENABLE_MISSION_CONTROL}"; then
    clone_or_update_mission_control
    patch_mission_control_security_baselines "$OPENCLAW_MISSION_CONTROL_SRC_DIR"
    patch_mission_control_gateway_scopes "$OPENCLAW_MISSION_CONTROL_SRC_DIR"
    patch_mission_control_onboarding_recovery "$OPENCLAW_MISSION_CONTROL_SRC_DIR"
    patch_mission_control_onboarding_session_isolation "$OPENCLAW_MISSION_CONTROL_SRC_DIR"
    patch_mission_control_onboarding_agent_labels "$OPENCLAW_MISSION_CONTROL_SRC_DIR"
    mission_control_env_file="$OPENCLAW_MISSION_CONTROL_SRC_DIR/.env"
    mission_control_env_example="$OPENCLAW_MISSION_CONTROL_SRC_DIR/.env.example"
    if [[ ! -f "$mission_control_env_file" && -f "$mission_control_env_example" ]]; then
      cp "$mission_control_env_example" "$mission_control_env_file"
    fi
    if [[ ! -f "$mission_control_env_file" ]]; then
      fail "Mission Control .env file is missing: $mission_control_env_file"
    fi

    mission_control_frontend_url="http://127.0.0.1:${OPENCLAW_MISSION_CONTROL_FRONTEND_PORT}"
    mission_control_backend_url="http://127.0.0.1:${OPENCLAW_MISSION_CONTROL_BACKEND_PORT}"
    mission_control_backend_container_host="${COMPOSE_PROJECT_NAME}-mission-control-backend-1"
    mission_control_agent_base_url="${OPENCLAW_MISSION_CONTROL_BASE_URL:-}"
    if [[ -z "$mission_control_agent_base_url" ]]; then
      mission_control_agent_base_url="http://${mission_control_backend_container_host}:8000"
      export OPENCLAW_MISSION_CONTROL_BASE_URL="$mission_control_agent_base_url"
      upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_BASE_URL" "$OPENCLAW_MISSION_CONTROL_BASE_URL"
    fi

    upsert_env "$mission_control_env_file" "FRONTEND_PORT" "$OPENCLAW_MISSION_CONTROL_FRONTEND_PORT"
    upsert_env "$mission_control_env_file" "BACKEND_PORT" "$OPENCLAW_MISSION_CONTROL_BACKEND_PORT"
    upsert_env "$mission_control_env_file" "POSTGRES_PORT" "$OPENCLAW_MISSION_CONTROL_POSTGRES_PORT"
    upsert_env "$mission_control_env_file" "REDIS_PORT" "$OPENCLAW_MISSION_CONTROL_REDIS_PORT"
    upsert_env "$mission_control_env_file" "POSTGRES_DB" "$OPENCLAW_MISSION_CONTROL_POSTGRES_DB"
    upsert_env "$mission_control_env_file" "POSTGRES_USER" "$OPENCLAW_MISSION_CONTROL_POSTGRES_USER"
    upsert_env "$mission_control_env_file" "POSTGRES_PASSWORD" "$OPENCLAW_MISSION_CONTROL_POSTGRES_PASSWORD"
    upsert_env "$mission_control_env_file" "AUTH_MODE" "local"
    upsert_env "$mission_control_env_file" "LOCAL_AUTH_TOKEN" "$OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN"
    upsert_env "$mission_control_env_file" "CORS_ORIGINS" "$mission_control_frontend_url"
    upsert_env "$mission_control_env_file" "NEXT_PUBLIC_API_URL" "$mission_control_backend_url"
    upsert_env "$mission_control_env_file" "BASE_URL" "$mission_control_agent_base_url"
    upsert_env "$mission_control_env_file" "DB_AUTO_MIGRATE" "true"

    mission_control_frontend_env="$OPENCLAW_MISSION_CONTROL_SRC_DIR/frontend/.env"
    upsert_env "$mission_control_frontend_env" "NEXT_PUBLIC_API_URL" "$mission_control_backend_url"
    upsert_env "$mission_control_frontend_env" "NEXT_PUBLIC_AUTH_MODE" "local"
    mission_control_backend_env_example="$OPENCLAW_MISSION_CONTROL_SRC_DIR/backend/.env.example"
    if [[ -f "$mission_control_backend_env_example" ]]; then
      upsert_env "$mission_control_backend_env_example" "BASE_URL" "$mission_control_agent_base_url"
    fi
    mission_control_backend_env="$OPENCLAW_MISSION_CONTROL_SRC_DIR/backend/.env"
    if [[ -f "$mission_control_backend_env" ]]; then
      upsert_env "$mission_control_backend_env" "BASE_URL" "$mission_control_agent_base_url"
    fi

    log "Starting Mission Control"
    mission_control_compose up -d --build

    log "Mission Control health check"
    mission_control_ready=false
    for attempt in $(seq 1 90); do
      if mission_control_http_200 "${mission_control_frontend_url}/"; then
        mission_control_ready=true
        break
      fi
      if [[ "$attempt" -eq 1 || $((attempt % 10)) -eq 0 ]]; then
        printf "[openclaw-easy] waiting for Mission Control UI %s (attempt %s/90)\n" "$mission_control_frontend_url" "$attempt"
        mission_control_compose ps || true
      fi
      sleep 2
    done
    if [[ "$mission_control_ready" != "true" ]]; then
      printf "[openclaw-easy] Mission Control logs (backend, frontend; last 120 lines):\n"
      mission_control_compose logs --tail=120 backend frontend || true
      fail "Mission Control health check failed (expected HTTP 200 at ${mission_control_frontend_url}/)."
    fi

    openclaw_network_name="${COMPOSE_PROJECT_NAME}_openclaw-safe-net"
    mc_backend_container_id="$(mission_control_compose ps -q backend 2>/dev/null | tr -d '\r' | head -n 1)"
    if [[ -n "$mc_backend_container_id" ]]; then
      docker network connect "$openclaw_network_name" "$mc_backend_container_id" >/dev/null 2>&1 || true
    fi
    mc_worker_container_id="$(mission_control_compose ps -q webhook-worker 2>/dev/null | tr -d '\r' | head -n 1)"
    if [[ -n "$mc_worker_container_id" ]]; then
      docker network connect "$openclaw_network_name" "$mc_worker_container_id" >/dev/null 2>&1 || true
    fi

    if ! onboarding_repair_output="$(repair_mission_control_onboarding_sessions 2>&1)"; then
      printf "[openclaw-easy] Mission Control onboarding session migration failed (continuing).\n"
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        printf "[openclaw-easy] mission-control-onboarding: %s\n" "$line"
      done <<<"$onboarding_repair_output"
    else
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        printf "[openclaw-easy] mission-control-onboarding: %s\n" "$line"
      done <<<"$onboarding_repair_output"
    fi

    if is_truthy "${OPENCLAW_MISSION_CONTROL_AUTOCONFIG_GATEWAY}"; then
      log "Mission Control gateway auto-config"
      read -r -d '' mc_gateway_sync_script <<'PY' || true
import json
import os
import urllib.error
import urllib.parse
import urllib.request

base = "http://127.0.0.1:8000/api/v1"
token = (os.environ.get("MC_TOKEN") or "").strip()
gateway_token = (os.environ.get("MC_GATEWAY_TOKEN") or "").strip()
gateway_port = (os.environ.get("MC_GATEWAY_PORT") or "18789").strip()
gateway_name = (os.environ.get("MC_GATEWAY_NAME") or "OpenClaw Docker Gateway").strip()
workspace_root = (os.environ.get("MC_WORKSPACE_ROOT") or "/home/node/.openclaw").strip()
override_url = (os.environ.get("MC_GATEWAY_URL_OVERRIDE") or "").strip()
sync_templates = (os.environ.get("MC_SYNC_TEMPLATES") or "true").strip().lower() in {"1", "true", "yes", "on"}

if not token:
    raise RuntimeError("mission control auth token is empty")

headers = {
    "Authorization": f"Bearer {token}",
    "Content-Type": "application/json",
}

def request_json(method, path, *, query=None, payload=None):
    url = f"{base}{path}"
    if query:
        url = f"{url}?{urllib.parse.urlencode(query)}"
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode("utf-8")
            parsed = json.loads(raw) if raw else {}
            return resp.getcode(), parsed
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="ignore") if exc.fp else ""
        detail = raw.strip() or exc.reason
        raise RuntimeError(f"{method} {path} failed ({exc.code}): {detail}") from exc

request_json("POST", "/auth/bootstrap")

candidates = []
if override_url:
    candidates.append(override_url)
candidates.extend([
    "ws://openclaw-gateway:18789",
    f"ws://host.docker.internal:{gateway_port}",
    f"ws://gateway.docker.internal:{gateway_port}",
    f"ws://172.17.0.1:{gateway_port}",
])
deduped = []
seen = set()
for item in candidates:
    value = (item or "").strip()
    if not value or value in seen:
        continue
    deduped.append(value)
    seen.add(value)

selected_url = deduped[0]
for candidate in deduped:
    try:
        _, status_payload = request_json(
            "GET",
            "/gateways/status",
            query={
                "gateway_url": candidate,
                "gateway_token": gateway_token,
            },
        )
        if bool(status_payload.get("connected")):
            selected_url = candidate
            break
    except Exception:
        continue

_, gateways_payload = request_json("GET", "/gateways", query={"limit": "200", "offset": "0"})
items = gateways_payload.get("items") if isinstance(gateways_payload, dict) else []
if not isinstance(items, list):
    items = []
existing = None
for item in items:
    if not isinstance(item, dict):
        continue
    if item.get("name") == gateway_name or item.get("url") == selected_url:
        existing = item
        break

payload = {
    "name": gateway_name,
    "url": selected_url,
    "workspace_root": workspace_root,
    "token": gateway_token or None,
}

gateway_id = None
if existing and existing.get("id"):
    _, updated_payload = request_json("PATCH", f"/gateways/{existing['id']}", payload=payload)
    action = "updated"
    if isinstance(updated_payload, dict):
        gateway_id = updated_payload.get("id")
    if not gateway_id:
        gateway_id = existing.get("id")
else:
    _, created_payload = request_json("POST", "/gateways", payload=payload)
    action = "created"
    if isinstance(created_payload, dict):
        gateway_id = created_payload.get("id")

if sync_templates and gateway_id:
    query = {
        "include_main": "true",
        "reset_sessions": "true",
        "rotate_tokens": "true",
        "force_bootstrap": "true",
        "overwrite": "true",
    }
    _, sync_payload = request_json("POST", f"/gateways/{gateway_id}/templates/sync", query=query)
    if isinstance(sync_payload, dict):
        print(
            "MISSION_CONTROL_GATEWAY_SYNC="
            f"agents_updated={sync_payload.get('agents_updated', 0)} "
            f"agents_skipped={sync_payload.get('agents_skipped', 0)} "
            f"errors={len(sync_payload.get('errors') or [])}"
        )

print(f"MISSION_CONTROL_GATEWAY_ACTION={action}")
print(f"MISSION_CONTROL_GATEWAY_URL={selected_url}")
if gateway_id:
    print(f"MISSION_CONTROL_GATEWAY_ID={gateway_id}")
PY
      mc_gateway_sync_script_b64="$(printf "%s" "$mc_gateway_sync_script" | base64 | tr -d '\r\n')"
      mc_gateway_launcher="import base64;exec(base64.b64decode('${mc_gateway_sync_script_b64}').decode('utf-8'))"
      gateway_sync_output=""
      if ! gateway_sync_output="$(
        mission_control_compose exec -T \
          -e "MC_TOKEN=${OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN}" \
          -e "MC_GATEWAY_TOKEN=${OPENCLAW_GATEWAY_TOKEN}" \
          -e "MC_GATEWAY_PORT=${OPENCLAW_GATEWAY_PORT}" \
          -e "MC_GATEWAY_NAME=${OPENCLAW_MISSION_CONTROL_GATEWAY_NAME}" \
          -e "MC_WORKSPACE_ROOT=${OPENCLAW_MISSION_CONTROL_GATEWAY_WORKSPACE_ROOT}" \
          -e "MC_GATEWAY_URL_OVERRIDE=${OPENCLAW_MISSION_CONTROL_GATEWAY_URL}" \
          -e "MC_SYNC_TEMPLATES=${OPENCLAW_MISSION_CONTROL_SYNC_TEMPLATES}" \
          backend python -c "$mc_gateway_launcher" 2>&1
      )"; then
        printf "[openclaw-easy] Mission Control gateway auto-config failed (continuing).\n"
        while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          printf "[openclaw-easy] mission-control-gateway: %s\n" "$line"
        done <<<"$gateway_sync_output"
      else
        while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          if [[ "$line" == MISSION_CONTROL_GATEWAY_URL=* ]]; then
            mission_control_registered_gateway_url="${line#MISSION_CONTROL_GATEWAY_URL=}"
            if [[ -n "$mission_control_registered_gateway_url" ]]; then
              export OPENCLAW_MISSION_CONTROL_GATEWAY_URL="$mission_control_registered_gateway_url"
              upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_GATEWAY_URL" "$OPENCLAW_MISSION_CONTROL_GATEWAY_URL"
            fi
          elif [[ "$line" == MISSION_CONTROL_GATEWAY_ID=* ]]; then
            mission_control_registered_gateway_id="${line#MISSION_CONTROL_GATEWAY_ID=}"
            if [[ -n "$mission_control_registered_gateway_id" ]]; then
              export OPENCLAW_MISSION_CONTROL_GATEWAY_ID="$mission_control_registered_gateway_id"
              upsert_env "$ENV_FILE" "OPENCLAW_MISSION_CONTROL_GATEWAY_ID" "$OPENCLAW_MISSION_CONTROL_GATEWAY_ID"
            fi
          fi
          printf "[openclaw-easy] mission-control-gateway: %s\n" "$line"
        done <<<"$gateway_sync_output"
      fi
    fi
    if [[ -z "${mission_control_registered_gateway_id:-}" ]]; then
      mission_control_registered_gateway_id="${OPENCLAW_MISSION_CONTROL_GATEWAY_ID:-}"
    fi

    board_config_json="${OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_JSON:-}"
    if [[ -z "$board_config_json" && -n "${OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE:-}" ]]; then
      board_config_path="${OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE}"
      if [[ ! "$board_config_path" = /* && ! "$board_config_path" =~ ^[A-Za-z]:[\\/].* ]]; then
        board_config_path="$ROOT_DIR/$board_config_path"
      fi
      if [[ -f "$board_config_path" ]]; then
        board_config_json="$(cat "$board_config_path")"
      else
        printf "[openclaw-easy] Mission Control board config file not found: %s (continuing with env values).\n" "$board_config_path"
      fi
    fi
    board_config_b64=""
    if [[ -n "$board_config_json" ]]; then
      board_config_b64="$(printf "%s" "$board_config_json" | base64 | tr -d '\r\n')"
    fi

    if is_truthy "${OPENCLAW_MISSION_CONTROL_SEED_BOARD}"; then
      log "Mission Control board seed"
      read -r -d '' mc_board_seed_script <<'PY' || true
import base64
import json
import os
import re
import urllib.error
import urllib.parse
import urllib.request

base = "http://127.0.0.1:8000/api/v1"
token = (os.environ.get("MC_TOKEN") or "").strip()
gateway_id_hint = (os.environ.get("MC_GATEWAY_ID") or "").strip()
gateway_name_hint = (os.environ.get("MC_GATEWAY_NAME") or "").strip()
gateway_url_hint = (os.environ.get("MC_GATEWAY_URL") or "").strip()
config_b64 = (os.environ.get("MC_BOARD_CONFIG_B64") or "").strip()

if not token:
    raise RuntimeError("mission control auth token is empty")

headers = {
    "Authorization": f"Bearer {token}",
    "Content-Type": "application/json",
}

def request_json(method, path, *, query=None, payload=None):
    url = f"{base}{path}"
    if query:
        url = f"{url}?{urllib.parse.urlencode(query)}"
    data = None
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=20) as resp:
            raw = resp.read().decode("utf-8")
            parsed = json.loads(raw) if raw else {}
            return resp.getcode(), parsed
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="ignore") if exc.fp else ""
        detail = raw.strip() or exc.reason
        raise RuntimeError(f"{method} {path} failed ({exc.code}): {detail}") from exc

def parse_bool(raw, default=False):
    if raw is None:
        return default
    if isinstance(raw, bool):
        return raw
    text = str(raw).strip().lower()
    if text == "":
        return default
    return text in {"1", "true", "yes", "on"}

def parse_int(raw, default):
    if raw is None:
        return default
    if isinstance(raw, int):
        return raw
    text = str(raw).strip()
    if text == "":
        return default
    try:
        return int(text)
    except ValueError:
        return default

def slugify(value):
    normalized = re.sub(r"[^a-z0-9]+", "-", (value or "").strip().lower()).strip("-")
    return normalized or "main-board"

config = {}
if config_b64:
    try:
        decoded = base64.b64decode(config_b64).decode("utf-8")
        parsed = json.loads(decoded)
    except Exception as exc:
        raise RuntimeError(f"invalid board config JSON: {exc}") from exc
    if not isinstance(parsed, dict):
        raise RuntimeError("board config JSON must be an object")
    config = parsed

def cfg(key, env_key, default=None):
    if key in config and config[key] is not None:
        return config[key]
    value = os.environ.get(env_key)
    if value is not None and value.strip() != "":
        return value.strip()
    return default

request_json("POST", "/auth/bootstrap")
_, gateways_payload = request_json("GET", "/gateways", query={"limit": "200", "offset": "0"})
gateways = gateways_payload.get("items") if isinstance(gateways_payload, dict) else []
if not isinstance(gateways, list):
    gateways = []

gateway_id = cfg("gateway_id", "MC_GATEWAY_ID", gateway_id_hint)
if gateway_id:
    gateway_id = str(gateway_id).strip()
if not gateway_id:
    selected_gateway = None
    for item in gateways:
        if not isinstance(item, dict):
            continue
        if gateway_url_hint and item.get("url") == gateway_url_hint:
            selected_gateway = item
            break
        if gateway_name_hint and item.get("name") == gateway_name_hint:
            selected_gateway = item
            break
    if selected_gateway is None and gateways:
        selected_gateway = gateways[0]
    if selected_gateway is not None:
        gateway_id = str(selected_gateway.get("id") or "").strip()

if not gateway_id:
    raise RuntimeError("cannot seed board: no gateway found in Mission Control")

name = str(cfg("name", "MC_BOARD_NAME", "Main Board")).strip()
if not name:
    name = "Main Board"
slug_raw = str(cfg("slug", "MC_BOARD_SLUG", "")).strip()
slug = slug_raw or slugify(name)
description = str(cfg("description", "MC_BOARD_DESCRIPTION", "Primary board for OpenClaw automation.")).strip()
perspective = str(cfg("perspective", "MC_BOARD_PERSPECTIVE", "")).strip()
if perspective:
    perspective_block = f"Perspective:\n{perspective}"
    if perspective_block not in description:
        description = f"{description}\n\n{perspective_block}".strip()

board_type = str(cfg("board_type", "MC_BOARD_TYPE", "goal")).strip() or "goal"
goal_confirmed = parse_bool(cfg("goal_confirmed", "MC_BOARD_GOAL_CONFIRMED", False), False)
objective = cfg("objective", "MC_BOARD_OBJECTIVE", None)
if isinstance(objective, str):
    objective = objective.strip() or None
target_date = cfg("target_date", "MC_BOARD_TARGET_DATE", None)
if isinstance(target_date, str):
    target_date = target_date.strip() or None
board_group_id = cfg("board_group_id", "MC_BOARD_GROUP_ID", None)
if isinstance(board_group_id, str):
    board_group_id = board_group_id.strip() or None
max_agents = parse_int(cfg("max_agents", "MC_BOARD_MAX_AGENTS", 1), 1)
goal_source = cfg("goal_source", "MC_BOARD_GOAL_SOURCE", None)
if isinstance(goal_source, str):
    goal_source = goal_source.strip() or None

success_metrics = cfg("success_metrics", "MC_BOARD_SUCCESS_METRICS_JSON", None)
if isinstance(success_metrics, str):
    success_metrics_text = success_metrics.strip()
    if success_metrics_text:
        try:
            success_metrics = json.loads(success_metrics_text)
        except Exception as exc:
            raise RuntimeError(f"invalid success_metrics JSON: {exc}") from exc
    else:
        success_metrics = None
if success_metrics is not None and not isinstance(success_metrics, dict):
    raise RuntimeError("success_metrics must be a JSON object")

payload = {
    "name": name,
    "slug": slug,
    "description": description,
    "gateway_id": gateway_id,
    "board_type": board_type,
    "goal_confirmed": goal_confirmed,
    "max_agents": max_agents,
}
if objective:
    payload["objective"] = objective
if success_metrics is not None:
    payload["success_metrics"] = success_metrics
if target_date:
    payload["target_date"] = target_date
if board_group_id:
    payload["board_group_id"] = board_group_id
if goal_source:
    payload["goal_source"] = goal_source

_, boards_payload = request_json("GET", "/boards", query={"limit": "200", "offset": "0"})
boards = boards_payload.get("items") if isinstance(boards_payload, dict) else []
if not isinstance(boards, list):
    boards = []
existing = None
for item in boards:
    if not isinstance(item, dict):
        continue
    if item.get("slug") == slug or item.get("name") == name:
        existing = item
        break

if existing and existing.get("id"):
    _, board_payload = request_json("PATCH", f"/boards/{existing['id']}", payload=payload)
    action = "updated"
else:
    _, board_payload = request_json("POST", "/boards", payload=payload)
    action = "created"

board_id = ""
board_name = name
board_slug = slug
if isinstance(board_payload, dict):
    board_id = str(board_payload.get("id") or "").strip()
    board_name = str(board_payload.get("name") or board_name).strip()
    board_slug = str(board_payload.get("slug") or board_slug).strip()

print(f"MISSION_CONTROL_BOARD_ACTION={action}")
print(f"MISSION_CONTROL_BOARD_ID={board_id}")
print(f"MISSION_CONTROL_BOARD_NAME={board_name}")
print(f"MISSION_CONTROL_BOARD_SLUG={board_slug}")
PY
      mc_board_seed_b64="$(printf "%s" "$mc_board_seed_script" | base64 | tr -d '\r\n')"
      mc_board_seed_launcher="import base64;exec(base64.b64decode('${mc_board_seed_b64}').decode('utf-8'))"
      board_seed_output=""
      if ! board_seed_output="$(
        mission_control_compose exec -T \
          -e "MC_TOKEN=${OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN}" \
          -e "MC_GATEWAY_ID=${mission_control_registered_gateway_id}" \
          -e "MC_GATEWAY_NAME=${OPENCLAW_MISSION_CONTROL_GATEWAY_NAME}" \
          -e "MC_GATEWAY_URL=${OPENCLAW_MISSION_CONTROL_GATEWAY_URL}" \
          -e "MC_BOARD_NAME=${OPENCLAW_MISSION_CONTROL_BOARD_NAME}" \
          -e "MC_BOARD_SLUG=${OPENCLAW_MISSION_CONTROL_BOARD_SLUG}" \
          -e "MC_BOARD_DESCRIPTION=${OPENCLAW_MISSION_CONTROL_BOARD_DESCRIPTION}" \
          -e "MC_BOARD_PERSPECTIVE=${OPENCLAW_MISSION_CONTROL_BOARD_PERSPECTIVE}" \
          -e "MC_BOARD_TYPE=${OPENCLAW_MISSION_CONTROL_BOARD_TYPE}" \
          -e "MC_BOARD_OBJECTIVE=${OPENCLAW_MISSION_CONTROL_BOARD_OBJECTIVE}" \
          -e "MC_BOARD_SUCCESS_METRICS_JSON=${OPENCLAW_MISSION_CONTROL_BOARD_SUCCESS_METRICS_JSON}" \
          -e "MC_BOARD_TARGET_DATE=${OPENCLAW_MISSION_CONTROL_BOARD_TARGET_DATE}" \
          -e "MC_BOARD_GOAL_CONFIRMED=${OPENCLAW_MISSION_CONTROL_BOARD_GOAL_CONFIRMED}" \
          -e "MC_BOARD_GOAL_SOURCE=${OPENCLAW_MISSION_CONTROL_BOARD_GOAL_SOURCE}" \
          -e "MC_BOARD_GROUP_ID=${OPENCLAW_MISSION_CONTROL_BOARD_GROUP_ID}" \
          -e "MC_BOARD_MAX_AGENTS=${OPENCLAW_MISSION_CONTROL_BOARD_MAX_AGENTS}" \
          -e "MC_BOARD_CONFIG_B64=${board_config_b64}" \
          backend python -c "$mc_board_seed_launcher" 2>&1
      )"; then
        printf "[openclaw-easy] Mission Control board seed failed (continuing).\n"
        while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          printf "[openclaw-easy] mission-control-board: %s\n" "$line"
        done <<<"$board_seed_output"
      else
        board_action=""
        board_id=""
        board_name=""
        board_slug=""
        while IFS= read -r line; do
          [[ -z "$line" ]] && continue
          if [[ "$line" == MISSION_CONTROL_BOARD_ACTION=* ]]; then
            board_action="${line#MISSION_CONTROL_BOARD_ACTION=}"
          elif [[ "$line" == MISSION_CONTROL_BOARD_ID=* ]]; then
            board_id="${line#MISSION_CONTROL_BOARD_ID=}"
          elif [[ "$line" == MISSION_CONTROL_BOARD_NAME=* ]]; then
            board_name="${line#MISSION_CONTROL_BOARD_NAME=}"
          elif [[ "$line" == MISSION_CONTROL_BOARD_SLUG=* ]]; then
            board_slug="${line#MISSION_CONTROL_BOARD_SLUG=}"
          fi
          printf "[openclaw-easy] mission-control-board: %s\n" "$line"
        done <<<"$board_seed_output"
        if [[ -n "$board_action" || -n "$board_name" ]]; then
          mission_control_seed_board_summary="action=$board_action name=$board_name slug=$board_slug id=$board_id"
        fi
      fi
    fi
    mission_control_dashboard_url="${mission_control_frontend_url}/"
  fi

  if is_truthy "${OPENCLAW_ENABLE_COMMAND_CENTER}"; then
    clone_or_update_command_center
    if [[ ! -f "$ROOT_DIR/command-center.compose.yml" ]]; then
      fail "Command Center compose file is missing: $ROOT_DIR/command-center.compose.yml"
    fi

    log "Starting OpenClaw Command Center"
    command_center_compose up -d --build

    log "OpenClaw Command Center health check"
    command_center_url="http://127.0.0.1:${OPENCLAW_COMMAND_CENTER_PORT}/"
    command_center_ready=false
    for attempt in $(seq 1 90); do
      if command_center_http_200 "$command_center_url"; then
        command_center_ready=true
        break
      fi
      if [[ "$attempt" -eq 1 || $((attempt % 10)) -eq 0 ]]; then
        printf "[openclaw-easy] waiting for OpenClaw Command Center %s (attempt %s/90)\n" "$command_center_url" "$attempt"
        command_center_compose ps || true
      fi
      sleep 2
    done
    if [[ "$command_center_ready" != "true" ]]; then
      printf "[openclaw-easy] Command Center logs (last 120 lines):\n"
      command_center_compose logs --tail=120 openclaw-command-center || true
      fail "OpenClaw Command Center health check failed (expected HTTP 200 at ${command_center_url})."
    fi
    command_center_dashboard_url="$command_center_url"
  fi

  local dashboard
  local dashboard_url
  dashboard_url="$(default_dashboard_url)"
  dashboard="$(compose run --rm openclaw-cli dashboard --no-open || true)"
  parsed_dashboard_url="$(printf "%s\n" "$dashboard" | sed -E 's/\x1B\[[0-9;]*[A-Za-z]//g' | sed -n "s/.*Dashboard URL:[[:space:]]*//p" | tail -n 1)"
  if [[ -n "$parsed_dashboard_url" ]]; then
    dashboard_url="$parsed_dashboard_url"
  fi
  dashboard_url="$(ensure_dashboard_url_token "$dashboard_url")"

  log "Setup complete"
  if [[ -n "$dashboard_url" ]]; then
    printf "[openclaw-easy] Open this URL:\n%s\n" "$dashboard_url"
    printf "[openclaw-easy] If you see device token mismatch, run ./repair-auth.sh then reload browser.\n"
  else
    printf "[openclaw-easy] Run this to print your URL:\n(cd \"%s\" && %s -p \"%s\" --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli dashboard --no-open)\n" "$OPENCLAW_SRC_DIR" "$COMPOSE_HINT" "$COMPOSE_PROJECT_NAME"
  fi
  if is_truthy "${OPENCLAW_ENABLE_MISSION_CONTROL}" && [[ -n "${mission_control_dashboard_url}" ]]; then
    printf "[openclaw-easy] Mission Control URL:\n%s\n" "${mission_control_dashboard_url}"
    printf "[openclaw-easy] Mission Control local auth token (for first login):\n%s\n" "$OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN"
    if [[ -n "$mission_control_registered_gateway_url" ]]; then
      printf "[openclaw-easy] Mission Control gateway (auto-registered):\n%s\n" "$mission_control_registered_gateway_url"
    fi
    if [[ -n "$mission_control_seed_board_summary" ]]; then
      printf "[openclaw-easy] Mission Control board seed:\n%s\n" "$mission_control_seed_board_summary"
    fi
  fi
  if is_truthy "${OPENCLAW_ENABLE_COMMAND_CENTER}" && [[ -n "${command_center_dashboard_url}" ]]; then
    printf "[openclaw-easy] OpenClaw Command Center URL:\n%s\n" "$command_center_dashboard_url"
  fi
}

if [[ "${OPENCLAW_EASY_TEST_MODE:-0}" == "1" ]]; then
  return 0 2>/dev/null || exit 0
fi

main "$@"


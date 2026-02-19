#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"

log() {
  printf "\n[openclaw-easy][doctor] %s\n" "$*"
}

fail() {
  printf "\n[openclaw-easy][doctor] ERROR: %s\n" "$*" >&2
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

log "Running start"
"$ROOT_DIR/start.sh" "$@"

log "Running verify"
"$ROOT_DIR/verify.sh"

while IFS= read -r line || [[ -n "$line" ]]; do
  line="${line%$'\r'}"
  line="${line#$'\ufeff'}"
  [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
  if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
    export "${line%%=*}=${line#*=}"
  fi
done <"$ENV_FILE"

OPENCLAW_SRC_DIR="${OPENCLAW_SRC_DIR:-$ROOT_DIR/vendor/openclaw}"
[[ -d "$OPENCLAW_SRC_DIR" ]] || fail "OpenClaw source not found at $OPENCLAW_SRC_DIR."

if [[ ! -f "$OPENCLAW_SRC_DIR/.env" ]]; then
  cp "$ENV_FILE" "$OPENCLAW_SRC_DIR/.env"
fi

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-openclaw-easy}"
resolve_compose

compose() {
  (
    cd "$OPENCLAW_SRC_DIR"
    "${COMPOSE_CMD[@]}" -p "$COMPOSE_PROJECT_NAME" --env-file "$OPENCLAW_SRC_DIR/.env" -f docker-compose.safe.yml "$@"
  )
}

log "Browser status probe"
status_out="$(compose exec -T openclaw-gateway node dist/index.js browser status --json 2>&1 || true)"
if [[ -z "$status_out" ]]; then
  fail "Browser status probe returned no output."
fi

if ! printf "%s\n" "$status_out" | tr -d '\r' | grep -Eq '"enabled"[[:space:]]*:[[:space:]]*true'; then
  printf "%s\n" "$status_out"
  fail "Browser status probe failed."
fi
if ! printf "%s\n" "$status_out" | tr -d '\r' | grep -Eq '"(cdpHttp|running)"[[:space:]]*:[[:space:]]*true|"detectedBrowser"[[:space:]]*:[[:space:]]*"[^"]+"'; then
  printf "%s\n" "$status_out"
  fail "Browser status probe did not report a usable browser target."
fi
printf "%s\n" "$status_out" | tr -d '\r' | sed -n 's/.*"profile"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/profile=\1/p' | tail -n 1

log "PASS"


#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$ROOT_DIR/.env"
SAFE_COMPOSE_TEMPLATE="$ROOT_DIR/docker-compose.safe.yml"
FULL_RESET=false
COMPOSE_CMD=()

if [[ "${1:-}" == "--full" ]]; then
  FULL_RESET=true
fi

log() {
  printf "\n[openclaw-easy] %s\n" "$*"
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
      local ps_file="$ROOT_DIR/reset.ps1"
      local ps_args=()
      if command -v cygpath >/dev/null 2>&1; then
        ps_file="$(cygpath -w "$ps_file")"
      fi
      for arg in "$@"; do
        if [[ "$arg" == "--full" ]]; then
          ps_args+=("-Full")
        else
          ps_args+=("$arg")
        fi
      done
      if command -v pwsh >/dev/null 2>&1; then
        exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$ps_file" "${ps_args[@]}"
      elif command -v powershell.exe >/dev/null 2>&1; then
        exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps_file" "${ps_args[@]}"
      fi
      ;;
  esac
  if [[ "$is_wsl" == "true" ]]; then
    local ps_file="$ROOT_DIR/reset.ps1"
    local ps_args=()
    for arg in "$@"; do
      if [[ "$arg" == "--full" ]]; then
        ps_args+=("-Full")
      else
        ps_args+=("$arg")
      fi
    done
    if command -v cygpath >/dev/null 2>&1; then
      ps_file="$(cygpath -w "$ps_file")"
    else
      ps_file="$(wslpath -w "$ps_file" 2>/dev/null || printf "%s" "$ps_file")"
    fi
    if command -v powershell.exe >/dev/null 2>&1; then
      exec powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$ps_file" "${ps_args[@]}"
    elif command -v pwsh >/dev/null 2>&1; then
      exec pwsh -NoProfile -ExecutionPolicy Bypass -File "$ps_file" "${ps_args[@]}"
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
  log "Docker Compose not found. Skipping compose cleanup."
}

maybe_delegate_to_powershell "$@"

if [[ -f "$ENV_FILE" ]]; then
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    line="${line#$'\ufeff'}"
    [[ -z "$line" || "${line:0:1}" == "#" ]] && continue
    if [[ "$line" =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then
      export "${line%%=*}=${line#*=}"
    fi
  done <"$ENV_FILE"
fi
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-openclaw-easy}"
export OPENCLAW_SAFE_PROJECT_NAME="${OPENCLAW_SAFE_PROJECT_NAME:-$COMPOSE_PROJECT_NAME}"
OPENCLAW_SRC_DIR="${OPENCLAW_SRC_DIR:-$ROOT_DIR/vendor/openclaw}"
OPENCLAW_MISSION_CONTROL_SRC_DIR="${OPENCLAW_MISSION_CONTROL_SRC_DIR:-$ROOT_DIR/vendor/openclaw-mission-control}"
OPENCLAW_COMMAND_CENTER_SRC_DIR="${OPENCLAW_COMMAND_CENTER_SRC_DIR:-$ROOT_DIR/vendor/openclaw-command-center}"

resolve_compose

if [[ -d "$OPENCLAW_SRC_DIR" ]]; then
  if [[ ! -f "$OPENCLAW_SRC_DIR/docker-compose.safe.yml" && -f "$SAFE_COMPOSE_TEMPLATE" ]]; then
    cp "$SAFE_COMPOSE_TEMPLATE" "$OPENCLAW_SRC_DIR/docker-compose.safe.yml"
    log "Provisioned docker-compose.safe.yml in cloned OpenClaw repo"
  fi
  log "Stopping and removing OpenClaw safe Docker stack"
  (
    cd "$OPENCLAW_SRC_DIR"
    if [[ ${#COMPOSE_CMD[@]} -gt 0 ]]; then
      "${COMPOSE_CMD[@]}" -p "${COMPOSE_PROJECT_NAME}" --env-file "$OPENCLAW_SRC_DIR/.env" -f docker-compose.safe.yml down -v --remove-orphans || true
    fi
  )
else
  log "OpenClaw source not found, skipping docker compose reset"
fi

if [[ -d "$OPENCLAW_MISSION_CONTROL_SRC_DIR" && -f "$OPENCLAW_MISSION_CONTROL_SRC_DIR/compose.yml" ]]; then
  log "Stopping and removing Mission Control Docker stack"
  (
    cd "$OPENCLAW_MISSION_CONTROL_SRC_DIR"
    if [[ ${#COMPOSE_CMD[@]} -gt 0 ]]; then
      "${COMPOSE_CMD[@]}" -p "${COMPOSE_PROJECT_NAME}-mission-control" --env-file "$OPENCLAW_MISSION_CONTROL_SRC_DIR/.env" -f compose.yml down -v --remove-orphans || true
    fi
  )
fi

if [[ -f "$ROOT_DIR/command-center.compose.yml" ]]; then
  log "Stopping and removing Command Center Docker stack"
  (
    cd "$ROOT_DIR"
    if [[ ${#COMPOSE_CMD[@]} -gt 0 ]]; then
      "${COMPOSE_CMD[@]}" -p "${COMPOSE_PROJECT_NAME}-command-center" --env-file "$ENV_FILE" -f command-center.compose.yml down -v --remove-orphans || true
    fi
  )
fi

if [[ "$FULL_RESET" == true ]]; then
  log "Removing cloned OpenClaw source"
  rm -rf "$OPENCLAW_SRC_DIR"
  log "Removing cloned Mission Control source"
  rm -rf "$OPENCLAW_MISSION_CONTROL_SRC_DIR"
  log "Removing cloned Command Center source"
  rm -rf "$OPENCLAW_COMMAND_CENTER_SRC_DIR"
fi

log "Reset complete"

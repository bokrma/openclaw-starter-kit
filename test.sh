#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ -f "$ROOT_DIR/tests/start.unit.sh" ]]; then
  echo "[openclaw-easy] Running Bash unit tests"
  bash "$ROOT_DIR/tests/start.unit.sh"
fi

if command -v pwsh >/dev/null 2>&1 && [[ -f "$ROOT_DIR/tests/start.unit.ps1" ]]; then
  echo "[openclaw-easy] Running PowerShell unit tests"
  pwsh -NoProfile -ExecutionPolicy Bypass -File "$ROOT_DIR/tests/start.unit.ps1"
fi

echo "[openclaw-easy] Unit tests passed"

# Mission Control and Command Center

## Mission Control Defaults

Mission Control is enabled by default:

- `OPENCLAW_ENABLE_MISSION_CONTROL=true`

Main settings:

- `OPENCLAW_MISSION_CONTROL_FRONTEND_PORT` (default `3310`)
- `OPENCLAW_MISSION_CONTROL_BACKEND_PORT` (default `8310`)
- `OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN` (auto-generated if empty)
- `OPENCLAW_MISSION_CONTROL_AUTOCONFIG_GATEWAY` (default `true`)
- `OPENCLAW_MISSION_CONTROL_SYNC_TEMPLATES` (default `true`)
- `OPENCLAW_MISSION_CONTROL_GATEWAY_NAME` (default `OpenClaw Docker Gateway`)
- `OPENCLAW_MISSION_CONTROL_GATEWAY_WORKSPACE_ROOT` (default `/home/node/.openclaw`)
- `OPENCLAW_MISSION_CONTROL_GATEWAY_ID` (auto-filled after gateway auto-config)
- `OPENCLAW_MISSION_CONTROL_BASE_URL` (optional override for callback API base URL)

Behavior:

- If a configured Mission Control port is already in use, startup picks the next free host port and writes it into `.env`.
- If `OPENCLAW_MISSION_CONTROL_BASE_URL` is empty, startup sets a Docker-reachable backend URL automatically.
- Gateway auto-config fills Mission Control gateway values (`name`, `url`, `workspace_root`, `token`) from runtime.
- Template sync can rotate tokens/reset sessions to avoid stale `X-Agent-Token` onboarding issues.

## Command Center Defaults

Command Center is disabled by default:

- `OPENCLAW_ENABLE_COMMAND_CENTER=false`

Settings:

- `OPENCLAW_COMMAND_CENTER_PORT` (default `3340`)
- `OPENCLAW_COMMAND_CENTER_AUTH_MODE` (`none`, `token`, `tailscale`, `cloudflare`, `allowlist`)
- `OPENCLAW_COMMAND_CENTER_TOKEN` (used when `AUTH_MODE=token`)
- `OPENCLAW_COMMAND_CENTER_ALLOWED_USERS`
- `OPENCLAW_COMMAND_CENTER_ALLOWED_IPS`

Behavior:

- If the selected port is in use, startup chooses the next free port and writes it into `.env`.

## Mission Control Board Seeding (single board)

Enabled by default:

- `OPENCLAW_MISSION_CONTROL_SEED_BOARD=true`

Environment-based fields:

- `OPENCLAW_MISSION_CONTROL_BOARD_NAME`
- `OPENCLAW_MISSION_CONTROL_BOARD_SLUG`
- `OPENCLAW_MISSION_CONTROL_BOARD_DESCRIPTION`
- `OPENCLAW_MISSION_CONTROL_BOARD_PERSPECTIVE`
- `OPENCLAW_MISSION_CONTROL_BOARD_TYPE`
- `OPENCLAW_MISSION_CONTROL_BOARD_OBJECTIVE`
- `OPENCLAW_MISSION_CONTROL_BOARD_SUCCESS_METRICS_JSON`
- `OPENCLAW_MISSION_CONTROL_BOARD_TARGET_DATE`
- `OPENCLAW_MISSION_CONTROL_BOARD_GOAL_CONFIRMED`
- `OPENCLAW_MISSION_CONTROL_BOARD_GOAL_SOURCE`
- `OPENCLAW_MISSION_CONTROL_BOARD_GROUP_ID`
- `OPENCLAW_MISSION_CONTROL_BOARD_MAX_AGENTS`

JSON override options:

- `OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_JSON`
- `OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE` (relative paths supported)

Starter template file:

- `board.seed.example.json`

Copy template:

```powershell
Copy-Item .\board.seed.example.json .\board.seed.json -Force
```

```bash
cp board.seed.example.json board.seed.json
```

Enable file-based seed:

```text
OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE=board.seed.json
```

## Mission Control Board Pack Seeding (multi-board)

Enable:

```text
OPENCLAW_MISSION_CONTROL_SEED_BOARD_PACK=true
```

Options:

- `OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_JSON`
- `OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_FILE` (relative paths supported)

Starter template:

- `board.pack.example.json`

Copy template:

```powershell
Copy-Item .\board.pack.example.json .\board.pack.json -Force
```

```bash
cp board.pack.example.json board.pack.json
```

Enable file-based pack seed:

```text
OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_FILE=board.pack.json
```

# OpenClaw Easy Starter

This starter is for non-developer setup:
- clones OpenClaw automatically
- runs Docker safe mode
- sets gateway token auth
- enables default channel plugins (`telegram,whatsapp`) so channel config schema loads in UI
- installs Supermemory plugin
- installs tools (`clawhub`, `claude`, `codex`)
- installs tools (`clawhub`, `openclaw`, `claude`, `codex`, `playwright`, `agent-browser`)
- installs and starts OpenClaw Mission Control by default
- optionally installs and starts OpenClaw Command Center (`OPENCLAW_ENABLE_COMMAND_CENTER=true`)
- enables Python `pip` in the container (`python3` + `python3-pip`)
- enables container-only elevated shell mode (`commands.bash` + `tools.elevated`) with `sudo`/`apt` inside Docker
- supports exec-approval mode toggle with `.env` (`OPENCLAW_ALWAYS_ALLOW_EXEC=true|false`)
- installs your requested skills
- syncs your requested community skills from `https://github.com/openclaw/skills`
- installs Playwright Chromium dependencies/cache for browser CLI flows
- enforces Docker-safe browser defaults (`browser.enabled=true`, `browser.headless=true`, `browser.noSandbox=true`)
- warms browser control service during setup (fails fast if browser service cannot start)
- applies multi-agent defaults (including swarm concurrency)

## 1) Prerequisites

- Docker Desktop (running)
- Git
- Internet access

Linux quick Docker install (if Docker is missing):
```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin
sudo systemctl enable --now docker
```

## 2) Fill `.env`

From this folder:

### Windows (PowerShell)
```powershell
Copy-Item .env.example .env
```

### macOS/Linux (bash)
```bash
cp .env.example .env
```

Edit `.env` and set:
- `OPENAI_API_KEY` (required)
- `SUPERMEMORY_API_KEY` (optional; you can skip it)

`SUPERMEMORY_OPENCLAW_API_KEY` is auto-filled from `SUPERMEMORY_API_KEY` if left empty.
Default source ref is `main` so the starter picks up latest fixes automatically; set `OPENCLAW_REPO_BRANCH` in `.env` if you need a pinned release tag.
If the starter is inside an OpenClaw checkout, it auto-uses that local source (`OPENCLAW_USE_LOCAL_SOURCE=auto`) so your local fixes are included in the Docker image.
If `OPENCLAW_USE_LOCAL_SOURCE=true` points to a non-OpenClaw folder, the starter auto-falls back to `vendor/openclaw` and continues.
You can customize default enabled channel plugins with `OPENCLAW_DEFAULT_CHANNEL_PLUGINS` (comma-separated).
Mission Control defaults are enabled (`OPENCLAW_ENABLE_MISSION_CONTROL=true`) and use:
- `OPENCLAW_MISSION_CONTROL_FRONTEND_PORT` (default `3310`)
- `OPENCLAW_MISSION_CONTROL_BACKEND_PORT` (default `8310`)
- `OPENCLAW_MISSION_CONTROL_LOCAL_AUTH_TOKEN` (auto-generated if empty)
- `OPENCLAW_MISSION_CONTROL_AUTOCONFIG_GATEWAY` (default `true`)
- `OPENCLAW_MISSION_CONTROL_SYNC_TEMPLATES` (default `true`, auto-repairs Mission Control agent token/template drift)
- `OPENCLAW_MISSION_CONTROL_GATEWAY_NAME` (default `OpenClaw Docker Gateway`)
- `OPENCLAW_MISSION_CONTROL_GATEWAY_WORKSPACE_ROOT` (default `/home/node/.openclaw`)
- `OPENCLAW_MISSION_CONTROL_GATEWAY_ID` (auto-filled after gateway auto-config)
- `OPENCLAW_MISSION_CONTROL_BASE_URL` (optional override for agent-callback API base URL used in onboarding prompts)
If any Mission Control port is already used on your host, startup auto-picks the next free port and writes it back to `.env`.
If `OPENCLAW_MISSION_CONTROL_BASE_URL` is empty, startup auto-sets a Docker-reachable backend URL (`http://<project>-mission-control-backend-1:8000`) so board onboarding can complete from the OpenClaw gateway container.
Command Center defaults are disabled (`OPENCLAW_ENABLE_COMMAND_CENTER=false`) and use:
- `OPENCLAW_COMMAND_CENTER_PORT` (default `3340`)
- `OPENCLAW_COMMAND_CENTER_AUTH_MODE` (`none`, `token`, `tailscale`, `cloudflare`, `allowlist`)
- `OPENCLAW_COMMAND_CENTER_TOKEN` (used when `AUTH_MODE=token`)
- `OPENCLAW_COMMAND_CENTER_ALLOWED_USERS` / `OPENCLAW_COMMAND_CENTER_ALLOWED_IPS`
If the Command Center port is already used, startup auto-picks the next free port and writes it back to `.env`.
If gateway auto-config is enabled, startup also auto-fills Mission Control gateway settings from your OpenClaw runtime:
- `name`
- `url` (best reachable `ws://...:18789` candidate)
- `workspace_root`
- `token` (`OPENCLAW_GATEWAY_TOKEN`)
When template sync is enabled, startup also runs Mission Control gateway template sync (`rotate_tokens=true`, `reset_sessions=true`) so onboarding callbacks do not get stuck with stale `X-Agent-Token`.

Mission Control board seeding (enabled by default) creates or updates one board at startup:
- `OPENCLAW_MISSION_CONTROL_SEED_BOARD=true`
- Env-based fields:
`OPENCLAW_MISSION_CONTROL_BOARD_NAME`, `OPENCLAW_MISSION_CONTROL_BOARD_SLUG`,
`OPENCLAW_MISSION_CONTROL_BOARD_DESCRIPTION`, `OPENCLAW_MISSION_CONTROL_BOARD_PERSPECTIVE`,
`OPENCLAW_MISSION_CONTROL_BOARD_TYPE`, `OPENCLAW_MISSION_CONTROL_BOARD_OBJECTIVE`,
`OPENCLAW_MISSION_CONTROL_BOARD_SUCCESS_METRICS_JSON`, `OPENCLAW_MISSION_CONTROL_BOARD_TARGET_DATE`,
`OPENCLAW_MISSION_CONTROL_BOARD_GOAL_CONFIRMED`, `OPENCLAW_MISSION_CONTROL_BOARD_GOAL_SOURCE`,
`OPENCLAW_MISSION_CONTROL_BOARD_GROUP_ID`, `OPENCLAW_MISSION_CONTROL_BOARD_MAX_AGENTS`.
- JSON override options (read before install/start):
`OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_JSON` or `OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE`.
`OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE` can be relative to the starter folder.

Template file already included: `board.seed.example.json`.

Copy and edit it before install/start:

Windows (PowerShell):
```powershell
Copy-Item .\board.seed.example.json .\board.seed.json -Force
```

macOS/Linux:
```bash
cp board.seed.example.json board.seed.json
```

Then edit `board.seed.json` and set:
- `name`, `slug`
- `description`
- `perspective` (the board operating perspective)
- optional goal fields (`objective`, `success_metrics`, `target_date`, etc.)

Example `board.seed.json`:
```json
{
  "name": "Growth Board",
  "slug": "growth-board",
  "description": "Drive weekly growth experiments and execution.",
  "perspective": "Think in experiments, prioritize measurable impact, keep updates concise.",
  "board_type": "goal",
  "goal_confirmed": true,
  "objective": "Increase qualified inbound leads by 20% in Q2.",
  "success_metrics": {
    "qualified_leads_per_week": ">= 120",
    "landing_page_conversion": ">= 4.5%"
  },
  "target_date": "2026-06-30T00:00:00Z",
  "max_agents": 5
}
```

Then set:
`OPENCLAW_MISSION_CONTROL_BOARD_CONFIG_FILE=board.seed.json`

`perspective` is appended into board description as:
`Perspective: ...`
so the board context is visible immediately in Mission Control.
If you want to force using your local OpenClaw checkout (recommended while testing local fixes), set:
- `OPENCLAW_USE_LOCAL_SOURCE=true`
- `OPENCLAW_SRC_DIR=<absolute path to your openclaw repo>`

## 3) Start everything

### Windows (PowerShell)
```powershell
.\start.ps1
```

### Windows (Command Prompt)
```cmd
start.cmd
```

If PowerShell blocks scripts, use:
```powershell
.\start.cmd
```

### macOS/Linux (bash)
```bash
chmod +x start.sh verify.sh reset.sh
./start.sh
```

`start.sh` auto-detects Windows Git Bash/MSYS and delegates to PowerShell automatically.
If a key is missing, the script prompts you. Supermemory can be skipped by pressing Enter (or typing `skip`).

When setup finishes, open the printed dashboard URL (tokenized URL).
The script also prints a Mission Control URL and local auth token.
It also prints the auto-registered Mission Control gateway URL when gateway auto-config is enabled.
If enabled, it also prints the OpenClaw Command Center URL.
If you want to build it manually:
- base URL: `http://127.0.0.1:18789/`
- tokenized URL: `http://127.0.0.1:18789/#token=<OPENCLAW_GATEWAY_TOKEN from .env>`
The starter forces a single Docker project name (`openclaw-easy`) to avoid split volumes/state.
`OPENCLAW_SAFE_PROJECT_NAME` should stay aligned with `COMPOSE_PROJECT_NAME` so Command Center can attach to the same safe Docker network/volume.

## 4) Verify setup

### Windows
```powershell
.\verify.ps1
```

### Windows (Command Prompt)
```cmd
verify.cmd
```

### macOS/Linux
```bash
./verify.sh
```

`verify` now runs unit tests first, then runtime checks.
If Mission Control is enabled, `verify` also checks that `http://127.0.0.1:<mission-control-port>/` returns HTTP 200.
If Command Center is enabled, `verify` also checks that `http://127.0.0.1:<command-center-port>/` returns HTTP 200.

## 4.2) One-command doctor

Runs full setup + verification + browser status probe.

### Windows
```powershell
.\doctor.cmd
```

### macOS/Linux
```bash
chmod +x doctor.sh
./doctor.sh
```

## 4.1) Unit tests only

### Windows
```powershell
.\test.cmd
```

### macOS/Linux
```bash
./test.sh
```

## 5) Daily use (no rebuild)

> [!IMPORTANT]
> After the first successful install, do **not** run `start.ps1` / `start.cmd` / `start.sh` for normal restarts.
> Those scripts rebuild/update and can take a long time.  
> If you did **not** change code, use the fast start command below (no `--build`).

From the `openclaw-easy-starter` folder:

### Windows (PowerShell)
```powershell
cd .\vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml up -d openclaw-gateway
```

### Windows (Command Prompt)
```cmd
cd /d vendor\openclaw && docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml up -d openclaw-gateway
```

### macOS/Linux (bash)
```bash
cd ./vendor/openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml up -d openclaw-gateway
```

If you changed `COMPOSE_PROJECT_NAME` in `.env`, replace `openclaw-easy` with that value.

Quick restart (without recreate/rebuild):

### Windows (PowerShell)
```powershell
cd .\vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml restart openclaw-gateway
```

### Windows (Command Prompt)
```cmd
cd /d vendor\openclaw && docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml restart openclaw-gateway
```

### macOS/Linux (bash)
```bash
cd ./vendor/openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml restart openclaw-gateway
```

Use `start.*` again only when you want to rebuild/update source or re-run setup/repair flows.
`start.*` also syncs `.env` into `vendor/openclaw/.env` so manual Docker Compose commands there use the same token/keys.

## 5.1) After editing `.env`

For most `.env` changes (API keys, gateway token, runtime flags), you only need to recreate the gateway container.

### Windows (PowerShell)
```powershell
Copy-Item .\.env .\vendor\openclaw\.env -Force
cd .\vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml up -d --force-recreate openclaw-gateway
```

### macOS/Linux (bash)
```bash
cp ./.env ./vendor/openclaw/.env
cd ./vendor/openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml up -d --force-recreate openclaw-gateway
```

If you changed `COMPOSE_PROJECT_NAME` in `.env`, replace `openclaw-easy` with that value.

Run full setup (`start.ps1` / `start.sh`) when you changed build/source variables:
- `OPENCLAW_REPO_URL`
- `OPENCLAW_REPO_BRANCH`
- `OPENCLAW_SRC_DIR`
- `OPENCLAW_USE_LOCAL_SOURCE`
- `OPENCLAW_IMAGE`
- `OPENCLAW_DOCKER_APT_PACKAGES`

If you changed `OPENCLAW_MISSION_CONTROL_*` or `OPENCLAW_COMMAND_CENTER_*`, run `start.*` so those service configs are synced and restarted correctly.

## 5.2) Use OpenClaw CLI directly

From `openclaw-easy-starter/vendor/openclaw`:

### Windows (PowerShell)
```powershell
cd .\vendor\openclaw

# List all available CLI commands
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli --help

# Run common commands
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli status
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli sessions
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli config get gateway.auth.token
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli dashboard --no-open

# Enter an interactive shell in the CLI container
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm --entrypoint sh openclaw-cli
# inside the container:
node dist/index.js --help
node dist/index.js status
exit
```

### Windows (Command Prompt)
```cmd
cd /d vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli --help
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm --entrypoint sh openclaw-cli
```

### macOS/Linux (bash)
```bash
cd ./vendor/openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli --help
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm --entrypoint sh openclaw-cli
```

If you changed `COMPOSE_PROJECT_NAME` in `.env`, replace `openclaw-easy` with that value.

## 6) Reset

Stop stack and remove Docker volumes:

### Windows
```powershell
.\reset.ps1
```

### Windows (Command Prompt)
```cmd
reset.cmd
```

### macOS/Linux
```bash
./reset.sh
```

Also remove cloned OpenClaw source:

### Windows
```powershell
.\reset.ps1 -Full
```

### Windows (Command Prompt)
```cmd
reset.cmd --full
```

### macOS/Linux
```bash
./reset.sh --full
```

## 7) Community participation with coding agents

If you contribute features or updates in your own branch/fork, keep AI memory exports in the community directory so other contributors and agents can resume quickly.

Required branch path:
- `docs/ai-memory/community/<branch-name>/`

Required files in that branch path:
- `PROJECT_MEMORY_EXPORT.md`

Rules:
- Use a folder name that matches your branch name.
- If branch name contains `/`, replace `/` with `-`.
- Attach both files from your branch folder to PR/MR requests.

To continue work in a new session, load:
- `docs/ai-memory/community/<branch-name>/PROJECT_MEMORY_EXPORT.md`

To customize how agents behave for this repository, update:
- `.agent/skills/project-preferences/SKILL.md`

For full workflow details, see:
- `.agent/skills/project-memory-export/README.md`

## Notes

- Default model is `openai/gpt-5.2` with fallback `openai/gpt-5-mini` (works with `OPENAI_API_KEY`).
- Python packages can be installed from inside OpenClaw with user scope:
  `python3 -m pip install --user <package>`
  (`~/.local/bin` and `~/.openclaw/tools/bin` are pre-added to PATH).
- Elevated shell commands are enabled for web chat by default:
  - `commands.bash=true`
  - `tools.elevated.enabled=true`
  - `tools.elevated.allowFrom.webchat[0]=*`
  - `tools.exec.ask` + exec approvals mode are controlled by `OPENCLAW_ALWAYS_ALLOW_EXEC`:
    - `false` (default): approvals can appear (`ask=on-miss`, allowlist security)
    - `true`: always allow (`ask=off`, full exec security for approvals defaults)
  This is scoped to the Docker container environment; it does not mount host filesystem paths by default.
- `claude` CLI is installed, but `claude-cli/*` models need Claude auth:
  `docker compose -f docker-compose.safe.yml run --rm --entrypoint claude openclaw-cli setup-token`
- `codex` CLI is installed and wired to use `OPENAI_API_KEY` automatically via
  `agents.defaults.cliBackends[codex-cli].env.OPENAI_API_KEY=${OPENAI_API_KEY}`.
- `openclaw` and `agent-browser` CLIs are installed in `/home/node/.openclaw/tools/bin`.
  Agent-browser quick test:
  `agent-browser open https://example.com`
  `agent-browser snapshot -i`
  `agent-browser screenshot /home/node/.openclaw/workspace/agent-browser-test.png`
  `agent-browser close`
- Gateway binds to `127.0.0.1` on port `18789` by default.
- Mission Control UI defaults to `http://127.0.0.1:3310/` and backend defaults to `http://127.0.0.1:8310/`.
- Command Center defaults to `http://127.0.0.1:3340/` when enabled.

## Quick fixes

If dashboard says unauthorized or missing token:
```powershell
cd .\vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli dashboard --no-open
```

If dashboard says `device token mismatch`:
```powershell
.\repair-auth.cmd
```
Then close all dashboard tabs, open the printed tokenized URL, and run this in browser DevTools console:
```js
localStorage.removeItem("openclaw.device.auth.v1");
localStorage.removeItem("openclaw-device-identity-v1");
localStorage.removeItem("openclaw.control.settings.v1");
location.reload();
```

If the site does not load at all:
```powershell
cd .\vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml up -d openclaw-gateway
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml ps
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml logs --tail=120 openclaw-gateway
```

If agent says Google/browser is blocked or unavailable:
```powershell
cd .\vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli config set browser.defaultProfile openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm --entrypoint sh openclaw-cli -lc 'for d in /home/node/.openclaw/browser/*/user-data; do [ -d "$d" ] || continue; rm -f "$d"/SingletonLock "$d"/SingletonSocket "$d"/SingletonCookie; done'
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml restart openclaw-gateway
```

If dashboard says pairing required:
```powershell
cd .\vendor\openclaw
$token = docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli config get gateway.auth.token
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli devices list --url ws://openclaw-gateway:18789 --token $token --json
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli devices approve <requestId> --url ws://openclaw-gateway:18789 --token $token --json
```

Telegram pairing approve:
```powershell
cd .\vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli pairing list telegram
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli pairing approve telegram <CODE>
```

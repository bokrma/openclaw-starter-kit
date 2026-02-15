# OpenClaw Easy Starter

This starter is for non-developer setup:
- clones OpenClaw automatically
- runs Docker safe mode
- sets gateway token auth
- installs Supermemory plugin
- installs tools (`clawhub`, `claude`, `codex`)
- installs your requested skills
- applies multi-agent defaults (including swarm concurrency)

## 1) Prerequisites

- Docker Desktop (running)
- Git
- Internet access

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

Edit `.env` and set at least:
- `OPENAI_API_KEY`
- `SUPERMEMORY_API_KEY`

`SUPERMEMORY_OPENCLAW_API_KEY` is auto-filled from `SUPERMEMORY_API_KEY` if left empty.
Default source ref is pinned to `v2026.2.14` for stability; change `OPENCLAW_REPO_BRANCH` in `.env` if you want another ref.

## 3) Start everything

### Windows (PowerShell)
```powershell
.\start.ps1
```

### Windows (Command Prompt)
```cmd
start.cmd
```

### macOS/Linux (bash)
```bash
chmod +x start.sh verify.sh reset.sh
./start.sh
```

`start.sh` auto-detects Windows Git Bash/MSYS and delegates to PowerShell automatically.

When setup finishes, open the printed dashboard URL (tokenized URL).

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

## 5) Daily use

Run the same start command again. It is idempotent and will update/repair as needed.

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

## Notes

- Default model is `openai/gpt-5.2-codex` (works with `OPENAI_API_KEY`).
- `claude` CLI is installed, but `claude-cli/*` models need Claude auth:
  `docker compose -f docker-compose.safe.yml run --rm --entrypoint claude openclaw-cli setup-token`
- Gateway binds to `127.0.0.1` on port `18789` by default.

## Quick fixes

If dashboard says unauthorized or missing token:
```powershell
cd .\vendor\openclaw
docker compose -f docker-compose.safe.yml run --rm openclaw-cli dashboard --no-open
```

If dashboard says pairing required:
```powershell
cd .\vendor\openclaw
$token = docker compose -f docker-compose.safe.yml run --rm openclaw-cli config get gateway.auth.token
docker compose -f docker-compose.safe.yml run --rm openclaw-cli devices list --url ws://openclaw-gateway:18789 --token $token --json
docker compose -f docker-compose.safe.yml run --rm openclaw-cli devices approve <requestId> --url ws://openclaw-gateway:18789 --token $token --json
```

Telegram pairing approve:
```powershell
cd .\vendor\openclaw
docker compose -f docker-compose.safe.yml run --rm openclaw-cli pairing list telegram
docker compose -f docker-compose.safe.yml run --rm openclaw-cli pairing approve telegram <CODE>
```

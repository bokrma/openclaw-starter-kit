# Setup and `.env` Reference

## Prerequisites

- Docker Desktop (running)
- Git
- Internet access

Linux quick install (if Docker is missing):

```bash
sudo apt-get update
sudo apt-get install -y docker.io docker-compose-plugin
sudo systemctl enable --now docker
```

## Create `.env`

From the repository root:

```powershell
Copy-Item .env.example .env
```

```bash
cp .env.example .env
```

## Required and Optional Keys

- Required: `OPENAI_API_KEY`
- Optional: `SUPERMEMORY_API_KEY`
- `SUPERMEMORY_OPENCLAW_API_KEY` is auto-filled from `SUPERMEMORY_API_KEY` if left empty.

## Source Selection Behavior

- Default source ref is `main`. Use `OPENCLAW_REPO_BRANCH` to pin a tag or branch.
- If this starter is inside an OpenClaw checkout, `OPENCLAW_USE_LOCAL_SOURCE=auto` uses local source automatically.
- If `OPENCLAW_USE_LOCAL_SOURCE=true` points to a non-OpenClaw folder, setup falls back to `vendor/openclaw`.
- To force local source:
  - `OPENCLAW_USE_LOCAL_SOURCE=true`
  - `OPENCLAW_SRC_DIR=<absolute path to your openclaw repo>`

## Runtime Defaults You May Change

- `OPENCLAW_DEFAULT_CHANNEL_PLUGINS` (comma-separated)
- `OPENCLAW_ALWAYS_ALLOW_EXEC=true|false`
- `COMPOSE_PROJECT_NAME` (default `openclaw-easy`)
- Keep `OPENCLAW_SAFE_PROJECT_NAME` aligned with `COMPOSE_PROJECT_NAME`.

## When You Must Re-run `start.*`

Re-run full setup if you changed:

- `OPENCLAW_REPO_URL`
- `OPENCLAW_REPO_BRANCH`
- `OPENCLAW_SRC_DIR`
- `OPENCLAW_USE_LOCAL_SOURCE`
- `OPENCLAW_IMAGE`
- `OPENCLAW_DOCKER_APT_PACKAGES`
- Any `OPENCLAW_MISSION_CONTROL_*` or `OPENCLAW_COMMAND_CENTER_*` variable

## Next

- Start and validation flow:
  [start-verify-reset.md](start-verify-reset.md)
- Mission Control and Command Center config:
  [services.md](services.md)

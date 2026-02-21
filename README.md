# OpenClaw Easy Starter

Beginner-friendly Docker setup for OpenClaw.

## Who this is for

- You want OpenClaw running locally without manual infra setup.
- You want setup scripts for Windows/macOS/Linux.
- You want optional Mission Control and Command Center included.

## What this starter configures

- Clones OpenClaw and runs Docker safe mode.
- Configures gateway token auth and default channel plugins (`telegram,whatsapp`).
- Installs key tools in container: `clawhub`, `openclaw`, `claude`, `codex`, `playwright`, `agent-browser`.
- Installs Supermemory plugin (when configured).
- Enables Mission Control by default.
- Supports optional Command Center.

## Starting Points

- Windows setup and first checks: [README.windows.md](README.windows.md)
- macOS setup and first checks (also works for Linux): [README.macos.md](README.macos.md)

Base URL is usually `http://127.0.0.1:18789/`.

## Important Daily-Use Rule

After first install, do not use `start.*` for normal restarts. Use fast daily commands in:

- [Daily Use Guide](docs/guides/daily-use.md)

## Docs Map

- Setup and `.env` reference:
  [docs/guides/setup-and-env.md](docs/guides/setup-and-env.md)
- Start, verify, tests, reset:
  [docs/guides/start-verify-reset.md](docs/guides/start-verify-reset.md)
- Mission Control and Command Center:
  [docs/guides/services.md](docs/guides/services.md)
- Daily operations (no rebuild flow):
  [docs/guides/daily-use.md](docs/guides/daily-use.md)
- OpenClaw CLI usage:
  [docs/guides/openclaw-cli.md](docs/guides/openclaw-cli.md)
- Troubleshooting:
  [docs/guides/troubleshooting.md](docs/guides/troubleshooting.md)
- Defaults and technical notes:
  [docs/guides/defaults-and-notes.md](docs/guides/defaults-and-notes.md)
- Community AI memory workflow:
  [docs/guides/community-workflow.md](docs/guides/community-workflow.md)

## Mission Control Board Packs

`board.pack.example.json` is a template only. It does not affect Mission Control unless you enable pack seeding and point to a real config file, then restart the stack.

Quick setup:

```powershell
Copy-Item .\board.pack.example.json .\board.pack.json -Force
```

```text
OPENCLAW_MISSION_CONTROL_SEED_BOARD_PACK=true
OPENCLAW_MISSION_CONTROL_BOARD_PACK_CONFIG_FILE=board.pack.json
```

See details in `docs/guides/services.md`.

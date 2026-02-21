# Defaults and Notes

- Default model is `openai/gpt-5.2` with fallback `openai/gpt-5-mini`.
- Python packages can be installed inside OpenClaw:
  `python3 -m pip install --user <package>`.
- `~/.local/bin` and `~/.openclaw/tools/bin` are pre-added to container `PATH`.
- Elevated shell is enabled for web chat by default:
  - `commands.bash=true`
  - `tools.elevated.enabled=true`
  - `tools.elevated.allowFrom.webchat[0]=*`
- Exec approval behavior is controlled by `OPENCLAW_ALWAYS_ALLOW_EXEC`:
  - `false` (default): approval prompts can appear
  - `true`: always allow
- `claude` CLI is installed, but Claude models require auth setup:
  `docker compose -f docker-compose.safe.yml run --rm --entrypoint claude openclaw-cli setup-token`
- `codex` CLI is installed and wired to use `OPENAI_API_KEY`.
- `openclaw`, `agent-browser`, `playwright` and related CLIs are installed in `/home/node/.openclaw/tools/bin`.
- Gateway default bind: `127.0.0.1:18789`.
- Mission Control defaults:
  - UI: `http://127.0.0.1:3310/`
  - Backend: `http://127.0.0.1:8310/`
- Command Center default when enabled: `http://127.0.0.1:3340/`.

# Daily Use (No Rebuild)

After first successful install, do not run `start.ps1` / `start.cmd` / `start.sh` for normal restarts. Those scripts rebuild/update and are slower.

## Fast Start (normal restart)

From `openclaw-easy-starter`:

```powershell
cd .\vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml up -d openclaw-gateway
```

```cmd
cd /d vendor\openclaw && docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml up -d openclaw-gateway
```

```bash
cd ./vendor/openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml up -d openclaw-gateway
```

If you changed `COMPOSE_PROJECT_NAME`, replace `openclaw-easy` in commands.

## Quick Restart (without recreate/rebuild)

```powershell
cd .\vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml restart openclaw-gateway
```

```cmd
cd /d vendor\openclaw && docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml restart openclaw-gateway
```

```bash
cd ./vendor/openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml restart openclaw-gateway
```

## After Editing `.env`

For most runtime changes (API keys, gateway token, runtime flags), recreate gateway only:

```powershell
Copy-Item .\.env .\vendor\openclaw\.env -Force
cd .\vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml up -d --force-recreate openclaw-gateway
```

```bash
cp ./.env ./vendor/openclaw/.env
cd ./vendor/openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml up -d --force-recreate openclaw-gateway
```

## When To Run Full `start.*` Again

Run full setup if you changed:

- build/source variables (`OPENCLAW_REPO_*`, `OPENCLAW_USE_LOCAL_SOURCE`, `OPENCLAW_SRC_DIR`, `OPENCLAW_IMAGE`, `OPENCLAW_DOCKER_APT_PACKAGES`)
- service configs (`OPENCLAW_MISSION_CONTROL_*` or `OPENCLAW_COMMAND_CENTER_*`)

`start.*` also syncs root `.env` to `vendor/openclaw/.env`.

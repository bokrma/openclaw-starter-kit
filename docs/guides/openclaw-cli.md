# OpenClaw CLI Usage

Run from `openclaw-easy-starter/vendor/openclaw`.

## Basic Commands

```powershell
cd .\vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli --help
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli status
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli sessions
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli config get gateway.auth.token
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli dashboard --no-open
```

```cmd
cd /d vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli --help
```

```bash
cd ./vendor/openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli --help
```

## Interactive Shell in CLI Container

```powershell
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm --entrypoint sh openclaw-cli
```

Inside container:

```bash
node dist/index.js --help
node dist/index.js status
exit
```

If you changed `COMPOSE_PROJECT_NAME`, replace `openclaw-easy` in all commands.

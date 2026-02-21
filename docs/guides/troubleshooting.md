# Troubleshooting

## Dashboard Unauthorized or Missing Token

```powershell
cd .\vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli dashboard --no-open
```

## `device token mismatch`

```powershell
.\repair-auth.cmd
```

Then close all dashboard tabs, open the printed tokenized URL, and run in browser DevTools:

```js
localStorage.removeItem("openclaw.device.auth.v1");
localStorage.removeItem("openclaw-device-identity-v1");
localStorage.removeItem("openclaw.control.settings.v1");
location.reload();
```

## Site Not Loading

```powershell
cd .\vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml up -d openclaw-gateway
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml ps
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml logs --tail=120 openclaw-gateway
```

## Browser Blocked/Unavailable

```powershell
cd .\vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli config set browser.defaultProfile openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm --entrypoint sh openclaw-cli -lc 'for d in /home/node/.openclaw/browser/*/user-data; do [ -d "$d" ] || continue; rm -f "$d"/SingletonLock "$d"/SingletonSocket "$d"/SingletonCookie; done'
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml restart openclaw-gateway
```

## Pairing Required

```powershell
cd .\vendor\openclaw
$token = docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli config get gateway.auth.token
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli devices list --url ws://openclaw-gateway:18789 --token $token --json
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli devices approve <requestId> --url ws://openclaw-gateway:18789 --token $token --json
```

## Telegram Pairing Approval

```powershell
cd .\vendor\openclaw
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli pairing list telegram
docker compose -p openclaw-easy --env-file .env -f docker-compose.safe.yml run --rm openclaw-cli pairing approve telegram <CODE>
```

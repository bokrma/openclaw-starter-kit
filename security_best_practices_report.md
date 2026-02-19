# Security Best Practices Report

## Executive Summary

The repository does **not** currently pass a publish-ready security gate.

- `pip-audit` found a known CVE in the Mission Control backend dependency graph.
- Mission Control Compose defaults expose services broadly with weak default DB credentials.
- Command Center defaults to `AUTH_MODE=none` (low friction for local dev, risky if ever exposed).
- One critical dependency scan (`vendor/openclaw` via `pnpm audit`) could not complete due upstream npm audit API failures, so dependency risk for that subtree remains unverified.

## Scope Reviewed

- `openclaw-easy-starter` scripts/config
- `openclaw-easy-starter/vendor/openclaw-mission-control` backend/frontend dependency and config posture
- `openclaw-easy-starter/vendor/openclaw` dependency audit attempt

## Automated Checks Run

1. `powershell -ExecutionPolicy Bypass -File .\test.ps1` -> passed
2. `powershell -ExecutionPolicy Bypass -File .\verify.ps1` -> passed (with runtime warning: `plugins.allow is empty`)
3. `npm.cmd audit --omit=dev --audit-level=high` in `vendor/openclaw-mission-control/frontend` -> `found 0 vulnerabilities`
4. `uvx --from pip-audit pip-audit -r openclaw-easy-starter/.tmp_backend_requirements.txt` -> **1 vulnerability found**
5. `pnpm audit --prod --audit-level high` in `vendor/openclaw` -> failed due npm audit endpoint `500 Internal Server Error` (scan incomplete)
6. Tracked-file secret grep for common key/token signatures -> no high-confidence leaked secrets found

## Findings

### F-001
- Rule ID: `DEP-PY-001`
- Severity: **High**
- Location: `openclaw-easy-starter/vendor/openclaw-mission-control/backend/pyproject.toml:16`
- Evidence:
  - `pip-audit` output: `cryptography 45.0.7  CVE-2026-26007  fix: 46.0.5`
  - `clerk-backend-api==4.2.0` is pinned and resolves to vulnerable `cryptography` transitively in the audited lock export.
- Impact: Known cryptography CVE in backend dependency chain can expose backend security properties to known exploit paths.
- Fix:
  - Upgrade to a dependency set that resolves `cryptography>=46.0.5`.
  - Re-run `pip-audit` and confirm zero findings.
- Mitigation:
  - If immediate upgrade is blocked, isolate backend exposure and reduce attack surface (strict ingress, no public backend port).
- False positive notes:
  - Verify with a fresh lock export after updating `pyproject.toml`.

### F-002
- Rule ID: `DEPLOY-NET-001`
- Severity: **Medium**
- Location:
  - `openclaw-easy-starter/vendor/openclaw-mission-control/compose.yml:12`
  - `openclaw-easy-starter/vendor/openclaw-mission-control/compose.yml:22`
  - `openclaw-easy-starter/vendor/openclaw-mission-control/compose.yml:46`
  - `openclaw-easy-starter/vendor/openclaw-mission-control/compose.yml:66`
  - `openclaw-easy-starter/vendor/openclaw-mission-control/compose.yml:9`
  - `openclaw-easy-starter/.env.example:35`
- Evidence:
  - Multiple services publish host ports without loopback binding (`"${PORT}:..."` pattern).
  - Default DB password is `postgres` in compose/env example.
- Impact: On machines with reachable host networking, database/redis/backend/frontend can be accessible to the local network with weak defaults.
- Fix:
  - Bind ports to loopback by default (`127.0.0.1:...`).
  - Require non-default `POSTGRES_PASSWORD` at startup (fail fast if unchanged).
- Mitigation:
  - Host firewall rules and private network only.
- False positive notes:
  - If deployment is guaranteed single-user local-only, risk is reduced but not eliminated.

### F-003
- Rule ID: `AUTH-CONFIG-001`
- Severity: **Medium**
- Location:
  - `openclaw-easy-starter/.env.example:62`
  - `openclaw-easy-starter/command-center.compose.yml:14`
  - `openclaw-easy-starter/start.sh:1026`
  - `openclaw-easy-starter/start.ps1:1196`
- Evidence:
  - Default `OPENCLAW_COMMAND_CENTER_AUTH_MODE=none`.
  - Compose consumes this into `DASHBOARD_AUTH_MODE`.
- Impact: If users expose/proxy Command Center beyond loopback, dashboard becomes unauthenticated by default.
- Fix:
  - Default to `token` mode in starter defaults.
  - Enforce non-empty token when `OPENCLAW_ENABLE_COMMAND_CENTER=true`.
- Mitigation:
  - Keep strict loopback binding (`127.0.0.1`) and never reverse-proxy without auth mode change.
- False positive notes:
  - Current compose file uses loopback mapping, which reduces immediate remote exposure.

### F-004
- Rule ID: `RELEASE-HYGIENE-001`
- Severity: **Low**
- Location:
  - `openclaw-easy-starter/.gitignore:1`
  - `openclaw-easy-starter/.gitignore:2`
- Evidence:
  - Root `.gitignore` omits `.tmp-openclaw-*` directories.
  - `git status --short` shows `.tmp-openclaw-command-center/` and `.tmp-openclaw-mission-control/` as untracked top-level paths.
- Impact: Accidental publication of embedded temporary repos/gitlinks is possible during bulk staging.
- Fix:
  - Add `.tmp-openclaw-*` to root `.gitignore`.
- Mitigation:
  - Use explicit path staging (`git add <files>`) instead of `git add .`.
- False positive notes:
  - Nested repo internals are not automatically committed unless explicitly staged, but staging mistakes are common.

## Unverified / Blocked Checks

- `vendor/openclaw` dependency vulnerability audit remains unverified because `pnpm audit` repeatedly failed with npm audit API `500`.

## Publish Recommendation

Do **not** push public yet. Address `F-001` and `F-002` at minimum, then re-run all dependency scans (including `vendor/openclaw` once npm audit endpoint is healthy).

# Start, Verify, Test, and Reset

## Start Everything

```powershell
.\start.ps1
```

```cmd
start.cmd
```

```bash
chmod +x start.sh verify.sh reset.sh
./start.sh
```

Notes:

- If PowerShell blocks scripts, run `.\start.cmd`.
- `start.sh` auto-detects Git Bash/MSYS on Windows and delegates to PowerShell.
- Missing keys are prompted during setup.
- Setup prints:
  - tokenized dashboard URL
  - Mission Control URL and local auth token (when enabled)
  - Command Center URL (when enabled)

Manual URL format:

- Base: `http://127.0.0.1:18789/`
- Tokenized: `http://127.0.0.1:18789/#token=<OPENCLAW_GATEWAY_TOKEN>`

## Verify Setup

```powershell
.\verify.ps1
```

```cmd
verify.cmd
```

```bash
./verify.sh
```

`verify` runs unit tests, then runtime checks. It also validates Mission Control and Command Center dashboards when enabled.

## Unit Tests Only

```powershell
.\test.cmd
```

```bash
./test.sh
```

## One-command Doctor

Runs full setup + verification + browser status probe.

```powershell
.\doctor.cmd
```

```bash
chmod +x doctor.sh
./doctor.sh
```

## Reset

Stop stack and remove Docker volumes:

```powershell
.\reset.ps1
```

```cmd
reset.cmd
```

```bash
./reset.sh
```

Remove volumes and cloned OpenClaw source:

```powershell
.\reset.ps1 -Full
```

```cmd
reset.cmd --full
```

```bash
./reset.sh --full
```

# OpenClaw Easy Starter — Windows

## Quick Start (first install)

1. Install prerequisites: Docker Desktop (running), Git, Internet access.
2. Create `.env`:

PowerShell:

```powershell
Copy-Item .env.example .env
```

Command Prompt:

```cmd
copy .env.example .env
```

3. Edit `.env`: Required `OPENAI_API_KEY`. Optional `SUPERMEMORY_API_KEY`.
4. Start setup:

PowerShell:

```powershell
.\start.ps1
```

Command Prompt:

```cmd
start.cmd
```

5. Open the dashboard URL printed at the end of setup.

Base URL is usually `http://127.0.0.1:18789/`.

## First Checks

- Full verification:

PowerShell:

```powershell
.\verify.ps1
```

Command Prompt:

```cmd
verify.cmd
```

- Unit tests only:

PowerShell:

```powershell
.\test.ps1
```

Command Prompt:

```cmd
test.cmd
```

- One-command setup + verification:

PowerShell:

```powershell
.\doctor.ps1
```

Command Prompt:

```cmd
doctor.cmd
```

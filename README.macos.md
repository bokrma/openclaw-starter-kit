# OpenClaw Easy Starter — macOS

This guide also works for Linux.

## Quick Start (first install)

1. Install prerequisites: Docker Desktop (running), Git, Internet access.
2. Create `.env`:

```bash
cp .env.example .env
```

3. Edit `.env`: Required `OPENAI_API_KEY`. Optional `SUPERMEMORY_API_KEY`.
4. Start setup:

```bash
chmod +x start.sh verify.sh reset.sh
./start.sh
```

5. Open the dashboard URL printed at the end of setup.

Base URL is usually `http://127.0.0.1:18789/`.

## First Checks

- Full verification:

```bash
./verify.sh
```

- Unit tests only:

```bash
./test.sh
```

- One-command setup + verification:

```bash
./doctor.sh
```

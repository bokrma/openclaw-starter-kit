USER_CONTEXT: Karim — QNAP NAS, Docker-heavy, home lab + cloud hybrid setup

KNOWN INFRASTRUCTURE:
  - QNAP NAS: running Docker containers, home lab
  - Gaming PC (RTX 5080): AI workloads, local development
  - Services: n8n, Qdrant, various Dockerized apps
  - Preference: self-hosted first, cloud when justified

ADAPT TO USER:
  - Karim is comfortable with Docker and Compose — skip basics
  - Home lab / QNAP constraints are real: power, storage, single-node limits
  - Suggest Hetzner or DigitalOcean for things that need HA
  - Always consider GPU passthrough for AI workloads

KEY CONCERNS FOR THIS USER:
  - Data sovereignty (self-hosted preference)
  - Cost efficiency (engineer, not enterprise budget)
  - AI model serving infrastructure
  - Reliable CI/CD for solo/small team projects

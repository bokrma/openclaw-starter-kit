PERSIST:
  - Infrastructure map: all running services, hosts, ports
  - Docker Compose configurations per project
  - CI/CD pipeline definitions
  - SSL certificate inventory with expiry dates
  - Incident history + resolutions
  - Backup schedules + last verified restore

MEMORY KEYS:
  infra.services.inventory         → all running services
  infra.qnap.config                → QNAP setup and container map
  infra.pipelines.[project]        → CI/CD definitions
  infra.certs.inventory            → SSL certs with expiry
  infra.incidents.log              → incident history
  infra.backups.schedule           → backup schedule + verification status

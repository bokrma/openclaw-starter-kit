FREQUENCY: On dispatch + scheduled infrastructure health checks

PROACTIVE BEHAVIORS:
  - Daily: check if any Docker containers are in restart loops
  - Weekly: review disk usage on QNAP, flag if >80%
  - Monthly: certificate expiry check, flag 30 days before
  - Flag any deployed service without a health check endpoint

INCIDENT DETECTION:
  - If a service deployment fails, immediately provide rollback steps
  - If memory/CPU alerts fire, surface optimization options

PERSIST:
  - Schema definitions per project (with version history of decisions)
  - Index strategy decisions and their rationale
  - Query performance benchmarks established
  - Migration history with change rationale
  - Known problematic queries flagged for future optimization

MEMORY KEYS:
  db.projects.[name].schema          → current schema + decisions
  db.projects.[name].indexes         → index inventory
  db.projects.[name].migrations      → migration log
  db.queries.slow_log               → known slow queries to address
  db.patterns.approved              → design patterns validated for this user

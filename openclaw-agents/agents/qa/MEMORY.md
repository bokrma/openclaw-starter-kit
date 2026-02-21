PERSIST:
  - Test suite inventory per project (what exists, coverage %)
  - Open bug log with severity and status
  - Known flaky tests and their status
  - Release checklists used and outcomes
  - Test automation framework choices per project
  - Performance baselines with measurement dates

MEMORY KEYS:
  qa.projects.[name].suite              → test suite inventory
  qa.projects.[name].bugs.open          → open bug log
  qa.projects.[name].bugs.history       → closed bug history
  qa.projects.[name].coverage           → coverage metrics
  qa.projects.[name].baselines          → performance + accessibility baselines
  qa.releases.[name].[version]          → release QA report

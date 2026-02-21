FREQUENCY: Pre-release check + on dispatch

PROACTIVE BEHAVIORS:
  - Before any deployment: "Have we run regression on these affected areas?"
  - Flag when new code is added without corresponding tests
  - Weekly: test coverage delta — did coverage go up or down?
  - Surface flaky tests immediately — they erode confidence in the suite

RELEASE READINESS CHECK:
  - All acceptance criteria verified?
  - Regression suite passed?
  - No known P0/P1 bugs open?
  - Performance baselines within bounds?
  - Accessibility checks passed?

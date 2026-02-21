FREQUENCY: On every user message + idle check every 5 minutes

HEARTBEAT TASKS:
  1. Check active agent tasks — surface completions to user
  2. Re-evaluate any stale routing decisions (>2min old)
  3. Validate memory freshness — flag outdated context
  4. Check if any chained agents are blocked or waiting for input
  5. Summarize session progress if session > 30 messages

PROACTIVE BEHAVIORS:
  - If user hasn't responded in 10min mid-task: ask if still needed
  - If 3+ agents were dispatched: send a status summary unprompted
  - If conflicting outputs detected: surface to user before responding

HEALTH CHECKS:
  - Verify all required agents are reachable before dispatch
  - Fallback: if agent unreachable, attempt 1 retry, then notify user

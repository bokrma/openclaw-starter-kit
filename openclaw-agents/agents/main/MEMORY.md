MEMORY STRATEGY: Layered — Session + Long-term

SESSION MEMORY (volatile, per conversation):
  - Active task queue
  - Agent dispatch history this session
  - Intermediate agent outputs (before synthesis)
  - User's stated goals this session
  - Clarifications received

LONG-TERM MEMORY (persistent):
  - User preferences and routing patterns that worked well
  - Recurring project contexts (Vibe Kanban, PathFinder, email AI)
  - Agents that performed well/poorly on specific task types
  - Custom user instructions given over time
  - Important decisions made (architecture choices, etc.)

MEMORY KEYS (conventions):
  user.preferences        → communication and style settings
  user.projects.active    → current project list with context
  routing.patterns        → learned dispatch rules
  agents.performance      → quality scores per agent per task type
  session.current         → active session state

FORGETTING RULES:
  - Session memory: cleared after session ends
  - Long-term: never auto-delete; flag for user review after 90 days of inactivity
  - Never store: passwords, API keys, financial account details

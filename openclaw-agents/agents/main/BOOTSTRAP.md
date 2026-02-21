INITIALIZATION SEQUENCE:

  STEP 1 — Load Identity
    Load IDENTITY.md, confirm role and authority scope

  STEP 2 — Load User Context
    Read USER.md → load Karim's profile and routing preferences
    Read MEMORY.md → restore last session state, ongoing projects

  STEP 3 — Register Available Agents
    Ping all agents, confirm availability
    Store agent manifest: [Backend, Frontend, DB, DevOps, Creative,
    Designer, Financial, Growth, Motivation, PM, QA, Research, UIUX]

  STEP 4 — Load Routing Rules
    Apply user-specific routing hints from USER.md
    Load any custom routing overrides from memory

  STEP 5 — Ready State
    Output: "Jarvis online. [N] agents available. How can I help?"

ON FAILURE:
  - If < 50% agents available: warn user, operate in degraded mode
  - If memory unreadable: start fresh, note it to user
  - Never block on agent failure — route around it

CORE TOOLS:
  - agent_dispatch(agent_id, task, context) → dispatches task to named agent
  - agent_dispatch_parallel([{agent_id, task}]) → concurrent multi-agent dispatch
  - agent_chain(source_agent, target_agent, transform_fn) → pipes output between agents
  - aggregate_responses(responses[]) → merges outputs into unified answer
  - context_broadcast(context) → sends shared context to all active agents
  - intent_classifier(user_input) → returns task type + required agents
  - memory_read(key) → retrieves stored context/facts
  - memory_write(key, value) → persists important decisions and learnings
  - clarify_user(question) → surfaces a clarifying question to the user

INTEGRATIONS:
  - All specialized agents (Backend, Frontend, DB, DevOps, etc.)
  - Memory system (short-term session + long-term persistent)
  - Notification layer (alerts user when long tasks complete)

CONSTRAINTS:
  - Max parallel dispatches: 5
  - Agent timeout: 60s before fallback or user notification
  - Never expose raw agent errors to user — wrap with context

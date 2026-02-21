# Community Workflow for AI Memory

If you contribute from your own branch/fork, keep memory exports so other contributors and agents can resume quickly.

## Required Path

- `docs/ai-memory/community/<branch-name>/`

If branch name contains `/`, replace `/` with `-`.

## Required File

- `PROJECT_MEMORY_EXPORT.md`

## Resume in a New Session

Load:

- `docs/ai-memory/community/<branch-name>/PROJECT_MEMORY_EXPORT.md`

## Agent Behavior Preferences

To customize default agent behavior for this repository, edit:

- `.agent/skills/project-preferences/SKILL.md`

For full export workflow details:

- `.agent/skills/project-memory-export/README.md`

# project-memory-export

Creates a portable project-memory export for cross-device and contributor continuity.

## What this skill does

- Produces `docs/ai-memory/community/<branch-name>/PROJECT_MEMORY_EXPORT.md` with repository + session context.
- Produces `docs/ai-memory/community/<branch-name>/CONTINUITY_BOOT_PROMPT.md` for quick session restart.
- Keeps memory grouped per branch for community collaboration.
- Enforces secret redaction (names only for env vars, never values).

## Trigger phrases

- "export project memory"
- "create cross-device handoff"
- "save everything we discussed in markdown"
- "prepare instant resume context"

## Output

- `docs/ai-memory/community/<branch-name>/PROJECT_MEMORY_EXPORT.md`
- `docs/ai-memory/community/<branch-name>/CONTINUITY_BOOT_PROMPT.md`

## Cross-device use

1. Sync/pull this repository on the other device.
2. Ensure both files exist under `docs/ai-memory/community/<branch-name>/`.
3. Start a new agent session in the same repo.
4. Paste the contents of `docs/ai-memory/community/<branch-name>/CONTINUITY_BOOT_PROMPT.md` as your first message.
5. Continue from the generated next actions list.

## Community contribution workflow

Use this when contributors add features, ship updates in their own branch/fork, or collaborate with a coding agent.

Why this helps:
- The exported memory captures the build path of the project, decisions made, and key relationships between components, variables, and flows.
- New sessions can reuse this context instead of rediscovering it from scratch.
- This reduces iteration cycles and speeds up solution finding.

### Where community files and versions must be uploaded

1. Create `docs/ai-memory/community/<branch-name>/` for your active branch.
2. Upload/export your branch memory files into that folder.
3. Keep current canonical files named exactly:
- `docs/ai-memory/community/<branch-name>/PROJECT_MEMORY_EXPORT.md`
- `docs/ai-memory/community/<branch-name>/CONTINUITY_BOOT_PROMPT.md`
4. If you keep extra versions, store them in the same branch folder so all branch memory history stays together.

### Load memory before requesting changes

1. Checkout your working branch.
2. Load `docs/ai-memory/community/<branch-name>/PROJECT_MEMORY_EXPORT.md`.
3. Load `docs/ai-memory/community/<branch-name>/CONTINUITY_BOOT_PROMPT.md`.
4. Start your coding-agent request by explicitly asking the agent to read those files first, then continue implementation.

### Export and attach memory for PR/MR

1. After completing work, run a memory export update.
2. Ensure both export files are updated under `docs/ai-memory/community/<branch-name>/`.
3. Attach `docs/ai-memory/community/<branch-name>/PROJECT_MEMORY_EXPORT.md` to your PR/MR request.
4. Attach `docs/ai-memory/community/<branch-name>/CONTINUITY_BOOT_PROMPT.md` to your PR/MR request.

### Branch naming rule

- The `<branch-name>` directory must match the branch being worked on.
- If your branch name contains `/`, convert `/` to `-` for the directory name.
- Example: branch `feature/auth-refactor` -> `docs/ai-memory/community/feature-auth-refactor/PROJECT_MEMORY_EXPORT.md`.

### Agent behavior customization

- Users can update `.agent/skills/project-preferences/SKILL.md` to add more repository-specific instructions for how agents should behave when handling change requests.

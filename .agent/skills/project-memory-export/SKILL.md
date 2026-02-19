---
name: project-memory-export
description: Export complete project and session context into portable Markdown files so work can continue on another device with minimal context loss.
---

# Project Memory Export

## Purpose

Create a complete, portable memory package for this repository so a new AI session on another device can resume with the same practical context.

Important constraint:
- AI sessions do not share hidden memory across devices.
- Continuity must be recreated from explicit files.
- This skill enforces that file-based continuity workflow.

## When To Use

Use this skill when the user asks to:
- export memory
- create a project handoff
- continue on another laptop/device
- save everything discussed in Markdown
- generate instant context restore files

## Non-Negotiable Rules

1. Never write secrets to export files.
- Include variable names only, never secret values or tokens.
- Redact credentials, private keys, cookies, and connection strings.

2. Use concrete references.
- Include exact file paths and commands.
- Include exact dates (YYYY-MM-DD) and current branch/commit.

3. Capture both repository state and conversation state.
- Repo state: architecture, commands, env expectations, active changes.
- Conversation state: user goals, decisions, constraints, pending tasks.

4. Keep export actionable.
- New session must be able to continue from the export without guessing.

5. Use branch-scoped community paths.
- Export files under `docs/ai-memory/community/<branch-name>/`.
- `<branch-name>` must match the current branch name.
- If branch name contains `/`, replace `/` with `-` for the folder name.
- Community uploads and version history must stay inside that same branch folder.

## Output Files

Write/update these files:
- `docs/ai-memory/community/<branch-name>/PROJECT_MEMORY_EXPORT.md`
- `docs/ai-memory/community/<branch-name>/CONTINUITY_BOOT_PROMPT.md`

## Required Workflow

1. Collect repository snapshot
- Current branch, latest commit hash/message, dirty/clean status.
- Key project structure and entry points.
- Setup/test/run commands from docs/scripts.
- Environment variable names from `.env.example` and related docs.
- Active TODOs/open risks from code/docs.

2. Collect conversation memory snapshot
- User objective and success criteria.
- Decisions already made.
- Constraints and preferences.
- Work completed in this session.
- Remaining steps and blockers.

3. Generate `PROJECT_MEMORY_EXPORT.md`
- Use the required section template below.
- Keep concise but complete.
- Prefer bullet lists and explicit file references.
- Write to `docs/ai-memory/community/<branch-name>/PROJECT_MEMORY_EXPORT.md`.

4. Generate `CONTINUITY_BOOT_PROMPT.md`
- Create a copy-paste starter prompt for a new chat.
- It must instruct the new agent to load `PROJECT_MEMORY_EXPORT.md` first.
- Write to `docs/ai-memory/community/<branch-name>/CONTINUITY_BOOT_PROMPT.md`.

5. Provide import steps to user
- Explain how to move these files into the same project path on another device.
- Explain first message to send in the new session.

6. Provide PR/MR handoff steps to user
- Instruct user to upload/commit the exported files in `docs/ai-memory/community/<branch-name>/`.
- Instruct user to attach those files in PR/MR so reviewers and agents can resume quickly.

## Required Section Template For `PROJECT_MEMORY_EXPORT.md`

Use these sections in order:

1. `# Project Memory Export`
2. `## Snapshot Metadata`
3. `## Project Identity`
4. `## Current Objectives`
5. `## Architecture And Key Paths`
6. `## Setup, Run, And Test Commands`
7. `## Environment Variables (Names Only, No Values)`
8. `## Decisions And Rationale`
9. `## Work Completed In This Session`
10. `## Pending Work / Next Actions`
11. `## Risks / Unknowns`
12. `## Resume Checklist`
13. `## First Prompt For New Session`

## Template For `CONTINUITY_BOOT_PROMPT.md`

The file must contain a short prompt equivalent to:

- Ask the agent to read `docs/ai-memory/community/<branch-name>/PROJECT_MEMORY_EXPORT.md`.
- Instruct it to restate goals, risks, and immediate next 3 actions.
- Instruct it to continue execution from the exported state without re-discovery.

## Completion Criteria

Consider the export complete only when:
- both files exist
- both files are under `docs/ai-memory/community/<branch-name>/`
- secret values are not present
- steps for cross-device restore were provided
- steps for community upload and PR/MR attachment were provided
- resume checklist is specific and executable

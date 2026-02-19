---
name: project-preferences
description: Apply project defaults for every coding task: full QA plus security testing, clean reactive UI behavior, and iterative test-fix-validation until ready.
---

# Project Preferences

## Purpose

Persist user-specific execution preferences for this repository so they are applied by default on every feature and code change.

## When To Use

Use this skill for any coding activity in this repository, including:
- new features
- bug fixes
- refactors
- UI updates
- API or data layer changes

## Mandatory Defaults

### 0. Docker-First Execution (Always)

For all project operations:
- run actions through Docker containers/services
- run project commands through Docker tooling (for example, `docker compose exec`, `docker compose run`)
- avoid host-machine direct command execution for project tasks unless Docker-based execution is impossible

If Docker-based execution is not possible for a specific task, explicitly report:
- which task could not run through Docker
- why Docker execution was not feasible
- the fallback used

### 1. QA + Security Validation On Every Change

For each piece of code or feature:
- run relevant tests (unit, integration, and end-to-end where applicable)
- run relevant security checks or security-focused review for the changed scope
- do not treat work as complete before validation evidence exists

If tests or security checks cannot run, explicitly report:
- what could not run
- why it could not run
- what remains unverified

### 2. Keep UI Clean And Reactive

For any frontend/UI impact:
- preserve a clean interface
- ensure UI reacts correctly to user actions and async states
- verify loading, success, empty, and error states are handled
- avoid visually noisy or inconsistent interactions

### 3. Iterate Until Fully Ready

Use a fix loop:
1. run checks/tests
2. identify failures or regressions
3. fix issues
4. rerun checks/tests
5. repeat until passing and validated

Completion standard:
- solution is implemented
- tests/checks are passing for changed scope
- no known unresolved validation failures remain

## Execution Checklist

- Use Docker-first command execution for all applicable tasks
- Identify impacted layers (backend, frontend, data, infra)
- Select and run appropriate tests for impacted layers
- Perform security-focused validation for changed code paths
- Verify UI responsiveness and behavior where applicable
- Repeat test/fix cycles until stable
- Report validation status and residual risk clearly


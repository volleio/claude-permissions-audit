---
name: permissions-audit
description: >-
  Use when reviewing, auditing, or cleaning up Claude Code permission allow, deny,
  and ask lists across settings files. Flags overly permissive patterns, deprecated
  syntax, duplicates, missing safety rules, and suggests project-type-aware additions.
user-invokable: true
args:
  - name: scope
    description: "Audit scope: 'global', 'project', or 'all' (default: all)"
    required: false
---

Audit Claude Code permission allow/deny/ask lists across all settings files. Classify issues by risk, suggest tightening, and interactively apply fixes.

## Permission Model Reference

Claude Code has three permission arrays, evaluated in order: **deny → ask → allow**. First match wins.

| Array | Behavior |
|-------|----------|
| `allow` | Auto-approved — no prompt |
| `ask` | Always prompts for confirmation |
| `deny` | Auto-rejected — tool cannot be used at all |

Anything not matching any array falls through to the `defaultMode` setting. Use the right array for the intent:
- **allow** — safe, read-only, or frequently-used commands (linters, test runners, git log)
- **ask** — commands that should succeed but need human review each time (git commit, git push, deployments)
- **deny** — commands that should never execute, even if explicitly requested (force push, rm -rf /)

## Phase 1: Discovery

Read all three settings files and detect the project type.

### Settings Files

Read each file. If a file doesn't exist, note it and continue.

1. **Global**: `~/.claude/settings.json`
2. **Project shared**: `.claude/settings.json` (in project root)
3. **Project local**: `.claude/settings.local.json` (in project root)

Extract `permissions.allow`, `permissions.deny`, and `permissions.ask` arrays from each. Ignore all other fields (env, hooks, model, statusLine, spinnerVerbs, etc.) — they are out of scope and must never be modified.

### Project Type Detection

Check for indicator files in the project root to determine project type(s). A project can have multiple types.

| Indicator | Type |
|-----------|------|
| `pyproject.toml` + `uv.lock` | Python/uv |
| `pyproject.toml` (no uv.lock) | Python (generic) |
| `package.json` + `package-lock.json` | Node/npm |
| `package.json` + `yarn.lock` | Node/yarn |
| `package.json` + `pnpm-lock.yaml` | Node/pnpm |
| `package.json` + `bun.lock` or `bun.lockb` | Node/bun |
| `Cargo.toml` | Rust |
| `go.mod` | Go |
| `mise.toml` or `.mise.toml` | Mise |
| `docker-compose.yml` or `docker-compose.yaml` or `compose.yml` | Docker |
| `.github/` directory | GitHub |
| `Makefile` | Make |

If mise is detected, run `mise tasks ls` to enumerate available task names. These feed into Phase 3 suggestions.

### Scope Filtering

If the user passed a `scope` argument:
- `global` — only audit `~/.claude/settings.json`
- `project` — only audit `.claude/settings.json` and `.claude/settings.local.json`
- `all` (default) — audit all three files

### No Project Directory

If run outside a project (no `.claude/` directory in the working directory), gracefully skip project settings files and only audit the global settings. Note this in the Phase 4 summary. Project-type detection and project-type-aware suggestions are also skipped in this case.

## Phase 2: Audit

Analyze every entry in every allow/deny/ask list. Classify each finding by risk level.

### Risk Levels

| Risk | Criteria | Examples |
|------|----------|---------|
| **CRITICAL** | Allows arbitrary execution or data destruction | `Bash(*)`, `Bash(sudo *)`, `Bash(rm -rf *)`, credentials in patterns |
| **HIGH** | Broad wildcard on command family with destructive subcommands | `Bash(docker compose *)`, `Bash(find *)`, `Bash(git *)` |
| **MEDIUM** | Deprecated syntax, broader than necessary, duplicates, built-in overlap | `:*` patterns, redundant entries, `Bash(grep *)` |
| **LOW** | Hygiene/informational | Stale WebFetch domains, subset duplicates, style inconsistencies |

### Checks to Perform

Run every check below against every entry. One entry can trigger multiple findings.

**1. Overly Permissive Patterns**

Flag entries that grant broad access to command families with known destructive subcommands:

| Pattern | Risk | Why |
|---------|------|-----|
| `Bash(*)` | CRITICAL | Allows any command |
| `Bash(sudo *)` | CRITICAL | Root access |
| `Bash(rm -rf *)` | CRITICAL | Arbitrary deletion |
| `Bash(docker compose *)` or `Bash(docker compose:*)` | HIGH | Includes `down -v`, `rm`, `exec` |
| `Bash(find *)` or `Bash(find:*)` | HIGH | `-exec` allows arbitrary execution |
| `Bash(git *)` or `Bash(git:*)` | HIGH | Includes destructive ops (reset, clean, push --force) |
| `Bash(npm *)` or `Bash(npm:*)` | HIGH | `npm exec` allows arbitrary execution |
| `Bash(PGPASSWORD=* psql *)` or `Bash(PGPASSWORD=* psql:*)` | CRITICAL | Arbitrary SQL execution. If password is a literal (not `*`), also a credential exposure issue (see check 4) |

**2. Deprecated Syntax**

The legacy `:*` suffix syntax is deprecated. The current syntax uses a space: ` *`.

- `Bash(cmd:*)` should be `Bash(cmd *)`
- Word boundary semantics: `Bash(ls *)` matches `ls -la` but NOT `lsof`. `Bash(ls*)` matches both.
- Flag ALL `:*` entries as MEDIUM risk

**3. Duplicates**

- **Exact duplicates**: Same string appears multiple times in the same file's allow, deny, or ask list
- **Cross-file duplicates**: Same rule in both global and project settings (project rule is redundant if global already allows it). Always flag — let the user decide whether to keep or remove
- **Subset duplicates**: `Bash(mise run check *)` is a subset of `Bash(mise run check:*)` or vice versa. `Bash(pip index *)` subsumes `Bash(pip index versions *)`

**4. Credential Exposure**

Flag entries containing literal passwords, tokens, or secrets in patterns:
- `PGPASSWORD=<literal>` — password visible in config
- `TOKEN=`, `SECRET=`, `API_KEY=` in patterns
- Risk: CRITICAL (credentials in plain text)

**5. Built-in Tool Overlap**

Claude Code has built-in tools that replace common shell commands. These Bash allows cause approval fatigue for no benefit:

| Bash Pattern | Built-in Alternative | Note |
|-------------|---------------------|------|
| `Bash(grep *)` or `Bash(grep:*)` | Grep tool | Remove — Grep tool is always available |
| `Bash(find *)` or `Bash(find:*)` | Glob tool | Remove or heavily scope — Glob handles file finding |
| `Bash(cat *)` or `Bash(cat:*)` | Read tool | Remove — Read tool handles file reading |
| `Bash(head *)`, `Bash(tail *)` | Read tool (with offset/limit) | Remove |
| `Bash(wc *)` or `Bash(wc:*)` | Grep (count mode) or Bash | Low priority, but note overlap |
| `Bash(tree *)` or `Bash(tree:*)` | Glob + Bash(ls) | Low priority |

**6. Missing Deny/Ask Rules**

Check if these baseline safety rules exist. If not, suggest adding them.

Suggested **deny** rules (should never execute):
- `Bash(git push --force *)` (or `--force-with-lease`, `-f`)
- `Bash(git reset --hard *)`
- `Bash(git clean -f *)`
- `Bash(rm -rf /*)` (no space — matches `rm -rf /etc`, `rm -rf /home`, etc.)
- `Bash(rm -rf ~*)` (no space — matches `rm -rf ~/Documents`, `rm -rf ~`, etc.)

Suggested **ask** rules (should prompt, not auto-approve or auto-deny):
- `Bash(git commit *)` — human should review before committing
- `Bash(git push *)` — human should review before pushing
- `Bash(docker compose down *)` — stops services, may lose data with `-v`

Check all three arrays across global and project settings. Global is preferred for baseline safety rules.

**9. Wrong Array Placement**

Flag entries in the wrong permission array:
- Destructive commands in `allow` that should be in `deny` or `ask` (e.g., `Bash(git push --force *)` in allow)
- Review-worthy commands in `allow` that should be in `ask` (e.g., `Bash(git commit *)` in allow — human should review)
- Safe read-only commands in `deny` or `ask` that could be in `allow` (e.g., `Bash(git log *)` in ask)
- Commands in `deny` that block legitimate use — suggest `ask` instead if the command is sometimes needed (e.g., `Bash(git commit *)` in deny blocks all commits; `ask` allows with confirmation)

**7. Misplaced Rules**

Flag project-specific entries in global settings that should live in the relevant project's `.claude/settings.json` or `.claude/settings.local.json`:

- `Bash(npx playwright install *)` — project-specific tool setup
- `Bash(PGPASSWORD=postgres psql *)` — project-specific database access
- `Bash(npx vitest run *)` — project-specific test runner
- Project-specific `WebFetch` domains that only apply to one project
- Entries referencing project-specific commands not used across projects

Heuristic: If a command is only relevant to one project type (e.g., `vitest` for a specific Node project, `PGPASSWORD` for a specific database), it likely belongs in project settings.

**8. Syntax Inconsistencies**

Flag when the same logical command uses different pattern styles across files:
- Same command with `:*` in one file and ` *` in another
- Same command with wildcard in one file and exact match in another (e.g., `Bash(uv sync)` in project vs `Bash(uv sync:*)` in global)

## Phase 3: Suggest

Generate two categories of recommendations.

### A. Tighten Existing Rules

For entries flagged HIGH or CRITICAL, suggest specific replacements:

| Current | Suggested Replacements |
|---------|----------------------|
| `Bash(docker compose *)` | `Bash(docker compose up *)`, `Bash(docker compose ps *)`, `Bash(docker compose logs *)`, `Bash(docker compose build *)` (omit `exec` — runs arbitrary commands in containers) |
| `Bash(docker compose:*)` | Same as above (also migrates deprecated syntax) |
| `Bash(find *)` | Remove (use Glob) or scope: `Bash(find * -name *)`, `Bash(find * -type *)` |
| `Bash(find:*)` | Same as above |
| `Bash(git *)` | `Bash(git status *)`, `Bash(git log *)`, `Bash(git diff *)`, `Bash(git branch *)`, `Bash(git show *)`, `Bash(git stash *)` |
| `Bash(git:*)` | Same as above |
| `Bash(PGPASSWORD=<literal> psql *)` | Remove from global. If needed in a project, add to that project's `.claude/settings.local.json` with tighter scope |
| `Bash(npm *)` | `Bash(npm test *)`, `Bash(npm run *)`, `Bash(npm install *)`, `Bash(npm ls *)` |

### B. Add Missing Rules (Project-Type-Aware)

Based on detected project type, suggest additions unless the rule already exists in any settings file. Target the appropriate file:
- `.claude/settings.json` (project shared) — team-visible rules: test runners, linters, build commands, dev servers
- `.claude/settings.local.json` (project local) — personal/credential-adjacent rules: database access with passwords, local tool configs, user-specific commands

| Project Type | Suggested Allows |
|-------------|-----------------|
| Python/uv | `Bash(uv sync)`, `Bash(uv run pytest *)`, `Bash(uv pip show *)`, `Bash(uv pip index versions *)`, `Bash(uv lock)` |
| Node/npm | `Bash(npm test *)`, `Bash(npm run lint *)`, `Bash(npm run build *)`, `Bash(npx tsc *)` |
| Node/bun | `Bash(bun test *)`, `Bash(bun run *)` |
| Rust | `Bash(cargo build *)`, `Bash(cargo test *)`, `Bash(cargo clippy *)`, `Bash(cargo fmt *)` |
| Go | `Bash(go build *)`, `Bash(go test *)`, `Bash(go vet *)` |
| Mise | One `Bash(mise run <task>)` or `Bash(mise run <task> *)` for each task from `mise tasks ls`. If a task is read-only (test, lint, typecheck, check), use exact match. If a task takes arguments, use wildcard. |
| Docker | `Bash(docker compose up -d)`, `Bash(docker compose ps *)`, `Bash(docker compose logs *)`, `Bash(docker compose build *)` |
| GitHub | `Bash(gh pr list *)`, `Bash(gh pr view *)`, `Bash(gh pr diff *)`, `Bash(gh issue list *)`, `Bash(gh issue view *)` |
| Make | `Bash(make *)` (if Makefile only has safe targets) or individual `Bash(make <target>)` entries |

Also suggest baseline deny and ask rules if missing (see Phase 2, check 6).

**Do NOT suggest rules that already exist** in any of the three settings files, even if in a different syntax variant. Check for semantic equivalence: `Bash(uv sync)` ≈ `Bash(uv sync *)` ≈ `Bash(uv sync:*)`.

## Phase 4: Interactive Apply

Present findings and apply changes interactively. **NEVER auto-modify settings files without explicit user approval for each change.**

### Step 1: Summary

Present a summary table:

```
## Permissions Audit Results

**Project type**: Python/uv + Mise + Docker + GitHub
**Files scanned**: 3 (global, project shared, project local)

| Severity | Count |
|----------|-------|
| CRITICAL | N     |
| HIGH     | N     |
| MEDIUM   | N     |
| LOW      | N     |

**N tightening recommendations, N additions suggested**
```

### Step 2: Issue-by-Issue Review

Present issues in severity order: CRITICAL first, then HIGH, MEDIUM, LOW.

For each issue, show:

```
### [SEVERITY] Issue Title
**File**: ~/.claude/settings.json (global)
**Current**: `Bash(docker compose:*)`
**Problem**: Broad wildcard on command family with destructive subcommands (down -v, rm). Also uses deprecated `:*` syntax.
**Proposed**:
  - Remove: `Bash(docker compose:*)`
  - Add: `Bash(docker compose up *)`, `Bash(docker compose ps *)`, `Bash(docker compose logs *)`, `Bash(docker compose build *)`

Accept / Reject / Skip?
```

Wait for user response before proceeding to next issue. Use the AskUserQuestion tool if needed.

When an entry is being modified for any reason (tightening, dedup, relocation), also migrate `:*` to ` *` in the same edit. Do NOT create separate issues for `:*` migration on entries already being modified.

### Step 3: Batch Additions

After individual issues, present project-type suggestions as a group:

```
### Suggested Additions for Python/uv + Mise project

These commands are commonly needed but not in your allow lists:

| # | Rule | File | Rationale |
|---|------|------|-----------|
| 1 | `Bash(mise run dev)` | project shared | Dev server task |
| 2 | `Bash(gh issue list *)` | global | GitHub issue browsing |
| ... | ... | ... | ... |

Add all / Pick individually / Skip all?
```

### Step 4: Remaining Deprecated Syntax

After all other changes, if there are `:*` entries that were NOT touched in Steps 2-3, offer a batch migration:

```
### Deprecated `:*` Syntax Migration

N entries still use the deprecated `:*` syntax. Migrate all to ` *`?

| Current | Migrated |
|---------|----------|
| `Bash(tree:*)` | `Bash(tree *)` |
| `Bash(ls:*)` | `Bash(ls *)` |
| ... | ... |

Migrate all / Pick individually / Skip?
```

### Step 5: Final Summary

After all changes are applied:

```
## Audit Complete

**Applied**: N changes across M files
**Skipped**: N items
**Rejected**: N items

Changes made:
- [file]: removed N entries, added N entries, migrated N syntax
- [file]: ...
```

## JSON Editing Rules

Settings files are JSON. Follow these rules strictly:

1. **Read before edit**: Always Read the file immediately before editing to get current content
2. **Targeted array edits**: Use the Edit tool to modify specific entries in the `permissions.allow`, `permissions.deny`, or `permissions.ask` arrays. Never rewrite the entire file.
3. **Preserve structure**: Never modify, reorder, or touch any fields outside of `permissions.allow`, `permissions.deny`, and `permissions.ask`
4. **Valid JSON**: After each edit, verify the file is valid JSON by reading it back
5. **Array operations**:
   - **Remove entry**: Edit the array to remove the specific line (handle trailing commas)
   - **Add entry**: Edit to insert at the end of the array before the closing `]`
   - **Replace entry**: Edit old string to new string
6. **Batch edits**: When multiple changes apply to the same file, make them in a single Edit operation to avoid intermediate invalid states
7. **Backup note**: Settings files are typically in git (`.claude/settings.json`) or gitignored (`settings.local.json`, `~/.claude/settings.json`). Remind the user they can `git checkout` project settings if needed, but global/local settings have no automatic backup.

## NEVER Rules

- **NEVER** modify settings without explicit user approval for each change
- **NEVER** touch non-permission fields (env, hooks, model, statusLine, spinnerVerbs, enabledPlugins, etc.)
- **NEVER** remove deny or ask rules without explicit user request — these are safety boundaries
- **NEVER** add overly broad patterns as suggestions (no `Bash(git *)`, always scoped)
- **NEVER** guess at project-specific commands — only suggest what's detected from indicator files and tool output
- **NEVER** migrate `:*` syntax on entries that aren't being touched for another fix (unless user opts into batch migration in Step 4)
- **NEVER** assume WebFetch domains are stale — only flag if user confirms the domain is no longer needed
- **NEVER** rewrite entire settings files — always use targeted edits

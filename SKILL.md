---
name: permissions-audit
description: >-
  Use when reviewing, auditing, or cleaning up Claude Code permission allow, deny,
  and ask lists across settings files. Flags overly permissive patterns, deprecated
  syntax, duplicates, missing safety rules, and suggests project-type-aware additions.
user-invokable: true
args:
  - name: command
    description: "Scope ('global'/'project'/'all') or 'discover <tool-name>' to explore a CLI tool's commands"
    required: false
---

Audit Claude Code permission allow/deny/ask lists across all settings files. Classify issues by risk, suggest tightening, and interactively apply fixes. Can also discover permissions for new CLI tools.

## Mode Selection

Parse the first argument to determine the mode:
- `global`, `project`, `all`, or no argument → **Audit mode** (Phases 1-4 below)
- `discover <tool-name>` → **Discover mode** (see Discover Mode section at the end)

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

Extract `permissions.allow`, `permissions.deny`, and `permissions.ask` arrays from each. Also note the `permissions.defaultMode` value if set — it affects the overall security posture (see below). Ignore all other fields (env, hooks, model, statusLine, spinnerVerbs, etc.) — they are out of scope and must never be modified.

### Default Mode Check

Read `permissions.defaultMode` from each file. Surface the value in the Phase 4 summary. Flag if set to a permissive mode:

| Mode | Risk | Note |
|------|------|------|
| `"default"` or absent | OK | Standard behavior — prompts on first use |
| `"plan"` | OK | Requires plan approval |
| `"dontAsk"` | OK | Auto-denies unless pre-approved in allow rules |
| `"bypassPermissions"` | CRITICAL | All permission rules are ignored — every tool auto-approved |
| `"acceptEdits"` | HIGH | File edits auto-approved without review |

Do not modify `defaultMode` — only surface it as informational context.

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

If the argument is one of the audit scopes:
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
| **CRITICAL** | Allows arbitrary execution or data destruction (in allow/ask) | `Bash(*)`, `Bash(sudo *)`, `Bash(rm -rf *)`, credentials in patterns |
| **HIGH** | Broad wildcard on risky command family (in allow/ask) | `Bash(docker compose *)`, `Bash(find *)`, `Bash(git *)` |
| **MEDIUM** | Deprecated syntax, broader than necessary, duplicates, built-in overlap | `:*` patterns, redundant entries, `Bash(grep *)` |
| **LOW** | Hygiene/informational | Stale WebFetch domains, subset duplicates, style inconsistencies |

Note: Broad patterns in `deny` are safety features, not risks — see check 1 for array-context-aware classification.

### Checks to Perform

Run every check below against every entry. One entry can trigger multiple findings. When multiple checks flag the same entry, **consolidate into a single finding** using the highest severity and combining the rationale (e.g., an entry that is both overly permissive and in the wrong array → one finding, not two).

**1. Overly Permissive Patterns**

Flag entries in `allow` or `ask` that grant broad access to command families with known destructive subcommands. **Skip this check for `deny` entries** — broad patterns in deny are safety features, not risks.

| Pattern | Risk (in allow) | Risk (in ask) | Why |
|---------|----------------|---------------|-----|
| `Bash(*)` | CRITICAL | HIGH | Allows any command |
| `Bash(sudo *)` | CRITICAL | HIGH | Root access |
| `Bash(rm -rf *)` | CRITICAL | HIGH | Arbitrary deletion |
| `Bash(docker compose *)` or `Bash(docker compose:*)` | HIGH | MEDIUM | Includes `down -v`, `rm`, `exec` |
| `Bash(find *)` or `Bash(find:*)` | HIGH | MEDIUM | `-exec` allows arbitrary execution |
| `Bash(git *)` or `Bash(git:*)` | HIGH | MEDIUM | Includes destructive ops (reset, clean, push --force) |
| `Bash(npm *)` or `Bash(npm:*)` | HIGH | MEDIUM | `npm exec` allows arbitrary execution |
| `Bash(PGPASSWORD=* psql *)` or `Bash(PGPASSWORD=* psql:*)` | CRITICAL | CRITICAL | Arbitrary SQL execution. If password is a literal (not `*`), also a credential exposure issue (see check 4) |

Risk is lower in `ask` (user still confirms each use) but broad `ask` patterns still warrant tightening.

**2. Deprecated Syntax**

The legacy `:*` suffix syntax is deprecated. The current syntax uses a space: ` *`.

- `Bash(cmd:*)` should be `Bash(cmd *)`
- Word boundary semantics: `Bash(ls *)` matches `ls -la` but NOT `lsof`. `Bash(ls*)` matches both.
- Flag ALL `:*` entries as MEDIUM risk

**3. Duplicates**

- **Exact duplicates**: Same string appears multiple times in the same file's allow, deny, or ask list
- **Cross-file duplicates (same tier)**: Same rule in the same array type across global and project settings (e.g., both have `Bash(uv sync)` in allow). The project rule is redundant. Always flag — let the user decide whether to keep or remove
- **Cross-file narrowing (different tier)**: A global `allow` + project `ask` for the same pattern is **intentional narrowing** — the project wants a prompt despite global auto-approve. Do NOT flag these as duplicates. Similarly, a project `deny` overriding a global `allow` is intentional restriction
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
- `Bash(git push *)` — human should review before pushing (deny rules for `--force` take precedence, so this is safe)
- `Bash(docker compose down *)` — stops services, may lose data with `-v`

Check all three arrays across global and project settings. Global is preferred for baseline safety rules.

**7. Wrong Array Placement**

Flag entries in the wrong permission array:
- Destructive commands in `allow` that should be in `deny` or `ask` (e.g., `Bash(git push --force *)` in allow)
- Review-worthy commands in `allow` that should be in `ask` (e.g., `Bash(git commit *)` in allow — human should review)
- Safe read-only commands in `deny` or `ask` that could be in `allow` (e.g., `Bash(git log *)` in ask)
- Commands in `deny` that block legitimate use — suggest `ask` instead if the command is sometimes needed (e.g., `Bash(git commit *)` in deny blocks all commits; `ask` allows with confirmation)

**8. Misplaced Rules**

Flag project-specific entries in global settings that should live in the relevant project's `.claude/settings.json` or `.claude/settings.local.json`:

- `Bash(npx playwright install *)` — project-specific tool setup
- `Bash(PGPASSWORD=postgres psql *)` — project-specific database access
- `Bash(npx vitest run *)` — project-specific test runner
- Project-specific `WebFetch` domains that only apply to one project
- Entries referencing project-specific commands not used across projects

Heuristic: If a command is only relevant to one project type (e.g., `vitest` for a specific Node project, `PGPASSWORD` for a specific database), it likely belongs in project settings.

**9. Syntax Inconsistencies**

Flag when the same logical command uses different pattern styles across files:
- Same command with `:*` in one file and ` *` in another
- Same command with wildcard in one file and exact match in another (e.g., `Bash(uv sync)` in project vs `Bash(uv sync:*)` in global)

**10. Broad Non-Bash Tool Patterns**

Not all permissions are Bash commands. Flag overly broad patterns for other tool types:

| Pattern | Risk | Why |
|---------|------|-----|
| `mcp__*` or `mcp__<server>__*` in allow | HIGH | Grants all operations for an MCP server — some may be destructive |
| `Read(*)` or `Write(*)` in allow | HIGH | Unrestricted file read/write, including secrets |
| `Edit(*)` in allow | MEDIUM | Unrestricted file editing |
| `WebFetch(*)` or `WebSearch` in allow | LOW | Informational — broad but low-risk |

For MCP wildcards like `mcp__logfire__*`, suggest scoping to specific operations if the server's available tools are known. Otherwise flag as informational.

**11. Usage Log Analysis (optional)**

If `~/.claude/tool-usage.log` exists (created by the companion logging hook — see Usage Logging section), analyze it for:
- Frequently used Bash commands not in any allow list → suggest adding to reduce approval fatigue
- Commands that appear in allow but were never used in the log period → flag as potentially stale (LOW)

This check is informational only — findings are LOW severity and presented as suggestions in Phase 3 Step 3 (batch additions). If the log file doesn't exist, skip this check silently.

### Settings File Merge Semantics

Permission arrays (`allow`, `deny`, `ask`) are **concatenated** across all settings files — not replaced. Then rules are evaluated in order: **deny → ask → allow, first match wins**. This means if a pattern appears in deny in ANY file, it's denied — no other file can override it. Same for ask over allow.

Examples:
- Global `allow` + project `deny` for same pattern → denied (deny checked first)
- Global `allow` + project `ask` for same pattern → prompted (ask checked before allow)
- Global `ask` + project `allow` for same pattern → prompted (ask checked before allow)
- Global `deny` + project `allow` for same pattern → denied (deny checked first)

Scalar settings like `defaultMode` are **replaced** by higher-precedence scopes (local > shared > global), not merged.

Cross-file "narrowing" (a project adding an ask or deny for something globally allowed) is a legitimate pattern, not a conflict. Use this understanding when assessing cross-file duplicates (check 3) and misplaced rules (check 8).

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
| `Bash(git *)` | **allow**: `Bash(git status *)`, `Bash(git log *)`, `Bash(git diff *)`, `Bash(git branch *)`, `Bash(git show *)`, `Bash(git stash list *)`, `Bash(git stash show *)`, `Bash(git stash push *)`; **ask**: `Bash(git commit *)`, `Bash(git push *)`, `Bash(git stash drop *)` (data loss) |
| `Bash(git:*)` | Same as above |
| `Bash(PGPASSWORD=<literal> psql *)` | Remove from global. If needed in a project, add to that project's `.claude/settings.local.json` with tighter scope |
| `Bash(npm *)` | `Bash(npm test *)`, `Bash(npm run lint *)`, `Bash(npm run build *)`, `Bash(npm install *)`, `Bash(npm ls *)` (avoid blanket `npm run *` — can execute any package.json script including deploys/migrations) |

### B. Add Missing Rules (Project-Type-Aware)

Based on detected project type, suggest additions unless the rule already exists in any settings file. Target the appropriate file:
- `.claude/settings.json` (project shared) — team-visible rules: test runners, linters, build commands, dev servers
- `.claude/settings.local.json` (project local) — personal/credential-adjacent rules: database access with passwords, local tool configs, user-specific commands

| Project Type | Suggested Allows |
|-------------|-----------------|
| Python/uv | `Bash(uv sync)`, `Bash(uv run pytest *)`, `Bash(uv pip show *)`, `Bash(uv pip index versions *)`, `Bash(uv lock)` |
| Node/npm | `Bash(npm test *)`, `Bash(npm run lint *)`, `Bash(npm run build *)`, `Bash(npx tsc *)` |
| Node/bun | `Bash(bun test *)`, `Bash(bun run lint *)`, `Bash(bun run build *)` (avoid blanket `bun run *` — same risk as `npm run *`) |
| Rust | `Bash(cargo build *)`, `Bash(cargo test *)`, `Bash(cargo clippy *)`, `Bash(cargo fmt *)` |
| Go | `Bash(go build *)`, `Bash(go test *)`, `Bash(go vet *)` |
| Mise | One `Bash(mise run <task>)` or `Bash(mise run <task> *)` for each task from `mise tasks ls`. If a task is read-only (test, lint, typecheck, check), use exact match. If a task takes arguments, use wildcard. |
| Docker | `Bash(docker compose up -d)`, `Bash(docker compose ps *)`, `Bash(docker compose logs *)`, `Bash(docker compose build *)` |
| GitHub | `Bash(gh pr list *)`, `Bash(gh pr view *)`, `Bash(gh pr diff *)`, `Bash(gh issue list *)`, `Bash(gh issue view *)` |
| Make | Individual `Bash(make <target>)` entries for each safe target (read the Makefile to enumerate). Do not suggest `Bash(make *)` — make targets can run arbitrary commands |

Also suggest baseline deny and ask rules if missing (see Phase 2, check 6).

**Do NOT suggest rules that already exist** in any of the three settings files, even if in a different syntax variant. Check for semantic equivalence: `Bash(uv sync)` ≈ `Bash(uv sync *)` ≈ `Bash(uv sync:*)`.

## Phase 4: Interactive Apply

Present findings and apply changes interactively. **NEVER auto-modify settings files without explicit user approval for each change.**

**CRITICAL INTERACTION RULE**: This phase is iterative. Present ONE step at a time, pause for user input using `AskUserQuestion`, apply changes, then continue to the next step. NEVER output multiple steps in a single response. Each response should contain at most ONE issue or ONE batch group.

### Step 0: Backup

Before making any changes, create backups of settings files that have no automatic git backup:
- `~/.claude/settings.json` → `~/.claude/settings.backup.json`
- `.claude/settings.local.json` → `.claude/settings.local.backup.json` (if it exists)

`.claude/settings.json` (project shared) is tracked by git — no backup needed (`git checkout` can restore it).

Use the Bash tool to copy: `cp ~/.claude/settings.json ~/.claude/settings.backup.json`. If a backup already exists from a previous run, overwrite it (only the most recent backup is kept). Inform the user which backups were created.

### Step 1: Summary

Present only the summary table, then immediately use `AskUserQuestion` to ask the user if they want to proceed with the issue-by-issue review.

```
## Permissions Audit Results

**Project type**: Python/uv + Mise + Docker + GitHub
**Files scanned**: 3 (global, project shared, project local)
**Default mode**: plan (OK)

| Severity | Count |
|----------|-------|
| CRITICAL | N     |
| HIGH     | N     |
| MEDIUM   | N     |
| LOW      | N     |

**N tightening recommendations, N additions suggested**
```

Then use `AskUserQuestion` with the question: "Ready to review issues? (yes / skip to additions / skip to syntax migration / done)"

### Step 2: Issue-by-Issue Review

Present issues one at a time in severity order: CRITICAL first, then HIGH, MEDIUM, LOW.

For each issue:
1. Output the issue description (ONE issue only)
2. Use `AskUserQuestion` to ask: "Accept / Reject / Skip?" (include issue number and total, e.g. "Issue 1/11")
3. Wait for the response
4. If accepted, apply the change using Edit tool, then confirm it was applied
5. Present the NEXT issue and repeat

Issue format:
```
### [SEVERITY] Issue Title (N of M)
**File**: ~/.claude/settings.json (global)
**Current**: `Bash(docker compose:*)`
**Problem**: Broad wildcard on command family with destructive subcommands (down -v, rm). Also uses deprecated `:*` syntax.
**Proposed**:
  - Remove: `Bash(docker compose:*)`
  - Add: `Bash(docker compose up *)`, `Bash(docker compose ps *)`, `Bash(docker compose logs *)`, `Bash(docker compose build *)`
```

When an entry is being modified for any reason (tightening, dedup, relocation), also migrate `:*` to ` *` in the same edit. Do NOT create separate issues for `:*` migration on entries already being modified.

If the user says "accept all" or "accept remaining", apply all remaining issues without further prompting and report what was done.

### Step 3: Batch Additions

After all individual issues are resolved, present project-type suggestions as a single group, then use `AskUserQuestion` to ask: "Add all / Pick individually / Skip all?"

```
### Suggested Additions for Python/uv + Mise project

These commands are commonly needed but not in your allow/ask lists:

| # | Rule | Array | File | Rationale |
|---|------|-------|------|-----------|
| 1 | `Bash(mise run dev)` | allow | project shared | Dev server task |
| 2 | `Bash(gh issue list *)` | allow | global | GitHub issue browsing |
| 3 | `Bash(git push *)` | ask | global | Push with human review |
| ... | ... | ... | ... | ... |
```

If "pick individually", present each addition one at a time using `AskUserQuestion` for each.

### Step 4: Remaining Deprecated Syntax

After all other changes, if there are `:*` entries that were NOT touched in Steps 2-3, present the migration table and use `AskUserQuestion` to ask: "Migrate all / Pick individually / Skip?"

```
### Deprecated `:*` Syntax Migration

N entries still use the deprecated `:*` syntax:

| Current | Migrated |
|---------|----------|
| `Bash(tree:*)` | `Bash(tree *)` |
| `Bash(ls:*)` | `Bash(ls *)` |
| ... | ... |
```

### Step 5: Final Summary

After all changes are applied, present a single summary:

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
   - **Create array**: If the file has no `ask` (or `deny`) array and one is needed, add it as a sibling to the existing arrays inside the `permissions` object. Example: insert `"ask": ["Bash(git commit *)"]` after the `allow` array's closing `]`
6. **Batch edits**: When multiple changes apply to the same file, make them in a single Edit operation to avoid intermediate invalid states
7. **Backup note**: Step 0 creates backups before changes. Project shared settings can also be restored with `git checkout`. Remind the user that `~/.claude/settings.backup.json` exists if they need to revert.

## NEVER Rules

- **NEVER** modify settings without explicit user approval for each change
- **NEVER** touch non-permission fields (env, hooks, model, statusLine, spinnerVerbs, enabledPlugins, etc.)
- **NEVER** remove deny or ask rules without explicit user request — these are safety boundaries
- **NEVER** add overly broad patterns as suggestions (no `Bash(git *)`, always scoped)
- **NEVER** guess at project-specific commands — only suggest what's detected from indicator files and tool output
- **NEVER** migrate `:*` syntax on entries that aren't being touched for another fix (unless user opts into batch migration in Step 4)
- **NEVER** assume WebFetch domains are stale — only flag if user confirms the domain is no longer needed
- **NEVER** rewrite entire settings files — always use targeted edits

## Discover Mode

When invoked with `/permissions-audit discover <tool-name>`, explore a CLI tool and suggest permission entries without running a full audit.

### Step 1: Explore the tool

1. Run `<tool> --help` (or `<tool> -h`, `<tool> help`) to get top-level commands/subcommands
2. For command groups that have their own subcommands, recurse one level: `<tool> <group> --help`
3. Stop at 2 levels of depth to avoid excessive exploration
4. If the tool is well-known (kubectl, aws, gh, docker, terraform, pup), leverage knowledge of its command tree to supplement `--help` output

**Security**: Only run `--help` / `-h` / `help` subcommands. Never run the tool's actual commands (e.g., don't run `pup synthetics tests create` to "test" it). Discovery is read-only.

### Step 2: Determine target file

Before suggesting entries, ask the user where rules should go. Use `AskUserQuestion`:
- Global (`~/.claude/settings.json`) — if the tool is used across projects
- Project shared (`.claude/settings.json`) — if team-shared for this project
- Project local (`.claude/settings.local.json`) — if personal/credential-adjacent

### Step 3: Read existing settings

Read the target file (and all other settings files) to collect existing permission entries. This is needed to avoid suggesting entries that already exist — check for semantic equivalence: `Bash(cmd)` ≈ `Bash(cmd *)` ≈ `Bash(cmd:*)`.

### Step 4: Categorize and suggest

Classify each discovered command by risk:

| Category | Keyword signals | Target array |
|----------|----------------|-------------|
| Read-only | list, get, show, describe, search, status, version, info, view, inspect, logs, whoami | allow |
| Write (reversible) | create, update, set, configure, run, start, stop, restart, trigger, push, apply | ask |
| Write (destructive) | delete, destroy, remove, purge, drop, force, reset, wipe, terminate | deny |

Filter out any entries that already exist in any settings file. Present remaining suggestions using the same interactive format as Phase 4 Step 3 (batch additions with `AskUserQuestion`).

Format: `Bash(<tool> <subcommand> *)` scoped to specific subcommands — never suggest `Bash(<tool> *)`.

### Step 5: Backup and apply

Before writing any changes, create a backup of the target file (same as Phase 4 Step 0 — `cp <file> <file>.backup`). Then apply accepted entries using the JSON Editing Rules.

## Usage Logging (Optional)

An **optional** companion hook that logs Bash tool usage to `~/.claude/tool-usage.log`. This enables check 11 (usage log analysis) in audit mode. The audit skill works fully without this hook — it only adds usage-pattern suggestions.

### Tradeoffs

Before installing, understand what you're opting into:

| Benefit | Cost |
|---------|------|
| Identifies frequently-prompted commands to add to allow | Adds ~5-10ms overhead per Bash tool call (fork + jq + sed + file write) |
| Surfaces stale allow entries you never use | Logs every Bash command to disk in plaintext |
| Reduces approval fatigue over time | Redaction is best-effort — secrets in non-`KEY=VALUE` formats can leak (e.g., `curl -H "Authorization: Bearer sk-..."`, base64 tokens as positional args) |

**Recommendation**: Install it, let it collect data for a week or two, run `/permissions-audit` to get suggestions, then **uninstall it**. Don't leave it running permanently.

### Installation

Requires `jq` (JSON processor). The script silently does nothing if jq is not available.

1. Copy: `cp hooks/log-tool-usage.sh ~/.claude/hooks/`
2. Chmod: `chmod +x ~/.claude/hooks/log-tool-usage.sh`
3. Add a `PostToolUse` entry **inside your existing `hooks` object** in `~/.claude/settings.json`:

```json
"PostToolUse": [
  {
    "matcher": "Bash",
    "hooks": [
      {
        "type": "command",
        "command": "~/.claude/hooks/log-tool-usage.sh"
      }
    ]
  }
]
```

**Important**: If you already have a `hooks` object (e.g., with `PreToolUse`), add `PostToolUse` as a sibling key — don't replace the entire `hooks` object.

### Uninstallation

Remove the `PostToolUse` entry from `~/.claude/settings.json` and optionally delete the log:

```bash
rm ~/.claude/hooks/log-tool-usage.sh
rm ~/.claude/tool-usage.log
```

### What it logs

Each line: `<ISO-8601 timestamp> <redacted command>`

Secrets are redacted before writing: `KEY=VALUE` patterns where KEY contains PASSWORD, TOKEN, SECRET, API_KEY, CREDENTIAL, AWS_SECRET_ACCESS_KEY, or PRIVATE_KEY have their value replaced with `***REDACTED***`. Both unquoted (`KEY=value`) and quoted (`KEY="value"`, `KEY='value'`) forms are redacted.

**Redaction is best-effort.** It does NOT catch: secrets as positional arguments, bearer tokens in headers, base64-encoded credentials, or any format that isn't `KEY=VALUE`. The log file is written with 0600 permissions (owner-only read/write).

### What it does NOT log

- Tool output (only the command string)
- Non-Bash tool calls (Read, Write, Edit, etc.)
- Commands that were denied (PostToolUse only fires after execution)

### Safety: exit code handling

PostToolUse hooks that exit non-zero can block Claude Code from executing further commands ([github.com/anthropics/claude-code/issues/4809](https://github.com/anthropics/claude-code/issues/4809)). The hook script uses `trap 'exit 0' ERR` to guarantee it always exits cleanly, even if jq, sed, or file I/O fails.

### Log management

The log file grows unbounded. Periodically check its size and truncate:

```bash
wc -c ~/.claude/tool-usage.log   # check size
tail -1000 ~/.claude/tool-usage.log > ~/.claude/tool-usage.log.tmp && mv ~/.claude/tool-usage.log.tmp ~/.claude/tool-usage.log  # keep last 1000 entries
```

The audit skill only reads the log — it never modifies or deletes it.

# Skill Evaluation Scenarios

Test the permissions-audit skill against these fixture files. Each scenario describes a sample settings configuration, the expected findings, and the expected severity.

Run the skill in a project containing the fixture files and verify the output matches expectations.

## How to run

1. Create a temp directory with the fixture files
2. Run `/permissions-audit` from that directory
3. Compare findings against the expected results below
4. Mark each expected finding as FOUND or MISSING

---

## Scenario 1: Clean settings (zero findings expected)

### Fixture: `~/.claude/settings.json` (global)
```json
{
  "permissions": {
    "allow": [
      "Bash(git log *)",
      "Bash(git status *)",
      "Bash(uv run pytest *)"
    ],
    "deny": [
      "Bash(git push --force *)",
      "Bash(git reset --hard *)",
      "Bash(git clean -f *)",
      "Bash(sudo *)",
      "Bash(rm -rf /*)",
      "Bash(rm -rf ~*)"
    ],
    "ask": [
      "Bash(git commit *)",
      "Bash(git push *)"
    ]
  }
}
```

### Expected: No findings (all clean)
- Modern syntax (space `*`)
- No broad patterns
- Baseline deny rules present
- Baseline ask rules present
- No duplicates

---

## Scenario 2: Common organic accumulation (many findings)

### Fixture: `~/.claude/settings.json` (global)
```json
{
  "permissions": {
    "allow": [
      "Bash(git:*)",
      "Bash(docker compose:*)",
      "Bash(find:*)",
      "Bash(grep:*)",
      "Bash(cat:*)",
      "Bash(PGPASSWORD=postgres psql:*)",
      "Bash(npm:*)",
      "Bash(ls:*)",
      "Bash(uv sync:*)",
      "Bash(uv sync:*)",
      "Bash(npx vitest run:*)",
      "mcp__logfire__*"
    ],
    "deny": [],
    "defaultMode": "plan"
  }
}
```

### Expected findings:

| # | Severity | Check | Entry | Issue |
|---|----------|-------|-------|-------|
| 1 | CRITICAL | 1+4 | `PGPASSWORD=postgres psql:*` | Credential exposure + arbitrary SQL + deprecated syntax |
| 2 | HIGH | 1+2 | `git:*` | Overly permissive (destructive subcommands) + deprecated syntax |
| 3 | HIGH | 1+2 | `docker compose:*` | Overly permissive (down -v, rm, exec) + deprecated syntax |
| 4 | HIGH | 1+2+5 | `find:*` | Overly permissive (-exec) + built-in overlap (Glob) + deprecated syntax |
| 5 | HIGH | 1+2 | `npm:*` | Overly permissive (npm exec) + deprecated syntax |
| 6 | HIGH | 10 | `mcp__logfire__*` | Broad MCP wildcard |
| 7 | MEDIUM | 2+5 | `grep:*` | Built-in overlap (Grep tool) + deprecated syntax |
| 8 | MEDIUM | 2+5 | `cat:*` | Built-in overlap (Read tool) + deprecated syntax |
| 9 | MEDIUM | 2+3 | `uv sync:*` (x2) | Exact duplicate + deprecated syntax |
| 10 | MEDIUM | 2 | `ls:*` | Deprecated syntax |
| 11 | MEDIUM | 2 | `npx vitest run:*` | Deprecated syntax (+ misplaced in global) |
| 12 | — | 6 | (missing) | Missing deny: git push --force, git reset --hard, git clean -f, sudo, rm -rf /, rm -rf ~ |
| 13 | — | 6 | (missing) | Missing ask: git commit, git push |

### Expected suggestions:
- Tighten: git, docker compose, find, npm, PGPASSWORD psql
- Add deny: force push, reset --hard, clean -f, sudo, rm -rf /, rm -rf ~
- Add ask: git commit, git push

---

## Scenario 3: Cross-file interactions

### Fixture: `~/.claude/settings.json` (global)
```json
{
  "permissions": {
    "allow": [
      "Bash(uv sync *)",
      "Bash(git log *)"
    ],
    "deny": [
      "Bash(git push --force *)"
    ],
    "ask": [
      "Bash(git commit *)"
    ]
  }
}
```

### Fixture: `.claude/settings.json` (project shared)
```json
{
  "permissions": {
    "allow": [
      "Bash(uv sync *)",
      "Bash(uv run pytest *)"
    ],
    "ask": [
      "Bash(git push *)"
    ]
  }
}
```

### Expected findings:

| # | Severity | Check | Issue |
|---|----------|-------|-------|
| 1 | LOW | 3 (cross-file same-tier) | `Bash(uv sync *)` in both global allow and project allow — project is redundant |

### Expected NON-findings (should NOT flag):
- `git push *` in project ask vs nothing in global → NOT a duplicate, it's a new ask rule
- `git commit *` in global ask → NOT flagged as cross-file issue (only in global)

---

## Scenario 4: Wrong array placement

### Fixture: `~/.claude/settings.json` (global)
```json
{
  "permissions": {
    "allow": [
      "Bash(git push --force *)",
      "Bash(git commit *)",
      "Bash(rm -rf *)"
    ],
    "deny": [
      "Bash(git log *)",
      "Bash(git status *)"
    ]
  }
}
```

### Expected findings:

| # | Severity | Check | Entry | Issue |
|---|----------|-------|-------|-------|
| 1 | CRITICAL | 1+7 | `rm -rf *` in allow | Should be in deny |
| 2 | HIGH | 1+7 | `git push --force *` in allow | Should be in deny |
| 3 | MEDIUM | 7 | `git commit *` in allow | Should be in ask |
| 4 | LOW | 7 | `git log *` in deny | Safe read-only command, could be in allow |
| 5 | LOW | 7 | `git status *` in deny | Safe read-only command, could be in allow |

---

## Scenario 5: Permissive defaultMode

### Fixture A: `~/.claude/settings.json` (bypassPermissions)
```json
{
  "permissions": {
    "allow": [],
    "deny": [],
    "defaultMode": "bypassPermissions"
  }
}
```

### Expected: CRITICAL — `bypassPermissions` all permission rules ignored

### Fixture B: `~/.claude/settings.json` (acceptEdits)
```json
{
  "permissions": {
    "allow": [],
    "deny": [],
    "defaultMode": "acceptEdits"
  }
}
```

### Expected: HIGH — `acceptEdits` file edits auto-approved without review

### Fixture C: Non-flagged modes (no findings expected for defaultMode)
- `"default"` → OK
- `"plan"` → OK
- `"dontAsk"` → OK (more restrictive than default)
- absent → OK

---

## Scenario 6: Subset duplicates

### Fixture: `~/.claude/settings.json` (global)
```json
{
  "permissions": {
    "allow": [
      "Bash(pip index *)",
      "Bash(pip index versions *)",
      "Bash(mise run lint *)",
      "Bash(mise run lint --fix *)",
      "Bash(git log *)",
      "Bash(git log --oneline *)"
    ],
    "ask": [
      "Bash(git commit *)",
      "Bash(git commit -m *)",
      "Bash(git commit --amend *)"
    ]
  }
}
```

### Expected findings:

| # | Severity | Check | Entry | Issue |
|---|----------|-------|-------|-------|
| 1 | LOW | 3 (subset) | `pip index versions *` | Subsumed by `pip index *` |
| 2 | LOW | 3 (subset) | `mise run lint --fix *` | Subsumed by `mise run lint *` |
| 3 | LOW | 3 (subset) | `git log --oneline *` | Subsumed by `git log *` |
| 4 | LOW | 3 (subset) | `git commit -m *` | Subsumed by `git commit *` |
| 5 | LOW | 3 (subset) | `git commit --amend *` | Subsumed by `git commit *` |

---

## Scenario 7: Syntax inconsistencies across files

### Fixture: `~/.claude/settings.json` (global)
```json
{
  "permissions": {
    "allow": [
      "Bash(uv sync:*)",
      "Bash(uv run pytest:*)"
    ]
  }
}
```

### Fixture: `.claude/settings.json` (project shared)
```json
{
  "permissions": {
    "allow": [
      "Bash(uv sync)",
      "Bash(uv run pytest *)"
    ]
  }
}
```

### Expected findings:

| # | Severity | Check | Issue |
|---|----------|-------|-------|
| 1 | MEDIUM | 9+2 | `uv sync:*` (global) vs `uv sync` (project) — syntax inconsistency + deprecated syntax in global |
| 2 | MEDIUM | 9+2 | `uv run pytest:*` (global) vs `uv run pytest *` (project) — syntax inconsistency + deprecated syntax in global |

---

## Scenario 8: Terraform/IaC project

### Fixture: `~/.claude/settings.json` (global)
```json
{
  "permissions": {
    "allow": [
      "Bash(terraform *)",
      "Bash(kubectl *)",
      "Bash(git log *)",
      "Bash(git status *)"
    ],
    "deny": [
      "Bash(git push --force *)"
    ],
    "ask": [
      "Bash(git commit *)"
    ]
  }
}
```

### Expected findings:

| # | Severity | Check | Entry | Issue |
|---|----------|-------|-------|-------|
| 1 | HIGH | 1 | `terraform *` in allow | Overly permissive — includes `apply` and `destroy` |
| 2 | HIGH | 1 | `kubectl *` in allow | Overly permissive — includes `delete`, `exec` |

### Expected suggestions:
- Tighten `terraform *` → allow: `init`, `plan`, `fmt`, `validate`; ask: `apply`, `import`; deny: `destroy`
- Tighten `kubectl *` → allow: `get`, `describe`, `logs`; ask: `apply`, `create`, `exec`; deny: `delete`
- Missing baseline deny: git reset --hard, git clean -f, sudo, rm -rf /*, rm -rf ~*
- Missing baseline ask: git push

---

## Scenario 9: Java/Gradle + Ruby mixed project

### Fixture: `~/.claude/settings.json` (global)
```json
{
  "permissions": {
    "allow": [
      "Bash(git log *)",
      "Bash(git status *)"
    ],
    "deny": [
      "Bash(git push --force *)",
      "Bash(git reset --hard *)",
      "Bash(git clean -f *)",
      "Bash(sudo *)",
      "Bash(rm -rf /*)",
      "Bash(rm -rf ~*)"
    ],
    "ask": [
      "Bash(git commit *)",
      "Bash(git push *)"
    ]
  }
}
```

### Project indicators (in project root):
- `build.gradle.kts` (Gradle)
- `Gemfile` (Ruby)
- `.github/` (GitHub)

### Expected: No findings (clean global settings)

### Expected suggestions (project-type-aware):
- Java/Gradle: `Bash(./gradlew build *)`, `Bash(./gradlew test *)`, `Bash(./gradlew check *)`
- Ruby: `Bash(bundle exec rspec *)`, `Bash(bundle exec rake *)`, `Bash(bundle exec rubocop *)`, `Bash(bundle install)`
- GitHub: `Bash(gh pr list *)`, `Bash(gh pr view *)`, `Bash(gh pr diff *)`, `Bash(gh issue list *)`, `Bash(gh issue view *)`

---

## Scenario 10: Catch-all `Bash(*)` and broad non-Bash patterns

### Fixture: `~/.claude/settings.json` (global)
```json
{
  "permissions": {
    "allow": [
      "Bash(*)",
      "Read(*)",
      "Write(*)",
      "Edit(*)",
      "mcp__slack__*",
      "mcp__github__*",
      "WebFetch(*)"
    ],
    "deny": [
      "Bash(rm -rf /*)"
    ]
  }
}
```

### Expected findings:

| # | Severity | Check | Entry | Issue |
|---|----------|-------|-------|-------|
| 1 | CRITICAL | 1 | `Bash(*)` in allow | Allows any command — deny rules still apply but everything else auto-approved |
| 2 | HIGH | 10 | `Read(*)` in allow | Unrestricted file read, including secrets |
| 3 | HIGH | 10 | `Write(*)` in allow | Unrestricted file write |
| 4 | MEDIUM | 10 | `Edit(*)` in allow | Unrestricted file editing |
| 5 | HIGH | 10 | `mcp__slack__*` in allow | Broad MCP wildcard — grants all Slack operations |
| 6 | HIGH | 10 | `mcp__github__*` in allow | Broad MCP wildcard — grants all GitHub operations |
| 7 | LOW | 10 | `WebFetch(*)` in allow | Broad but low-risk |

### Expected NON-findings:
- `Bash(rm -rf /*)` in deny → NOT flagged (broad deny is a safety feature)

---

## Scenario 11: Multiple credential types in patterns

### Fixture: `~/.claude/settings.json` (global)
```json
{
  "permissions": {
    "allow": [
      "Bash(TOKEN=ghp_abc123 gh api *)",
      "Bash(API_KEY=sk-proj-xyz curl *)",
      "Bash(DATABASE_URL=postgres://admin:secret@prod:5432/mydb psql *)",
      "Bash(MYSQL_PWD=rootpass mysql *)",
      "Bash(git log *)",
      "Bash(git status *)"
    ],
    "deny": [
      "Bash(git push --force *)",
      "Bash(git reset --hard *)",
      "Bash(git clean -f *)",
      "Bash(sudo *)",
      "Bash(rm -rf /*)",
      "Bash(rm -rf ~*)"
    ],
    "ask": [
      "Bash(git commit *)",
      "Bash(git push *)"
    ]
  }
}
```

### Expected findings:

| # | Severity | Check | Entry | Issue |
|---|----------|-------|-------|-------|
| 1 | CRITICAL | 4 | `TOKEN=ghp_abc123 gh api *` | Credential exposure — GitHub token in plain text |
| 2 | CRITICAL | 4 | `API_KEY=sk-proj-xyz curl *` | Credential exposure — API key in plain text |
| 3 | CRITICAL | 4 | `DATABASE_URL=postgres://admin:secret@prod:5432/mydb psql *` | Credential exposure — database connection string with embedded password |
| 4 | CRITICAL | 4 | `MYSQL_PWD=rootpass mysql *` | Credential exposure — MySQL password in plain text |

### Expected suggestions:
- Remove all credential-bearing entries from global settings
- If needed, add to project's `.claude/settings.local.json` with tighter scope

---

## Scenario 12: Literal colons in command names

### Fixture: `~/.claude/settings.json` (global)
```json
{
  "permissions": {
    "allow": [
      "Bash(mise run fe:*)",
      "Bash(npm run build:*)",
      "Bash(rake db:*)",
      "Bash(mise run check *)",
      "Bash(git log *)"
    ],
    "deny": [
      "Bash(git push --force *)",
      "Bash(git reset --hard *)",
      "Bash(git clean -f *)",
      "Bash(sudo *)",
      "Bash(rm -rf /*)",
      "Bash(rm -rf ~*)"
    ],
    "ask": [
      "Bash(git commit *)",
      "Bash(git push *)"
    ]
  }
}
```

### Expected findings:

| # | Severity | Check | Entry | Issue |
|---|----------|-------|-------|-------|
| 1 | MEDIUM | 2 | `mise run fe:*` | Deprecated `:*` syntax — BUT colon is likely part of mise task name. Migrating to `mise run fe *` would NOT match `mise run fe:lint`. Needs rewrite as individual exact-match rules |
| 2 | MEDIUM | 2 | `npm run build:*` | Deprecated `:*` syntax — BUT colon is likely part of npm script name. `npm run build *` would NOT match `npm run build:prod`. Needs exact-match rules |
| 3 | MEDIUM | 2 | `rake db:*` | Deprecated `:*` syntax — BUT colon is part of rake task name. `rake db *` would NOT match `rake db:migrate`. Needs exact-match rules |

### Expected NON-findings:
- `mise run check *` → NOT flagged for colon issues (no colon, uses modern ` *` syntax)

### Key behavior:
- The skill MUST warn the user that these `:*` entries contain literal colons and cannot be blindly migrated to ` *`
- Suggest listing each colon-command explicitly instead (e.g., `Bash(mise run fe:lint)`, `Bash(mise run fe:test)`)

---

## Scenario 13: Cross-file interactions with settings.local.json

### Fixture: `~/.claude/settings.json` (global)
```json
{
  "permissions": {
    "allow": [
      "Bash(git log *)",
      "Bash(git status *)",
      "Bash(uv run pytest *)"
    ],
    "deny": [
      "Bash(git push --force *)"
    ],
    "ask": [
      "Bash(git commit *)"
    ]
  }
}
```

### Fixture: `.claude/settings.json` (project shared)
```json
{
  "permissions": {
    "allow": [
      "Bash(uv run pytest *)",
      "Bash(mise run check)"
    ]
  }
}
```

### Fixture: `.claude/settings.local.json` (project local)
```json
{
  "permissions": {
    "allow": [
      "Bash(uv run pytest *)",
      "Bash(PGPASSWORD=devpass psql -d myapp_dev *)"
    ]
  }
}
```

### Expected findings:

| # | Severity | Check | Entry | Issue |
|---|----------|-------|-------|-------|
| 1 | CRITICAL | 1+4 | `PGPASSWORD=devpass psql -d myapp_dev *` in local allow | Credential exposure + arbitrary SQL. Acceptable in local file but password is in plain text |
| 2 | LOW | 3 | `uv run pytest *` in project shared allow | Redundant — already in global allow |
| 3 | LOW | 3 | `uv run pytest *` in project local allow | Redundant — already in global allow and project shared allow |

### Expected NON-findings:
- `git commit *` in global ask → NOT flagged (only in one file)
- `mise run check` in project shared → NOT flagged (only in one file, exact match is fine)
- Credential in `.local.json` should still be flagged for exposure, but the file location (local, gitignored) is appropriate

---

## Scenario 14: Package manager wildcards (make, yarn, pnpm)

### Fixture: `~/.claude/settings.json` (global)
```json
{
  "permissions": {
    "allow": [
      "Bash(make *)",
      "Bash(yarn *)",
      "Bash(pnpm *)",
      "Bash(git log *)",
      "Bash(git status *)"
    ],
    "deny": [
      "Bash(git push --force *)",
      "Bash(git reset --hard *)",
      "Bash(git clean -f *)",
      "Bash(sudo *)",
      "Bash(rm -rf /*)",
      "Bash(rm -rf ~*)"
    ],
    "ask": [
      "Bash(git commit *)",
      "Bash(git push *)"
    ]
  }
}
```

### Expected findings:

| # | Severity | Check | Entry | Issue |
|---|----------|-------|-------|-------|
| 1 | HIGH | 1 | `make *` in allow | Make targets are arbitrary shell commands — enumerate safe targets individually |
| 2 | HIGH | 1 | `yarn *` in allow | `yarn dlx` allows arbitrary execution; `yarn run` can execute any script |
| 3 | HIGH | 1 | `pnpm *` in allow | `pnpm dlx`/`pnpm exec` allows arbitrary execution |

### Expected suggestions:
- Tighten `make *` → remove and list individual safe targets (e.g., `Bash(make test)`, `Bash(make lint)`)
- Tighten `yarn *` → `Bash(yarn test *)`, `Bash(yarn lint *)`, `Bash(yarn build *)`
- Tighten `pnpm *` → `Bash(pnpm test *)`, `Bash(pnpm run lint *)`, `Bash(pnpm run build *)`

---

## Scenario 15: Broad patterns in `ask` array (lower severity than allow)

### Fixture: `~/.claude/settings.json` (global)
```json
{
  "permissions": {
    "allow": [
      "Bash(git log *)",
      "Bash(git status *)"
    ],
    "deny": [
      "Bash(git push --force *)",
      "Bash(git reset --hard *)",
      "Bash(git clean -f *)",
      "Bash(sudo *)",
      "Bash(rm -rf /*)",
      "Bash(rm -rf ~*)"
    ],
    "ask": [
      "Bash(docker compose *)",
      "Bash(git *)",
      "Bash(npm *)",
      "Bash(git commit *)",
      "Bash(git push *)"
    ]
  }
}
```

### Expected findings:

| # | Severity | Check | Entry | Issue |
|---|----------|-------|-------|-------|
| 1 | MEDIUM | 1 | `docker compose *` in ask | Broad pattern — includes `down -v`, `rm`. Lower severity than in allow because user still confirms |
| 2 | MEDIUM | 1 | `git *` in ask | Broad pattern — includes destructive ops. Lower severity because prompted |
| 3 | MEDIUM | 1 | `npm *` in ask | Broad pattern — `npm exec` allows arbitrary execution. Lower severity because prompted |
| 4 | LOW | 3 (subset) | `git commit *` in ask | Subsumed by `git *` in ask |
| 5 | LOW | 3 (subset) | `git push *` in ask | Subsumed by `git *` in ask |

### Key behavior:
- Broad patterns in `ask` should be flagged at **one severity level lower** than in `allow` (HIGH → MEDIUM, CRITICAL → HIGH)
- The skill should still suggest tightening, but note that the user is already prompted for each use
- `git commit *` and `git push *` are subsets of `git *` (all in the same `ask` array)

### Expected NON-findings:
- Deny rules → NOT flagged (broad deny is a safety feature)

---

## Scenario 16: Discover mode (basic)

### Invocation: `/permissions-audit discover git`

### Expected behavior:
1. Runs `git --help` (or `git help`) to enumerate subcommands
2. Asks the user which file to add rules to (global / project shared / project local)
3. Reads existing settings to avoid suggesting duplicates
4. Categorizes git subcommands into allow/ask/deny:
   - **allow**: `git status *`, `git log *`, `git diff *`, `git branch *`, `git show *`, `git stash list *`, `git stash show *`, `git remote -v *`, `git tag *`
   - **ask**: `git commit *`, `git push *`, `git merge *`, `git rebase *`, `git stash push *`, `git stash drop *`, `git checkout *`
   - **deny**: `git push --force *`, `git reset --hard *`, `git clean -f *`
5. Filters out any entries that already exist in settings
6. Presents remaining suggestions in batch format with Add all / Pick individually / Skip all
7. Creates backup before applying

### Key behavior:
- Should NOT suggest `Bash(git *)` (overly broad)
- Should only run `--help` / `-h` / `help` subcommands — no actual git operations
- Should scope each entry to specific subcommands
- Existing rules in any settings file should be excluded from suggestions

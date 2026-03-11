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

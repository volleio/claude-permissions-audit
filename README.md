# permissions-audit

Claude Code skill that audits your permission allow/deny lists across settings files. Flags overly permissive patterns, deprecated `:*` syntax, duplicates, credential exposure, missing safety rules, and suggests project-type-aware additions.

## Install

```bash
cd ~/Projects  # or wherever you keep repos
git clone https://github.com/volleio/claude-permissions-audit.git
ln -s "$(pwd)/claude-permissions-audit" ~/.claude/skills/permissions-audit
```

Requires [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with skills support.

## Usage

In any Claude Code session:

```
/permissions-audit          # audit all settings files
/permissions-audit global   # only ~/.claude/settings.json
/permissions-audit project  # only project-level settings
```

## What it checks

- **Overly permissive patterns** — broad wildcards on command families with destructive subcommands
- **Deprecated syntax** — `:*` entries that should use ` *`
- **Duplicates** — exact, cross-file, and subset matches
- **Credential exposure** — passwords/tokens embedded in patterns
- **Built-in tool overlap** — `Bash(grep *)`, `Bash(find *)`, etc. where Grep/Glob/Read exist
- **Missing deny rules** — force push, reset --hard, rm -rf, etc.
- **Misplaced rules** — project-specific entries in global settings
- **Project-type suggestions** — detects Python/uv, Node, Rust, Go, Mise, Docker, GitHub and suggests scoped allows

All changes are interactive — nothing is modified without your approval.

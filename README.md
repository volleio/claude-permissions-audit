# claude-permissions-audit

> Audit and optimize Claude Code permissions — a skill for [Claude Code](https://docs.anthropic.com/en/docs/claude-code)

Claude Code permission allow/deny/ask lists accumulate organically as you click "allow" during sessions. Over time you end up with overly broad entries, duplicates, deprecated syntax, credential exposure, and missing safety rules. This skill audits all your settings files, flags issues by severity, and interactively applies fixes.

Also includes a **discover mode** to explore new CLI tools and generate scoped permission entries before you start using them.

## Install

```bash
git clone https://github.com/volleio/claude-permissions-audit.git
cd claude-permissions-audit && ln -s "$(pwd)" ~/.claude/skills/permissions-audit
```

Requires [Claude Code](https://docs.anthropic.com/en/docs/claude-code) with skills support.

## Usage

```
/permissions-audit                  # audit all settings files
/permissions-audit global           # only ~/.claude/settings.json
/permissions-audit project          # only project-level settings
/permissions-audit discover kubectl  # explore a CLI tool and suggest permissions
/permissions-audit discover terraform # works with any CLI that has --help
```

## What it checks

- **Overly permissive patterns** — broad wildcards on command families with destructive subcommands (e.g. `Bash(docker compose *)` allows `down -v`, `rm`)
- **Deprecated syntax** — legacy `:*` entries that should use the current ` *` syntax
- **Duplicates** — exact, cross-file, and subset matches (e.g. `pip index *` subsumes `pip index versions *`)
- **Credential exposure** — passwords/tokens embedded in patterns (e.g. `PGPASSWORD=literal psql *`)
- **Built-in tool overlap** — `Bash(grep *)`, `Bash(find *)`, etc. where Claude Code's Grep/Glob/Read tools exist
- **Missing deny/ask rules** — force push, reset --hard, rm -rf in deny; git commit, git push in ask
- **Wrong array placement** — destructive commands in allow that belong in deny/ask, safe commands in deny that should be allow
- **Misplaced rules** — project-specific entries in global settings that belong in project settings
- **Syntax inconsistencies** — same command using `:*` in one file and ` *` in another
- **Broad non-Bash patterns** — overly permissive `mcp__*`, `Read(*)`, `Write(*)` rules
- **Default mode check** — flags `bypassPermissions` and other permissive modes
- **Usage log analysis** — if the optional logging hook is installed, identifies frequently-used commands not yet in allow
- **Project-type suggestions** — detects Python, Node, Rust, Go, Java, C#, Ruby, PHP, Terraform, Mise, Docker, GitHub, Make and suggests scoped allows

## Features

- **Interactive** — nothing is modified without your approval; review each change one at a time
- **Backups** — automatically backs up settings files before making changes
- **Discover mode** — explore a new CLI tool (`kubectl`, `terraform`, `helm`, etc.) and generate scoped allow/ask/deny entries
- **Project-aware** — detects your project type and suggests relevant permissions for the right settings file

## How it works

1. **Discovery** — reads global, project shared, and project local settings files; detects project type
2. **Audit** — runs 11 checks against every permission entry, classifies findings by severity (CRITICAL/HIGH/MEDIUM/LOW)
3. **Suggest** — generates tightening recommendations and project-type-aware additions
4. **Interactive apply** — presents findings one at a time with accept/reject/skip, applies approved changes

## Optional: Usage logging hook

An **optional** companion hook that logs Bash commands to `~/.claude/tool-usage.log` so the audit can suggest commonly-used commands you haven't added yet. The audit works fully without this — it only adds usage-pattern suggestions.

### Should I install it?

**Recommended approach**: Install it, collect data for 1-2 weeks, run `/permissions-audit` to get suggestions, then **uninstall it**. Don't leave it running permanently.

| Benefit | Cost |
|---------|------|
| Identifies frequently-prompted commands to add to allow | ~5-10ms overhead per Bash tool call |
| Surfaces stale allow entries you never use | Logs every Bash command to disk |

### Security considerations

- Redaction is **best-effort**: `KEY=VALUE` patterns (PASSWORD, TOKEN, SECRET, API_KEY, etc.) are redacted, but secrets passed as positional args, bearer tokens in headers, or base64-encoded credentials are **not caught**
- Log file is created with `0600` permissions (owner read/write only)
- The log file is plaintext — anyone with filesystem access can read it
- Requires `jq`; silently does nothing if jq is not installed

### Install

```bash
cp hooks/log-tool-usage.sh ~/.claude/hooks/
chmod +x ~/.claude/hooks/log-tool-usage.sh
```

Then add a `PostToolUse` entry **inside your existing `hooks` object** in `~/.claude/settings.json`:

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

> **Important**: If you already have a `hooks` object (e.g., with `PreToolUse`), add `PostToolUse` as a sibling key — don't replace the entire object.

### Uninstall

Remove the `PostToolUse` entry from settings and delete the files:

```bash
rm ~/.claude/hooks/log-tool-usage.sh
rm ~/.claude/tool-usage.log  # optional — review first if you want
```

## License

MIT

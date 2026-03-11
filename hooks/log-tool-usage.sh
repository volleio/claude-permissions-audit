#!/usr/bin/env bash
# PostToolUse hook: logs Bash commands to ~/.claude/tool-usage.log
# Redacts KEY=VALUE secrets (PASSWORD, TOKEN, SECRET, API_KEY, CREDENTIAL, PRIVATE_KEY, DATABASE_URL, etc.)
#
# Install:
#   cp hooks/log-tool-usage.sh ~/.claude/hooks/
#   chmod +x ~/.claude/hooks/log-tool-usage.sh
#   Add PostToolUse hook entry to ~/.claude/settings.json (see SKILL.md)
#
# Requires: jq (silently exits if not available)
#
# Security notes:
#   - Redaction is best-effort: only KEY=VALUE patterns are caught
#   - Secrets as positional args, bearer tokens, base64 creds are NOT redacted
#   - Log file is created with 0600 permissions (owner read/write only)
#   - Recommend: collect data for 1-2 weeks, run audit, then uninstall

set -uo pipefail

# CRITICAL: PostToolUse hooks that exit non-zero can block Claude Code execution
# (see github.com/anthropics/claude-code/issues/4809). Trap ensures we always exit 0.
trap 'exit 0' ERR

LOG_FILE="${HOME}/.claude/tool-usage.log"

# Read hook input from stdin
input=$(cat)

# Requires jq — silently exit if not available
if ! command -v jq &>/dev/null; then
  exit 0
fi

# Extract the command field; exit silently on parse failure
command_str=$(printf '%s' "$input" | jq -r '.tool_input.command // empty' 2>/dev/null) || true

if [[ -z "$command_str" ]]; then
  exit 0
fi

# Collapse newlines to spaces — multiline commands (heredocs, &&-chains) must be
# single-line log entries so each line has exactly one timestamp + command.
command_str=$(printf '%s' "$command_str" | tr '\n' ' ')

# Redact secrets in KEY=VALUE patterns (unquoted, double-quoted, single-quoted)
redacted=$(printf '%s' "$command_str" | sed -E \
  -e 's/(PASSWORD|TOKEN|SECRET|API_KEY|CREDENTIAL|AWS_SECRET_ACCESS_KEY|PRIVATE_KEY|DATABASE_URL|REDIS_URL|MONGO_URI|DSN|MYSQL_PWD)="[^"]*"/\1=***REDACTED***/gi' \
  -e "s/(PASSWORD|TOKEN|SECRET|API_KEY|CREDENTIAL|AWS_SECRET_ACCESS_KEY|PRIVATE_KEY|DATABASE_URL|REDIS_URL|MONGO_URI|DSN|MYSQL_PWD)='[^']*'/\1=***REDACTED***/gi" \
  -e 's/(PASSWORD|TOKEN|SECRET|API_KEY|CREDENTIAL|AWS_SECRET_ACCESS_KEY|PRIVATE_KEY|DATABASE_URL|REDIS_URL|MONGO_URI|DSN|MYSQL_PWD)=[^ "'"'"'"][^ ]*/\1=***REDACTED***/gi')

# Create log file with restricted permissions if it doesn't exist
if [[ ! -f "$LOG_FILE" ]]; then
  touch "$LOG_FILE"
  chmod 0600 "$LOG_FILE"
fi

# Append timestamped entry
printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$redacted" >> "$LOG_FILE"

exit 0

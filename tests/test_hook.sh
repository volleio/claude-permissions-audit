#!/usr/bin/env bash
# Tests for hooks/log-tool-usage.sh
# Run: ./tests/test_hook.sh
#
# Tests the hook script against various inputs and verifies:
# - Secret redaction (unquoted, double-quoted, single-quoted)
# - Non-secret commands pass through unchanged
# - Edge cases (empty input, malformed JSON, missing fields)
# - Log file permissions (0600)
# - Multiple secrets in one command
# - No jq fallback behavior

set -uo pipefail

HOOK_SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/hooks/log-tool-usage.sh"
TEST_LOG=""
TESTS_RUN=0
TESTS_PASSED=0
TESTS_FAILED=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

setup() {
  TEST_LOG=$(mktemp /tmp/hook-test-XXXXXX.log)
}

teardown() {
  rm -f "$TEST_LOG" 2>/dev/null
}

# Run hook with given JSON input, return last line of log
run_hook() {
  local json="$1"
  # Create a temp script that overrides LOG_FILE and runs the hook logic
  local tmp_hook
  tmp_hook=$(mktemp /tmp/hook-run-XXXXXX.sh)
  sed "s|^LOG_FILE=.*|LOG_FILE=\"$TEST_LOG\"|" "$HOOK_SCRIPT" > "$tmp_hook"
  chmod +x "$tmp_hook"
  printf '%s' "$json" | bash "$tmp_hook"
  local exit_code=$?
  rm -f "$tmp_hook"
  return $exit_code
}

# Get the command portion of the last log line (strip timestamp)
last_logged_command() {
  if [[ -f "$TEST_LOG" ]]; then
    tail -1 "$TEST_LOG" | sed 's/^[^ ]* //'
  fi
}

assert_logged() {
  local expected="$1"
  local description="$2"
  local actual
  actual=$(last_logged_command)
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$actual" == "$expected" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "${GREEN}  PASS${NC} %s\n" "$description"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "${RED}  FAIL${NC} %s\n" "$description"
    printf "       expected: %s\n" "$expected"
    printf "       actual:   %s\n" "$actual"
  fi
}

assert_not_logged() {
  local description="$1"
  local line_count
  line_count=$(wc -l < "$TEST_LOG" 2>/dev/null | tr -d ' ')
  TESTS_RUN=$((TESTS_RUN + 1))
  if [[ "$line_count" == "0" ]] || [[ ! -f "$TEST_LOG" ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "${GREEN}  PASS${NC} %s\n" "$description"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "${RED}  FAIL${NC} %s\n" "$description"
    printf "       expected: no log entry\n"
    printf "       actual:   %s line(s) logged\n" "$line_count"
  fi
}

assert_exit_zero() {
  local json="$1"
  local description="$2"
  TESTS_RUN=$((TESTS_RUN + 1))
  run_hook "$json"
  local code=$?
  if [[ $code -eq 0 ]]; then
    TESTS_PASSED=$((TESTS_PASSED + 1))
    printf "${GREEN}  PASS${NC} %s\n" "$description"
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
    printf "${RED}  FAIL${NC} %s\n" "$description"
    printf "       expected exit 0, got %d\n" "$code"
  fi
}

make_input() {
  local cmd="$1"
  printf '{"tool_name":"Bash","tool_input":{"command":"%s"},"hook_event_name":"PostToolUse"}' "$cmd"
}

# ============================================================
echo "Hook Tests"
echo "=========="
echo ""

# Check prerequisites
if ! command -v jq &>/dev/null; then
  printf "${RED}ERROR: jq required for tests${NC}\n"
  exit 1
fi

if [[ ! -x "$HOOK_SCRIPT" ]]; then
  printf "${RED}ERROR: Hook script not found or not executable: %s${NC}\n" "$HOOK_SCRIPT"
  exit 1
fi

# --- Basic functionality ---
echo "Basic functionality:"

setup
run_hook "$(make_input "git status")"
assert_logged "git status" "Normal command logged unchanged"
teardown

setup
run_hook "$(make_input "uv run pytest -x tests/")"
assert_logged "uv run pytest -x tests/" "Command with args logged unchanged"
teardown

# --- Secret redaction: unquoted ---
echo ""
echo "Secret redaction (unquoted KEY=VALUE):"

setup
run_hook "$(make_input "PGPASSWORD=mypass psql -d mydb")"
assert_logged "PGPASSWORD=***REDACTED*** psql -d mydb" "PGPASSWORD unquoted"
teardown

setup
run_hook "$(make_input "API_KEY=sk-abc123 curl https://api.example.com")"
assert_logged "API_KEY=***REDACTED*** curl https://api.example.com" "API_KEY unquoted"
teardown

setup
run_hook "$(make_input "TOKEN=abc123 some-command")"
assert_logged "TOKEN=***REDACTED*** some-command" "TOKEN unquoted"
teardown

setup
run_hook "$(make_input "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI some-command")"
assert_logged "AWS_SECRET_ACCESS_KEY=***REDACTED*** some-command" "AWS_SECRET_ACCESS_KEY unquoted"
teardown

# --- Secret redaction: double-quoted ---
echo ""
echo "Secret redaction (double-quoted KEY=\"VALUE\"):"

setup
run_hook '{"tool_name":"Bash","tool_input":{"command":"PGPASSWORD=\"mypass\" psql -d mydb"},"hook_event_name":"PostToolUse"}'
assert_logged "PGPASSWORD=***REDACTED*** psql -d mydb" "PGPASSWORD double-quoted"
teardown

setup
run_hook '{"tool_name":"Bash","tool_input":{"command":"SECRET=\"super secret value\" cmd"},"hook_event_name":"PostToolUse"}'
assert_logged "SECRET=***REDACTED*** cmd" "SECRET double-quoted with spaces"
teardown

# --- Secret redaction: single-quoted ---
echo ""
echo "Secret redaction (single-quoted KEY='VALUE'):"

setup
run_hook '{"tool_name":"Bash","tool_input":{"command":"PGPASSWORD='"'"'mypass'"'"' psql -d mydb"},"hook_event_name":"PostToolUse"}'
assert_logged "PGPASSWORD=***REDACTED*** psql -d mydb" "PGPASSWORD single-quoted"
teardown

# --- Multiple secrets ---
echo ""
echo "Multiple secrets in one command:"

setup
run_hook "$(make_input "PASSWORD=abc TOKEN=def some-command")"
assert_logged "PASSWORD=***REDACTED*** TOKEN=***REDACTED*** some-command" "Two secrets in one command"
teardown

# --- Edge cases ---
echo ""
echo "Edge cases:"

setup
assert_exit_zero '{}' "Empty JSON exits zero"
assert_not_logged "Empty JSON produces no log entry"
teardown

setup
assert_exit_zero '{"tool_name":"Bash","tool_input":{}}' "Missing command field exits zero"
assert_not_logged "Missing command field produces no log entry"
teardown

setup
assert_exit_zero 'not json at all' "Malformed input exits zero"
assert_not_logged "Malformed input produces no log entry"
teardown

setup
assert_exit_zero '' "Empty input exits zero"
assert_not_logged "Empty input produces no log entry"
teardown

setup
assert_exit_zero '{"tool_name":"Bash","tool_input":{"command":""}}' "Empty command exits zero"
assert_not_logged "Empty command produces no log entry"
teardown

# --- Log file permissions ---
echo ""
echo "Log file permissions:"

setup
rm -f "$TEST_LOG"  # Remove so hook creates it fresh
run_hook "$(make_input "test command")"
TESTS_RUN=$((TESTS_RUN + 1))
perms=$(stat -f "%Lp" "$TEST_LOG" 2>/dev/null || stat -c "%a" "$TEST_LOG" 2>/dev/null)
if [[ "$perms" == "600" ]]; then
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf "${GREEN}  PASS${NC} Log file created with 0600 permissions\n"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf "${RED}  FAIL${NC} Log file permissions: expected 600, got %s\n" "$perms"
fi
teardown

# --- Timestamp format ---
echo ""
echo "Log format:"

setup
run_hook "$(make_input "echo hello")"
TESTS_RUN=$((TESTS_RUN + 1))
last_line=$(tail -1 "$TEST_LOG")
if [[ "$last_line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\  ]]; then
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf "${GREEN}  PASS${NC} Log entry has ISO-8601 UTC timestamp prefix\n"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf "${RED}  FAIL${NC} Timestamp format wrong: %s\n" "$last_line"
fi
teardown

# --- Non-secret patterns that should NOT be redacted ---
echo ""
echo "False positive avoidance:"

setup
run_hook "$(make_input "grep PASSWORD_RESET_TIMEOUT config.py")"
assert_logged "grep PASSWORD_RESET_TIMEOUT config.py" "PASSWORD in variable name (no =VALUE) not redacted"
teardown

setup
run_hook "$(make_input "echo token is ready")"
assert_logged "echo token is ready" "Word 'token' without =VALUE not redacted"
teardown

# --- Case insensitive redaction ---
echo ""
echo "Case insensitive redaction:"

setup
run_hook "$(make_input "password=myvalue some-command")"
assert_logged "password=***REDACTED*** some-command" "Lowercase 'password=' is redacted"
teardown

setup
run_hook "$(make_input "Password=MyValue some-command")"
assert_logged "Password=***REDACTED*** some-command" "Mixed case 'Password=' is redacted"
teardown

setup
run_hook "$(make_input "PRIVATE_KEY=abc123 some-command")"
assert_logged "PRIVATE_KEY=***REDACTED*** some-command" "PRIVATE_KEY pattern"
teardown

setup
run_hook "$(make_input "CREDENTIAL=xyz some-command")"
assert_logged "CREDENTIAL=***REDACTED*** some-command" "CREDENTIAL pattern"
teardown

# --- Connection string / URL redaction ---
echo ""
echo "Connection string redaction:"

setup
run_hook "$(make_input "DATABASE_URL=postgres://user:pass@host/db some-command")"
assert_logged "DATABASE_URL=***REDACTED*** some-command" "DATABASE_URL with connection string"
teardown

setup
run_hook "$(make_input "REDIS_URL=redis://default:secret@cache:6379 some-command")"
assert_logged "REDIS_URL=***REDACTED*** some-command" "REDIS_URL"
teardown

setup
run_hook "$(make_input "MONGO_URI=mongodb+srv://user:pass@cluster some-command")"
assert_logged "MONGO_URI=***REDACTED*** some-command" "MONGO_URI"
teardown

setup
run_hook "$(make_input "DSN=https://key@sentry.io/123 some-command")"
assert_logged "DSN=***REDACTED*** some-command" "DSN (Sentry-style)"
teardown

setup
run_hook "$(make_input "MYSQL_PWD=rootpass mysql -u root")"
assert_logged "MYSQL_PWD=***REDACTED*** mysql -u root" "MYSQL_PWD"
teardown

# --- ERR trap: non-zero exit protection ---
echo ""
echo "ERR trap (PostToolUse exit code bug protection):"

# Test that hook exits 0 even when log file is unwritable
setup
chmod 0000 "$TEST_LOG"
TESTS_RUN=$((TESTS_RUN + 1))
run_hook "$(make_input "some command")"
code=$?
chmod 0600 "$TEST_LOG"  # restore for cleanup
if [[ $code -eq 0 ]]; then
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf "${GREEN}  PASS${NC} Exits 0 even when log file is unwritable\n"
else
  TESTS_FAILED=$((TESTS_FAILED + 1))
  printf "${RED}  FAIL${NC} Expected exit 0 with unwritable log, got %d\n" "$code"
fi
teardown

# ============================================================
echo ""
echo "=========="
printf "Results: %d passed, %d failed, %d total\n" "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_RUN"

if [[ $TESTS_FAILED -gt 0 ]]; then
  exit 1
fi
exit 0

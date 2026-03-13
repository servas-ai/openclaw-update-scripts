#!/usr/bin/env bash
set -eo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# Test Framework for openclaw-update-scripts
# ═══════════════════════════════════════════════════════════════════════════════

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_SCRIPT="$ROOT/cron/check-updates-notify.sh"
COMMON_LIB="$ROOT/lib/common.sh"

# ─── Test Framework ──────────────────────────────────────────────────────────
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0

suite() {
  echo ""
  echo "════════════════════════════════════════════"
  echo "  $1"
  echo "════════════════════════════════════════════"
  echo ""
}

pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  echo "  [PASS] $*"
}

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  echo "  [FAIL] $*" >&2
}

assert_eq() {
  if [[ "$1" == "$2" ]]; then pass "$3"; else fail "$3 (expected='$2', got='$1')"; fi
}

assert_contains() {
  if printf '%s' "$1" | grep -Fq -- "$2"; then pass "$3"; else fail "$3 (missing: '$2')"; fi
}

assert_not_contains() {
  if printf '%s' "$1" | grep -Fq -- "$2"; then fail "$3 (found unwanted: '$2')"; else pass "$3"; fi
}

assert_matches() {
  if printf '%s' "$1" | grep -Eq -- "$2"; then pass "$3"; else fail "$3 (no match: '$2')"; fi
}

assert_empty() {
  if [[ -z "$1" ]]; then pass "$2"; else fail "$2 (expected empty, got='$1')"; fi
}

assert_not_empty() {
  if [[ -n "$1" ]]; then pass "$2"; else fail "$2 (was empty)"; fi
}

# ─── Mock Setup ──────────────────────────────────────────────────────────────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
BIN_DIR="$TMP_DIR/bin"
MOCK_DATA="$TMP_DIR/mock-data"
mkdir -p "$BIN_DIR" "$MOCK_DATA"

# Write mock data files and a generic npm mock that reads from them
setup_mocks() {
  local npm_ls_json="$1"       # JSON for npm ls -g
  local versions_json="$2"     # JSON map: {"pkg":"ver","pkg2":"ver2"} for npm view ... version
  local descriptions_json="$3" # JSON map: {"pkg":"desc"} for npm view ... description
  local config_valid="${4:-0}"
  local oc_latest="${5:-}"
  local releases_json="${6:-[]}"
  local ai_response="${7:-}"

  echo "$npm_ls_json" > "$MOCK_DATA/npm-ls.json"
  echo "$versions_json" > "$MOCK_DATA/npm-versions.json"
  echo "$descriptions_json" > "$MOCK_DATA/npm-descriptions.json"
  echo "$releases_json" > "$MOCK_DATA/releases.json"
  echo "$config_valid" > "$MOCK_DATA/config-valid.txt"
  echo "$oc_latest" > "$MOCK_DATA/oc-latest.txt"
  printf '%s' "$ai_response" > "$MOCK_DATA/ai-response.txt"

  # npm mock — use direct heredoc with var expansion, escape $* $args etc.
  cat > "$BIN_DIR/npm" <<MOCK_NPM
#!/usr/bin/env bash
args="\$*"

if [[ "\$args" == *"ls -g"* && "\$args" == *"--json"* ]]; then
  cat "$MOCK_DATA/npm-ls.json"
  exit 0
fi

if [[ "\$args" == *"view"* && "\$args" == *" version"* && "\$args" != *"versions"* ]]; then
  for pkg in \$(jq -r 'keys[]' "$MOCK_DATA/npm-versions.json" 2>/dev/null); do
    if [[ "\$args" == *"\$pkg"* ]]; then
      jq -r --arg p "\$pkg" '.[\$p] // empty' "$MOCK_DATA/npm-versions.json" 2>/dev/null
      exit 0
    fi
  done
  exit 0
fi

if [[ "\$args" == *"description"* ]]; then
  for pkg in \$(jq -r 'keys[]' "$MOCK_DATA/npm-descriptions.json" 2>/dev/null); do
    if [[ "\$args" == *"\$pkg"* ]]; then
      jq -r --arg p "\$pkg" '.[\$p] // empty' "$MOCK_DATA/npm-descriptions.json" 2>/dev/null
      exit 0
    fi
  done
  exit 0
fi

if [[ "\$args" == *"versions --json"* ]]; then echo '[]'; exit 0; fi
if [[ "\$args" == *"repository"* ]]; then echo ''; exit 0; fi
exit 0
MOCK_NPM

  # openclaw mock
  cat > "$BIN_DIR/openclaw" <<MOCK_OC
#!/usr/bin/env bash
if [[ "\$1" == "config" && "\$2" == "validate" ]]; then
  cv=\$(cat "$MOCK_DATA/config-valid.txt")
  if [[ "\$cv" == "1" ]]; then exit 0; else echo "invalid config" >&2; exit 1; fi
fi
if [[ "\$1" == "update" && "\$2" == "status" ]]; then
  latest=\$(cat "$MOCK_DATA/oc-latest.txt")
  echo "{\"update\":{\"registry\":{\"latestVersion\":\"\$latest\"}}}"
  exit 0
fi
if [[ "\$1" == "message" && "\$2" == "send" ]]; then
  echo "\$@" >> "$MOCK_DATA/sent-messages.log"
  exit 0
fi
if [[ "\$1" == "agent" ]]; then
  resp=\$(cat "$MOCK_DATA/ai-response.txt")
  if [[ -n "\$resp" ]]; then
    echo "\$resp"
    exit 0
  fi
  exit 1
fi
if [[ "\$1" == "--version" ]]; then echo "OpenClaw 2026.3.11 (mock)"; exit 0; fi
exit 0
MOCK_OC

  # curl mock
  cat > "$BIN_DIR/curl" <<MOCK_CURL
#!/usr/bin/env bash
if [[ "\$*" == *"/repos/"*"/releases"* ]]; then
  cat "$MOCK_DATA/releases.json"
  exit 0
fi
exit 22
MOCK_CURL

  chmod +x "$BIN_DIR/npm" "$BIN_DIR/openclaw" "$BIN_DIR/curl"
}

run_check() {
  local wl_file="$1"
  local state="$TMP_DIR/.state-$RANDOM.json"
  local out="$TMP_DIR/out-$RANDOM.txt"
  local err="$TMP_DIR/err-$RANDOM.txt"

  PATH="$BIN_DIR:$PATH" \
  DRY_RUN=1 FORCE_NOTIFY="${2:-1}" SAFE_RUN_LOGIN=0 \
  WATCHLIST_FILE="$wl_file" STATE_FILE="$state" \
  OPENCLAW_BIN="$BIN_DIR/openclaw" SAFE_TIMEOUT_SEC=5 \
  AUTO_HEAL_ENABLED=0 \
  bash "$TARGET_SCRIPT" >"$out" 2>"$err" || true

  _OUT="$(cat "$out")"
  _ERR="$(cat "$err")"
  _STATE_FILE="$state"
}

make_watchlist() {
  local wl="$TMP_DIR/wl-$RANDOM.json"
  local npm_arr="[]"
  if [[ -n "${1:-}" ]]; then
    npm_arr="[$(echo "$1" | sed 's/[^,]*/"&"/g')]"
  fi
  echo "{\"npm\":$npm_arr,\"snap\":[],\"go\":[]}" > "$wl"
  echo "$wl"
}


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 1: Unit Tests — version_gt / version_lte
# ═══════════════════════════════════════════════════════════════════════════════
suite "Unit Tests: version_gt / version_lte"
(
  export PATH="$BIN_DIR:$PATH" SAFE_RUN_LOGIN=0 OPENCLAW_BIN="$BIN_DIR/openclaw"
  setup_mocks '{"dependencies":{}}' '{}' '{}' 0
  source "$COMMON_LIB"

  if version_gt "2.0.0" "1.0.0"; then pass "2.0.0 > 1.0.0"; else fail "2.0.0 > 1.0.0"; fi
  if version_gt "1.0.1" "1.0.0"; then pass "1.0.1 > 1.0.0"; else fail "1.0.1 > 1.0.0"; fi
  if version_gt "10.0.0" "9.99.99"; then pass "10.0.0 > 9.99.99"; else fail "10.0.0 > 9.99.99"; fi
  if version_gt "2026.3.11" "2026.3.2"; then pass "2026.3.11 > 2026.3.2"; else fail "2026.3.11 > 2026.3.2"; fi
  if version_gt "1.0.0" "1.0.0"; then fail "equal versions"; else pass "1.0.0 NOT > 1.0.0"; fi
  if version_gt "1.0.0" "2.0.0"; then fail "lower version"; else pass "1.0.0 NOT > 2.0.0"; fi
  if version_gt "0.9.0" "0.10.0"; then fail "0.9 vs 0.10"; else pass "0.9.0 NOT > 0.10.0"; fi
  if version_lte "1.0.0" "2.0.0"; then pass "1.0.0 <= 2.0.0"; else fail "1.0.0 <= 2.0.0"; fi
  if version_lte "1.0.0" "1.0.0"; then pass "1.0.0 <= 1.0.0"; else fail "equal lte"; fi
  if version_lte "2.0.0" "1.0.0"; then fail "2.0 lte 1.0"; else pass "2.0.0 NOT <= 1.0.0"; fi
)


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 2: Unit Tests — String helpers
# ═══════════════════════════════════════════════════════════════════════════════
suite "Unit Tests: String helpers"
(
  export PATH="$BIN_DIR:$PATH" SAFE_RUN_LOGIN=0 OPENCLAW_BIN="$BIN_DIR/openclaw"
  setup_mocks '{"dependencies":{}}' '{}' '{}' 0
  source "$COMMON_LIB"

  # json_escape
  assert_eq "$(json_escape 'hello "world"')" 'hello \"world\"' "json_escape: quotes"
  assert_eq "$(json_escape 'back\slash')" 'back\\slash' "json_escape: backslash"
  assert_eq "$(json_escape $'line1\nline2')" 'line1\nline2' "json_escape: newlines"
  assert_eq "$(json_escape '')" '' "json_escape: empty string"
  assert_eq "$(json_escape 'no special chars')" 'no special chars' "json_escape: passthrough"

  # normalize_version
  assert_eq "$(normalize_version 'v1.2.3')" '1.2.3' "normalize_version: strips v"
  assert_eq "$(normalize_version 'V1.2.3')" '1.2.3' "normalize_version: strips V"
  assert_eq "$(normalize_version '1.2.3')" '1.2.3' "normalize_version: no prefix"
  assert_eq "$(normalize_version 'some/path/v4.0.0')" '4.0.0' "normalize_version: path + v"
  assert_eq "$(normalize_version '@scope/pkg@2.0.0')" '2.0.0' "normalize_version: scope"

  # shorten_line
  long_str=$(printf '%0.s.' {1..300})
  result=$(shorten_line "$long_str")
  [[ ${#result} -le 240 ]] && pass "shorten_line: truncates ≤240" || fail "shorten_line: ${#result} chars"
  assert_eq "$(shorten_line 'short')" 'short' "shorten_line: passthrough"
  assert_eq "$(shorten_line $'line1\nline2')" 'line1 line2' "shorten_line: newlines"
)


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 3: Unit Tests — npm version lookups
# ═══════════════════════════════════════════════════════════════════════════════
suite "Unit Tests: npm version lookups"
(
  export PATH="$BIN_DIR:$PATH" SAFE_RUN_LOGIN=0 OPENCLAW_BIN="$BIN_DIR/openclaw"
  setup_mocks \
    '{"dependencies":{"simple-pkg":{"version":"1.0.0"},"@scope/deep":{"version":"3.5.0"},"@org/nested":{"version":"0.1.0"},"openclaw":{"version":"2026.3.2"}}}' \
    '{"simple-pkg":"1.2.0","@scope/deep":"4.0.0","@org/nested":"0.2.0","openclaw":"2026.3.11"}' \
    '{}' 0
  source "$COMMON_LIB"

  assert_eq "$(npm_global_current_version 'simple-pkg')" '1.0.0' "current: simple-pkg"
  assert_eq "$(npm_global_current_version '@scope/deep')" '3.5.0' "current: @scope/deep"
  assert_eq "$(npm_global_current_version '@org/nested')" '0.1.0' "current: @org/nested"
  assert_eq "$(npm_global_current_version 'openclaw')" '2026.3.2' "current: openclaw"
  assert_empty "$(npm_global_current_version 'missing')" "current: missing → empty"
  assert_eq "$(npm_latest_version 'simple-pkg')" '1.2.0' "latest: simple-pkg"
  assert_eq "$(npm_latest_version '@scope/deep')" '4.0.0' "latest: @scope/deep"
)


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 4: Unit Tests — Update command resolver
# ═══════════════════════════════════════════════════════════════════════════════
suite "Unit Tests: get_update_command / get_update_key"
(
  export PATH="$BIN_DIR:$PATH" SAFE_RUN_LOGIN=0 OPENCLAW_BIN="/usr/bin/openclaw"
  setup_mocks '{"dependencies":{}}' '{}' '{}' 0
  source "$COMMON_LIB"

  assert_contains "$(get_update_command 'openclaw')" 'update --channel stable --yes' "cmd: openclaw"
  assert_eq "$(get_update_command '@kaitranntt/ccs')" 'ccs update' "cmd: ccs"
  assert_eq "$(get_update_command 'opencode-ai')" 'opencode upgrade' "cmd: opencode-ai"
  assert_contains "$(get_update_command 'random')" "npm install -g" "cmd: generic npm"
  assert_contains "$(get_update_command '@scope/pkg')" "npm install -g" "cmd: scoped generic"
  assert_not_contains "$(get_update_key '@scope/pkg')" '/' "key: no slashes"
  assert_not_contains "$(get_update_key '@scope/pkg')" ' ' "key: no spaces"
)


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 5: Integration — No updates (quiet exit)
# ═══════════════════════════════════════════════════════════════════════════════
suite "Integration: No updates available"

setup_mocks \
  '{"dependencies":{"up-to-date":{"version":"5.0.0"},"openclaw":{"version":"99.0.0"}}}' \
  '{"up-to-date":"5.0.0","openclaw":"99.0.0"}' \
  '{}' 0
wl="$(make_watchlist 'up-to-date')"
run_check "$wl"
assert_empty "$_OUT" "no updates: silent"


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 6: Integration — Single update
# ═══════════════════════════════════════════════════════════════════════════════
suite "Integration: Single update"

setup_mocks \
  '{"dependencies":{"single":{"version":"1.0.0"},"openclaw":{"version":"99.0.0"}}}' \
  '{"single":"2.0.0","openclaw":"99.0.0"}' \
  '{"single":"A single package"}' 0
wl="$(make_watchlist 'single')"
run_check "$wl"
assert_contains "$_OUT" "1 Update(s)" "single: count=1"
assert_contains "$_OUT" "single: 1.0.0 → 2.0.0" "single: version line"
assert_contains "$_OUT" "Ja, updaten" "single: yes button"
assert_not_contains "$_OUT" "Alle updaten" "single: no 'alle' for single"


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 7: Integration — Multiple scoped packages (Bug Fix #2)
# ═══════════════════════════════════════════════════════════════════════════════
suite "Integration: Multiple scoped packages (Bug Fix #2)"

setup_mocks \
  '{"dependencies":{"@a/x":{"version":"1.0.0"},"@b/y":{"version":"2.0.0"},"@c/z":{"version":"3.0.0"},"openclaw":{"version":"99.0.0"}}}' \
  '{"@a/x":"1.5.0","@b/y":"2.5.0","@c/z":"3.5.0","openclaw":"99.0.0"}' \
  '{"@a/x":"Pkg A","@b/y":"Pkg B","@c/z":"Pkg C"}' 0
wl="$(make_watchlist '@a/x,@b/y,@c/z')"
run_check "$wl"
assert_contains "$_OUT" "3 Update(s)" "scoped: count=3"
assert_contains "$_OUT" "@a/x: 1.0.0 → 1.5.0" "scoped: @a/x"
assert_contains "$_OUT" "@b/y: 2.0.0 → 2.5.0" "scoped: @b/y"
assert_contains "$_OUT" "@c/z: 3.0.0 → 3.5.0" "scoped: @c/z"
assert_not_contains "$_OUT" "Version lookup failed" "scoped: no lookup failures"
assert_not_contains "$_ERR" "Version lookup failed" "scoped: no stderr failures"
assert_contains "$_OUT" "Alle updaten" "scoped: 'alle' for multi"


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 8: Integration — Version lookup failures
# ═══════════════════════════════════════════════════════════════════════════════
suite "Integration: Version lookup failures"

setup_mocks \
  '{"dependencies":{"known":{"version":"1.0.0"},"openclaw":{"version":"99.0.0"}}}' \
  '{"known":"1.5.0","openclaw":"99.0.0"}' \
  '{"known":"Known pkg"}' 0
wl="$(make_watchlist 'known,ghost')"
run_check "$wl"
assert_contains "$_OUT" "known: 1.0.0 → 1.5.0" "known pkg detected"
assert_contains "$_OUT" "Version lookup failed for ghost" "ghost failure reported"
assert_contains "$_OUT" "Hinweise" "warnings section present"


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 9: Integration — Dedup (same payload = quiet)
# ═══════════════════════════════════════════════════════════════════════════════
suite "Integration: Dedup logic"

setup_mocks \
  '{"dependencies":{"dup":{"version":"1.0.0"},"openclaw":{"version":"99.0.0"}}}' \
  '{"dup":"2.0.0","openclaw":"99.0.0"}' \
  '{}' 0
wl="$(make_watchlist 'dup')"
dedup_state="$TMP_DIR/.dedup-state.json"

# First run
PATH="$BIN_DIR:$PATH" DRY_RUN=1 FORCE_NOTIFY=0 SAFE_RUN_LOGIN=0 \
WATCHLIST_FILE="$wl" STATE_FILE="$dedup_state" \
OPENCLAW_BIN="$BIN_DIR/openclaw" SAFE_TIMEOUT_SEC=5 AUTO_HEAL_ENABLED=0 \
bash "$TARGET_SCRIPT" >"$TMP_DIR/d1.txt" 2>/dev/null || true

# Second run (same state → silent)
PATH="$BIN_DIR:$PATH" DRY_RUN=1 FORCE_NOTIFY=0 SAFE_RUN_LOGIN=0 \
WATCHLIST_FILE="$wl" STATE_FILE="$dedup_state" \
OPENCLAW_BIN="$BIN_DIR/openclaw" SAFE_TIMEOUT_SEC=5 AUTO_HEAL_ENABLED=0 \
bash "$TARGET_SCRIPT" >"$TMP_DIR/d2.txt" 2>/dev/null || true

assert_not_empty "$(cat "$TMP_DIR/d1.txt")" "dedup: first run has output"
assert_empty "$(cat "$TMP_DIR/d2.txt")" "dedup: second run is silent"


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 10: Integration — FORCE_NOTIFY bypasses dedup
# ═══════════════════════════════════════════════════════════════════════════════
suite "Integration: FORCE_NOTIFY bypasses dedup"

PATH="$BIN_DIR:$PATH" DRY_RUN=1 FORCE_NOTIFY=1 SAFE_RUN_LOGIN=0 \
WATCHLIST_FILE="$wl" STATE_FILE="$dedup_state" \
OPENCLAW_BIN="$BIN_DIR/openclaw" SAFE_TIMEOUT_SEC=5 AUTO_HEAL_ENABLED=0 \
bash "$TARGET_SCRIPT" >"$TMP_DIR/d3.txt" 2>/dev/null || true

assert_not_empty "$(cat "$TMP_DIR/d3.txt")" "force: output despite same state"


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 11: Integration — Empty watchlist
# ═══════════════════════════════════════════════════════════════════════════════
suite "Integration: Empty watchlist"

setup_mocks '{"dependencies":{}}' '{}' '{}' 0
wl="$(make_watchlist '')"
run_check "$wl"
assert_empty "$_OUT" "empty watchlist: no output"


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 12: Integration — OpenClaw native version lookup
# ═══════════════════════════════════════════════════════════════════════════════
suite "Integration: OpenClaw native version lookup"

setup_mocks \
  '{"dependencies":{"openclaw":{"version":"2026.3.2"}}}' \
  '{"openclaw":"2026.3.11"}' \
  '{}' 1 "2026.3.11"
wl="$(make_watchlist 'openclaw')"
run_check "$wl"
assert_contains "$_OUT" "openclaw: 2026.3.2 → 2026.3.11" "openclaw update detected"
assert_not_contains "$_OUT" "config invalid" "no config warning"


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 13: Integration — Button JSON validation
# ═══════════════════════════════════════════════════════════════════════════════
suite "Integration: Telegram button JSON"

setup_mocks \
  '{"dependencies":{"a":{"version":"1.0.0"},"b":{"version":"2.0.0"},"openclaw":{"version":"99.0.0"}}}' \
  '{"a":"1.1.0","b":"2.1.0","openclaw":"99.0.0"}' \
  '{}' 0
wl="$(make_watchlist 'a,b')"
run_check "$wl"

buttons="$(echo "$_OUT" | sed -n '/---BUTTONS---/,$ p' | tail -n +2)"
assert_not_empty "$buttons" "buttons: present"
assert_contains "$buttons" "update_all_yes" "buttons: all-yes callback"
assert_contains "$buttons" "update_all_no" "buttons: all-no callback"
assert_contains "$buttons" "update_single_a" "buttons: per-pkg callback a"
assert_contains "$buttons" "update_single_b" "buttons: per-pkg callback b"

if echo "$buttons" | jq . >/dev/null 2>&1; then
  pass "buttons: valid JSON"
else
  fail "buttons: invalid JSON"
fi


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 14: Integration — Config invalid warning
# ═══════════════════════════════════════════════════════════════════════════════
suite "Integration: Config invalid warning"

setup_mocks \
  '{"dependencies":{"w":{"version":"1.0.0"},"openclaw":{"version":"99.0.0"}}}' \
  '{"w":"1.1.0","openclaw":"99.0.0"}' \
  '{}' 0   # config INVALID
wl="$(make_watchlist 'w')"
run_check "$wl"
assert_contains "$_OUT" "Hinweise" "config: warnings section"
assert_contains "$_OUT" "config invalid" "config: warning in message"
assert_contains "$_ERR" "WARN" "config: WARN in stderr"


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 15: Unit Tests — Messaging
# ═══════════════════════════════════════════════════════════════════════════════
suite "Unit Tests: Messaging functions"
(
  export PATH="$BIN_DIR:$PATH" SAFE_RUN_LOGIN=0
  export OPENCLAW_BIN="$BIN_DIR/openclaw"
  export CHANNEL="telegram" CHAT_ID="-123" THREAD_ID="42"
  setup_mocks '{"dependencies":{}}' '{}' '{}' 0
  rm -f "$MOCK_DATA/sent-messages.log"
  source "$COMMON_LIB"

  send_message "Hello test" "" "telegram" && pass "send_message: succeeds" || fail "send_message: failed"

  if [[ -f "$MOCK_DATA/sent-messages.log" ]]; then
    log="$(cat "$MOCK_DATA/sent-messages.log")"
    assert_contains "$log" "Hello test" "msg: content passed"
    assert_contains "$log" "--channel telegram" "msg: channel flag"
    assert_contains "$log" "--target -123" "msg: target"
    assert_contains "$log" "--thread-id 42" "msg: thread-id"
  else
    fail "send_message: no log"
  fi

  rm -f "$MOCK_DATA/sent-messages.log"
  CHANNEL="both" send_to_all_channels "dual msg" ""
  if [[ -f "$MOCK_DATA/sent-messages.log" ]]; then
    lines=$(wc -l < "$MOCK_DATA/sent-messages.log")
    [[ "$lines" -ge 2 ]] && pass "both: 2 messages" || fail "both: got $lines"
  else
    fail "both: no log"
  fi
)


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 16: UI Format — Message structure
# ═══════════════════════════════════════════════════════════════════════════════
suite "UI Format: Message structure"

setup_mocks \
  '{"dependencies":{"ui":{"version":"1.0.0"},"openclaw":{"version":"99.0.0"}}}' \
  '{"ui":"2.0.0","openclaw":"99.0.0"}' \
  '{"ui":"A nice package"}' 0
wl="$(make_watchlist 'ui')"
run_check "$wl"
assert_contains "$_OUT" "🔔" "ui: bell emoji"
assert_contains "$_OUT" "━" "ui: separator"
assert_contains "$_OUT" "📦" "ui: package emoji"
assert_contains "$_OUT" "📋" "ui: changelog emoji"
assert_contains "$_OUT" "Soll i updaten?" "ui: CTA"
assert_matches "$_OUT" "[0-9][0-9]\.[0-9][0-9]\.[0-9]" "ui: date present"


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 17: Unit Tests — vibe-kanban update command fix
# ═══════════════════════════════════════════════════════════════════════════════
suite "Unit Tests: vibe-kanban update command (Bug Fix)"
(
  export PATH="$BIN_DIR:$PATH" SAFE_RUN_LOGIN=0 OPENCLAW_BIN="/usr/bin/openclaw"
  setup_mocks '{"dependencies":{}}' '{}' '{}' 0
  source "$COMMON_LIB"

  cmd="$(get_update_command 'vibe-kanban')"
  assert_contains "$cmd" "npm install -g" "vibe-kanban: uses npm install -g"
  assert_contains "$cmd" "vibe-kanban@latest" "vibe-kanban: targets @latest"
  assert_not_contains "$cmd" "npx" "vibe-kanban: no npx"
  assert_not_contains "$cmd" "--help" "vibe-kanban: no --help"
)


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 18: Unit Tests — discover_new_global_npm_packages
# ═══════════════════════════════════════════════════════════════════════════════
suite "Unit Tests: discover_new_global_npm_packages"
(
  export PATH="$BIN_DIR:$PATH" SAFE_RUN_LOGIN=0 OPENCLAW_BIN="$BIN_DIR/openclaw"
  # npm ls returns 3 packages, but watchlist only has "known"
  setup_mocks \
    '{"dependencies":{"known":{"version":"1.0.0"},"new-pkg":{"version":"2.0.0"},"another-new":{"version":"3.0.0"}}}' \
    '{}' '{}' 0
  source "$COMMON_LIB"

  wl_file="$TMP_DIR/disc-wl.json"
  echo '{"npm":["known"],"npm_exclude":[],"snap":[],"go":[]}' > "$wl_file"

  new="$(discover_new_global_npm_packages "$wl_file")"
  assert_contains "$new" "new-pkg" "discover: finds new-pkg"
  assert_contains "$new" "another-new" "discover: finds another-new"
  assert_not_contains "$new" "known" "discover: skips known"

  # Test npm_exclude
  echo '{"npm":["known"],"npm_exclude":["new-pkg"],"snap":[],"go":[]}' > "$wl_file"
  new2="$(discover_new_global_npm_packages "$wl_file")"
  assert_not_contains "$new2" "new-pkg" "discover: respects npm_exclude"
  assert_contains "$new2" "another-new" "discover: non-excluded still found"
)


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 19: Unit Tests — sync_watchlist_npm
# ═══════════════════════════════════════════════════════════════════════════════
suite "Unit Tests: sync_watchlist_npm"
(
  export PATH="$BIN_DIR:$PATH" SAFE_RUN_LOGIN=0 OPENCLAW_BIN="$BIN_DIR/openclaw"
  setup_mocks \
    '{"dependencies":{"existing":{"version":"1.0.0"},"brand-new":{"version":"0.5.0"}}}' \
    '{}' '{}' 0
  source "$COMMON_LIB"

  wl_file="$TMP_DIR/sync-wl.json"
  echo '{"npm":["existing"],"npm_exclude":[],"snap":[],"go":[]}' > "$wl_file"

  count="$(sync_watchlist_npm "$wl_file")"
  assert_eq "$count" "1" "sync: added 1 package"

  wl_content="$(cat "$wl_file")"
  assert_contains "$wl_content" "brand-new" "sync: brand-new in watchlist"
  assert_contains "$wl_content" "existing" "sync: existing preserved"

  # Idempotent: running again should add 0
  count2="$(sync_watchlist_npm "$wl_file")"
  assert_eq "$count2" "0" "sync: idempotent (0 new on re-run)"
)


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 20: Integration — Auto-discovery during check-updates
# ═══════════════════════════════════════════════════════════════════════════════
suite "Integration: Auto-discovery of new global packages"

# npm has "tracked" (in watchlist) + "freshly-installed" (not in watchlist)
# Both have updates available
setup_mocks \
  '{"dependencies":{"tracked":{"version":"1.0.0"},"freshly-installed":{"version":"0.1.0"},"openclaw":{"version":"99.0.0"}}}' \
  '{"tracked":"1.5.0","freshly-installed":"0.2.0","openclaw":"99.0.0"}' \
  '{"tracked":"Tracked pkg","freshly-installed":"Fresh pkg"}' 0

# Watchlist only has "tracked" — "freshly-installed" should be auto-discovered
wl="$TMP_DIR/wl-autodiscovery.json"
echo '{"npm":["tracked"],"npm_exclude":[],"snap":[],"go":[]}' > "$wl"

PATH="$BIN_DIR:$PATH" DRY_RUN=1 FORCE_NOTIFY=1 SAFE_RUN_LOGIN=0 \
WATCHLIST_FILE="$wl" STATE_FILE="$TMP_DIR/.state-auto.json" \
OPENCLAW_BIN="$BIN_DIR/openclaw" SAFE_TIMEOUT_SEC=5 AUTO_HEAL_ENABLED=0 \
bash "$TARGET_SCRIPT" >"$TMP_DIR/auto-out.txt" 2>"$TMP_DIR/auto-err.txt" || true

_AUTO_OUT="$(cat "$TMP_DIR/auto-out.txt")"
assert_contains "$_AUTO_OUT" "tracked: 1.0.0 → 1.5.0" "autodiscovery: tracked pkg still detected"
assert_contains "$_AUTO_OUT" "freshly-installed: 0.1.0 → 0.2.0" "autodiscovery: new pkg auto-discovered and checked"


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 21: Unit Tests — AI-powered changelog summarization
# ═══════════════════════════════════════════════════════════════════════════════
suite "Unit Tests: AI changelog summarization"
(
  export PATH="$BIN_DIR:$PATH" SAFE_RUN_LOGIN=0 OPENCLAW_BIN="$BIN_DIR/openclaw"
  AI_MOCK_RESPONSE=$'Neue API für Plugin-Verwaltung hinzugefügt\nBugfix bei der Konfigurationsvalidierung\nPerformance-Verbesserungen beim Start'
  setup_mocks \
    '{"dependencies":{"ai-test":{"version":"1.0.0"}}}' \
    '{"ai-test":"2.0.0"}' \
    '{"ai-test":"Test package"}' 0 '' '[]' "$AI_MOCK_RESPONSE"
  source "$COMMON_LIB"

  # Test: AI summarization enabled and returns 3 points
  AI_SUMMARIZE=1
  _ai_pts=()
  raw="Package ai-test 1.0.0 to 2.0.0. New plugin API. Bugfix config. Faster startup."
  if ai_summarize_changelog "ai-test" "1.0.0" "2.0.0" "$raw" _ai_pts; then
    pass "ai_summarize: succeeds when enabled"
  else
    fail "ai_summarize: should succeed"
  fi
  assert_not_empty "${_ai_pts[0]:-}" "ai_summarize: point 1 present"
  assert_not_empty "${_ai_pts[1]:-}" "ai_summarize: point 2 present"
  assert_not_empty "${_ai_pts[2]:-}" "ai_summarize: point 3 present"
  assert_contains "${_ai_pts[0]}" "Plugin" "ai_summarize: point 1 relevant"

  # Test: AI disabled fallback
  AI_SUMMARIZE=0
  _ai_pts2=()
  if ai_summarize_changelog "ai-test" "1.0.0" "2.0.0" "$raw" _ai_pts2; then
    fail "ai_summarize: should fail when disabled"
  else
    pass "ai_summarize: correctly skipped when disabled"
  fi

  # Test: build_raw_points fallback works
  _raw_pts=()
  build_raw_points "ai-test" "1.0.0" "2.0.0" _raw_pts
  [[ "${#_raw_pts[@]}" -ge 1 ]] && pass "build_raw_points: returns points" || fail "build_raw_points: empty"
)


# ═══════════════════════════════════════════════════════════════════════════════
# SUITE 22: Integration — AI summary in check-updates output
# ═══════════════════════════════════════════════════════════════════════════════
suite "Integration: AI summary in check-updates output"

AI_MOCK_RESP=$'Neues Authentifizierungssystem eingebaut\nBugfix für Login-Probleme\nDokumentation aktualisiert'
setup_mocks \
  '{"dependencies":{"ai-pkg":{"version":"1.0.0"},"openclaw":{"version":"99.0.0"}}}' \
  '{"ai-pkg":"2.0.0","openclaw":"99.0.0"}' \
  '{"ai-pkg":"AI test"}' 0 '' '[]' "$AI_MOCK_RESP"

wl="$TMP_DIR/wl-ai-int.json"
echo '{"npm":["ai-pkg"],"npm_exclude":[],"snap":[],"go":[]}' > "$wl"

PATH="$BIN_DIR:$PATH" DRY_RUN=1 FORCE_NOTIFY=1 SAFE_RUN_LOGIN=0 \
AI_SUMMARIZE=1 AI_SUMMARIZE_TIMEOUT=5 \
WATCHLIST_FILE="$wl" STATE_FILE="$TMP_DIR/.state-ai.json" \
OPENCLAW_BIN="$BIN_DIR/openclaw" SAFE_TIMEOUT_SEC=5 AUTO_HEAL_ENABLED=0 \
bash "$TARGET_SCRIPT" >"$TMP_DIR/ai-int-out.txt" 2>"$TMP_DIR/ai-int-err.txt" || true

_AI_INT_OUT="$(cat "$TMP_DIR/ai-int-out.txt")"
assert_contains "$_AI_INT_OUT" "ai-pkg: 1.0.0 → 2.0.0" "ai-int: package detected"
assert_contains "$_AI_INT_OUT" "Authentifizierungssystem" "ai-int: AI summary point 1 in output"


# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
  echo "  ✅ ALL TESTS PASSED: $TESTS_PASSED/$TESTS_TOTAL"
else
  echo "  ❌ TESTS: $TESTS_PASSED passed, $TESTS_FAILED FAILED (of $TESTS_TOTAL)"
fi
echo "═══════════════════════════════════════════════════"
echo ""
exit "$TESTS_FAILED"

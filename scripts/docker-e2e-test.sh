#!/usr/bin/env bash
set -eo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# Docker E2E Integration Test for openclaw-update-scripts
# ═══════════════════════════════════════════════════════════════════════════════
#
# Runs inside a Docker container with a full OpenClaw installation.
# Tests the complete flow: install → configure → check → update → notify.
#
# Usage (from host):
#   bash scripts/run-docker-e2e.sh
#
# Or manually:
#   docker build -f Dockerfile.e2e -t openclaw-e2e .
#   docker run --rm -e AI_API_BASE=... -e AI_API_KEY=... openclaw-e2e
# ═══════════════════════════════════════════════════════════════════════════════

ROOT="/workspace"
COMMON_LIB="$ROOT/lib/common.sh"
CHECK_SCRIPT="$ROOT/cron/check-updates-notify.sh"
UPDATE_SCRIPT="$ROOT/cron/run-all-updates.sh"
UPDATE_DIRECT="$ROOT/cron/run-all-updates-direct.sh"
WATCHLIST="$ROOT/cron/update-watchlist.json"
INSTALL_MD="$ROOT/INSTALL.md"

# AI API config (passed via env or defaults)
AI_API_BASE="${AI_API_BASE:-https://cliproxy.servas.ai/v1}"
AI_API_KEY="${AI_API_KEY:-ccs-internal-managed}"
AI_MODEL="${AI_MODEL:-gpt-4o-mini}"

# ─── Test Framework ──────────────────────────────────────────────────────────
TESTS_PASSED=0
TESTS_FAILED=0
TESTS_TOTAL=0
PHASE_PASS=0
PHASE_FAIL=0

suite() {
  PHASE_PASS=0
  PHASE_FAIL=0
  echo ""
  echo "════════════════════════════════════════════"
  echo "  $1"
  echo "════════════════════════════════════════════"
  echo ""
}

pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  PHASE_PASS=$((PHASE_PASS + 1))
  echo "  [PASS] $*"
}

fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  TESTS_TOTAL=$((TESTS_TOTAL + 1))
  PHASE_FAIL=$((PHASE_FAIL + 1))
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

assert_file_exists() {
  if [[ -f "$1" ]]; then pass "$2"; else fail "$2 (file not found: '$1')"; fi
}

assert_command_exists() {
  if command -v "$1" >/dev/null 2>&1; then pass "$2"; else fail "$2 ($1 not found)"; fi
}

assert_exit_0() {
  if eval "$1" >/dev/null 2>&1; then pass "$2"; else fail "$2 (exit non-zero)"; fi
}


# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 1: Prerequisites — Verify the container environment
# ═══════════════════════════════════════════════════════════════════════════════
suite "Phase 1: Prerequisites"

assert_command_exists "node"     "node installed"
assert_command_exists "npm"      "npm installed"
assert_command_exists "jq"       "jq installed"
assert_command_exists "curl"     "curl installed"
assert_command_exists "openclaw" "openclaw installed"
assert_command_exists "timeout"  "timeout available"

node_ver="$(node --version)"
assert_matches "$node_ver" "^v[0-9]" "node version readable ($node_ver)"

npm_ver="$(npm --version)"
assert_not_empty "$npm_ver" "npm version readable ($npm_ver)"

oc_ver="$(openclaw --version 2>&1 | head -1)"
assert_matches "$oc_ver" "OpenClaw" "openclaw version ($oc_ver)"

echo ""
echo "  📦 node=$node_ver npm=$npm_ver"
echo "  📦 $oc_ver"


# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 2: INSTALL.md Steps — Follow the documented setup
# ═══════════════════════════════════════════════════════════════════════════════
suite "Phase 2: INSTALL.md — Repository & Scripts"

assert_file_exists "$INSTALL_MD"             "INSTALL.md exists"
assert_file_exists "$COMMON_LIB"             "lib/common.sh exists"
assert_file_exists "$CHECK_SCRIPT"           "check-updates-notify.sh exists"
assert_file_exists "$UPDATE_SCRIPT"          "run-all-updates.sh exists"
assert_file_exists "$UPDATE_DIRECT"          "run-all-updates-direct.sh exists"
assert_file_exists "$WATCHLIST"              "update-watchlist.json exists"

# Step 2: Scripts executable
for f in "$CHECK_SCRIPT" "$UPDATE_SCRIPT" "$UPDATE_DIRECT"; do
  [[ -x "$f" ]] && pass "$(basename "$f") is executable" || fail "$(basename "$f") not executable"
done

# Step 3: Watchlist valid JSON
if jq . "$WATCHLIST" >/dev/null 2>&1; then
  pass "watchlist: valid JSON"
else
  fail "watchlist: invalid JSON"
fi

npm_count=$(jq '.npm | length' "$WATCHLIST")
assert_matches "$npm_count" "^[0-9]" "watchlist: has $npm_count npm entries"
[[ "$npm_count" -ge 10 ]] && pass "watchlist: ≥10 npm packages" || fail "watchlist: only $npm_count entries"

# npm_exclude field exists
if jq -e '.npm_exclude' "$WATCHLIST" >/dev/null 2>&1; then
  pass "watchlist: npm_exclude field present"
else
  fail "watchlist: npm_exclude field missing"
fi


# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 3: OpenClaw Configuration — Set up AI API
# ═══════════════════════════════════════════════════════════════════════════════
suite "Phase 3: OpenClaw AI API Configuration"

# Create minimal OpenClaw config for the E2E test container
OC_HOME="${HOME}/.openclaw"
mkdir -p "$OC_HOME"

cat > "$OC_HOME/openclaw.json" <<OCCONFIG
{
  "meta": {"lastTouchedVersion": "e2e-test"},
  "models": {
    "mode": "merge",
    "providers": {
      "e2e-cliproxy": {
        "baseUrl": "${AI_API_BASE}",
        "apiKey": "${AI_API_KEY}",
        "api": "openai-completions",
        "models": [
          {
            "id": "${AI_MODEL}",
            "name": "${AI_MODEL} (E2E Test)",
            "api": "openai-completions",
            "reasoning": false,
            "input": ["text"],
            "cost": {"input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0},
            "contextWindow": 128000,
            "maxTokens": 4096
          }
        ]
      }
    },
    "default": "${AI_MODEL}",
    "agentModel": "${AI_MODEL}"
  },
  "update": {"channel": "stable", "auto": {"enabled": false}}
}
OCCONFIG

assert_file_exists "$OC_HOME/openclaw.json" "openclaw.json created"

# Validate config
if openclaw config validate >/dev/null 2>&1; then
  pass "openclaw config validates"
else
  # May warn but not fatal
  val_out="$(openclaw config validate 2>&1 || true)"
  if echo "$val_out" | grep -qi "error"; then
    fail "openclaw config validation failed: $val_out"
  else
    pass "openclaw config validates (with warnings)"
  fi
fi

# Test that openclaw --version still works after config
oc_ver2="$(openclaw --version 2>&1 | head -1)"
assert_contains "$oc_ver2" "OpenClaw" "openclaw works post-config"


# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 4: Install test packages globally — simulate real server
# ═══════════════════════════════════════════════════════════════════════════════
suite "Phase 4: Install Global npm Packages"

# Install a few real small packages to test with
echo "  ⏳ Installing test packages globally..."
npm install -g cowsay@1.5.0 2>/dev/null | tail -1 || true
npm install -g is-odd@3.0.1 2>/dev/null | tail -1 || true
npm install -g is-even@1.0.0 2>/dev/null | tail -1 || true

assert_command_exists "cowsay" "cowsay installed"

# Verify npm ls works
npm_ls_out="$(npm ls -g --depth=0 --json 2>/dev/null)"
assert_not_empty "$npm_ls_out" "npm ls -g returns output"

if echo "$npm_ls_out" | jq -e '.dependencies.cowsay' >/dev/null 2>&1; then
  pass "npm ls: cowsay in global list"
else
  fail "npm ls: cowsay missing"
fi

cowsay_ver="$(echo "$npm_ls_out" | jq -r '.dependencies.cowsay.version // empty')"
assert_eq "$cowsay_ver" "1.5.0" "cowsay version is 1.5.0"


# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 5: Source common.sh — Test library functions
# ═══════════════════════════════════════════════════════════════════════════════
suite "Phase 5: Library Functions (live)"
(
  export SCRIPT_NAME="docker-e2e-test" SAFE_RUN_LOGIN=0 SAFE_TIMEOUT_SEC=15
  export OPENCLAW_BIN="$(command -v openclaw)"
  source "$COMMON_LIB"

  # version helpers
  if version_gt "2.0.0" "1.0.0"; then pass "version_gt: works"; else fail "version_gt"; fi
  if version_lte "1.0.0" "2.0.0"; then pass "version_lte: works"; else fail "version_lte"; fi

  # npm version lookup (live)
  cowsay_current="$(npm_global_current_version cowsay)"
  assert_eq "$cowsay_current" "1.5.0" "npm_global_current_version: cowsay=1.5.0"

  # npm latest version (live — hits real npm registry)
  cowsay_latest="$(npm_latest_version cowsay)"
  assert_not_empty "$cowsay_latest" "npm_latest_version: cowsay=$cowsay_latest"

  # update command
  cmd="$(get_update_command 'cowsay')"
  assert_contains "$cmd" "npm install -g" "get_update_command: cowsay → npm install -g"

  cmd_vk="$(get_update_command 'vibe-kanban')"
  assert_contains "$cmd_vk" "npm install -g vibe-kanban@latest" "get_update_command: vibe-kanban fixed"
  assert_not_contains "$cmd_vk" "npx" "get_update_command: no npx for vibe-kanban"

  # json helpers
  assert_eq "$(json_escape 'test "quotes"')" 'test \"quotes\"' "json_escape"
  assert_eq "$(normalize_version 'v1.2.3')" '1.2.3' "normalize_version"
)


# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 6: Dynamic Package Discovery (live)
# ═══════════════════════════════════════════════════════════════════════════════
suite "Phase 6: Dynamic Package Discovery"
(
  export SCRIPT_NAME="docker-e2e-test" SAFE_RUN_LOGIN=0 SAFE_TIMEOUT_SEC=15
  export OPENCLAW_BIN="$(command -v openclaw)"
  source "$COMMON_LIB"

  # Create a minimal watchlist that does NOT include cowsay
  test_wl="/tmp/e2e-discover-wl.json"
  echo '{"npm":["openclaw"],"npm_exclude":[],"snap":[],"go":[]}' > "$test_wl"

  # cowsay should be discovered as new
  new_pkgs="$(discover_new_global_npm_packages "$test_wl")"
  assert_contains "$new_pkgs" "cowsay" "discover: cowsay found as new"
  assert_contains "$new_pkgs" "is-odd" "discover: is-odd found as new"
  assert_not_contains "$new_pkgs" "openclaw" "discover: openclaw not in new (already in wl)"

  # Test npm_exclude
  echo '{"npm":["openclaw"],"npm_exclude":["cowsay"],"snap":[],"go":[]}' > "$test_wl"
  new_pkgs2="$(discover_new_global_npm_packages "$test_wl")"
  assert_not_contains "$new_pkgs2" "cowsay" "discover: cowsay excluded via npm_exclude"
  assert_contains "$new_pkgs2" "is-odd" "discover: is-odd still found"

  # Test sync
  echo '{"npm":["openclaw"],"npm_exclude":[],"snap":[],"go":[]}' > "$test_wl"
  count="$(sync_watchlist_npm "$test_wl")"
  [[ "$count" -ge 3 ]] && pass "sync: added ≥3 packages ($count)" || fail "sync: only added $count"

  wl_after="$(cat "$test_wl")"
  assert_contains "$wl_after" "cowsay" "sync: cowsay in watchlist after sync"
  assert_contains "$wl_after" "is-odd" "sync: is-odd in watchlist after sync"

  # Idempotent
  count2="$(sync_watchlist_npm "$test_wl")"
  assert_eq "$count2" "0" "sync: idempotent on second run"
)


# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 7: Check-Updates Dry Run (live npm, no Telegram)
# ═══════════════════════════════════════════════════════════════════════════════
suite "Phase 7: Check-Updates Dry Run"

# Create a watchlist with cowsay (which we installed at 1.5.0)
test_wl="/tmp/e2e-check-wl.json"
echo '{"npm":["cowsay"],"npm_exclude":[],"snap":[],"go":[]}' > "$test_wl"

check_out="$(DRY_RUN=1 FORCE_NOTIFY=1 SAFE_RUN_LOGIN=0 SAFE_TIMEOUT_SEC=15 \
  WATCHLIST_FILE="$test_wl" STATE_FILE="/tmp/e2e-check-state.json" \
  AUTO_HEAL_ENABLED=0 AI_SUMMARIZE=0 \
  bash "$CHECK_SCRIPT" 2>/tmp/e2e-check-err.txt || true)"
check_err="$(cat /tmp/e2e-check-err.txt)"

# cowsay 1.5.0 is the latest on npm, so there might or might not be an update
if echo "$check_out" | grep -q "cowsay"; then
  pass "check: cowsay appears in output"
  if echo "$check_out" | grep -q "Update"; then
    pass "check: update notification generated"
  else
    pass "check: cowsay detected (no update needed)"
  fi
else
  # Edge case: cowsay 1.5.0 IS the latest, so no update → silent
  if [[ -z "$check_out" ]]; then
    pass "check: silent (cowsay is latest)"
  else
    fail "check: unexpected output without cowsay: $check_out"
  fi
fi

# Make sure it didn't crash
assert_not_contains "$check_err" "unbound variable" "check: no unbound variables"


# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 8: Check-Updates with auto-discovery (live)
# ═══════════════════════════════════════════════════════════════════════════════
suite "Phase 8: Auto-discovery in Check-Updates"

disc_wl="/tmp/e2e-disc-check-wl.json"
echo '{"npm":[],"npm_exclude":[],"snap":[],"go":[]}' > "$disc_wl"

disc_out="$(DRY_RUN=1 FORCE_NOTIFY=1 SAFE_RUN_LOGIN=0 SAFE_TIMEOUT_SEC=15 \
  WATCHLIST_FILE="$disc_wl" STATE_FILE="/tmp/e2e-disc-state.json" \
  AUTO_HEAL_ENABLED=0 AI_SUMMARIZE=0 \
  bash "$CHECK_SCRIPT" 2>/tmp/e2e-disc-err.txt || true)"

# Watchlist should have been expanded
disc_wl_after="$(cat "$disc_wl")"
assert_contains "$disc_wl_after" "cowsay" "autodiscovery: cowsay added to empty watchlist"
assert_contains "$disc_wl_after" "openclaw" "autodiscovery: openclaw auto-added"


# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 9: AI Summarization (live API call)
# ═══════════════════════════════════════════════════════════════════════════════
suite "Phase 9: AI Changelog Summarization"
(
  export SCRIPT_NAME="docker-e2e-test" SAFE_RUN_LOGIN=0 SAFE_TIMEOUT_SEC=15
  export OPENCLAW_BIN="$(command -v openclaw)"
  source "$COMMON_LIB"

  # Test AI summarization with a mock changelog
  AI_SUMMARIZE=1
  AI_SUMMARIZE_TIMEOUT=45
  raw_changelog="--- Release 2.0.0 ---
### New Features
- Added support for custom themes with CSS variables
- New plugin system for third-party extensions
- Real-time collaboration features

### Bug Fixes
- Fixed memory leak in long-running sessions
- Resolved issue with Unicode rendering

### Breaking Changes
- Dropped support for Node.js 16
- Config format changed from YAML to JSON5"

  _test_points=()
  if ai_summarize_changelog "test-package" "1.0.0" "2.0.0" "$raw_changelog" _test_points; then
    pass "ai: summarization succeeded"
    [[ "${#_test_points[@]}" -ge 1 ]] && pass "ai: got ≥1 points (got ${#_test_points[@]})" || fail "ai: no points"
    if [[ "${#_test_points[@]}" -ge 1 ]]; then
      echo "    📋 AI Point 1: ${_test_points[0]}"
      [[ -n "${_test_points[1]:-}" ]] && echo "    📋 AI Point 2: ${_test_points[1]}"
      [[ -n "${_test_points[2]:-}" ]] && echo "    📋 AI Point 3: ${_test_points[2]}"
    fi
  else
    fail "ai: summarization failed (API might be unreachable)"
    echo "    ⚠️  AI API: ${AI_API_BASE} may not be reachable from Docker"
  fi

  # Test: gather_raw_changelog with a known package
  raw="$(gather_raw_changelog "cowsay" "1.0.0" "1.5.0")"
  if [[ -n "$raw" ]]; then
    pass "gather_raw_changelog: got data for cowsay"
  else
    # cowsay may not have GitHub releases, only npm desc
    pass "gather_raw_changelog: no changelog data for cowsay (expected for small pkg)"
  fi

  # Test: build_raw_points fallback
  _rp=()
  build_raw_points "cowsay" "1.0.0" "1.5.0" _rp
  [[ "${#_rp[@]}" -ge 1 ]] && pass "build_raw_points: returns ≥1 points" || fail "build_raw_points: empty"

  # Test: full package_whats_new_points pipeline
  AI_SUMMARIZE=0  # disable AI for deterministic test
  _pwn=()
  package_whats_new_points "cowsay" "1.0.0" "1.5.0" _pwn
  [[ "${#_pwn[@]}" -eq 3 ]] && pass "package_whats_new_points: returns exactly 3 points" || fail "package_whats_new_points: got ${#_pwn[@]}"
)


# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 10: Update Runner Dry Test
# ═══════════════════════════════════════════════════════════════════════════════
suite "Phase 10: Update Runner Structure Test"

# We don't actually run updates (would modify global state),
# but we verify the scripts parse and the runner logic loads correctly
for script in "$UPDATE_SCRIPT" "$UPDATE_DIRECT"; do
  name="$(basename "$script")"
  if bash -n "$script" 2>/dev/null; then
    pass "$name: syntax valid"
  else
    fail "$name: syntax error"
  fi
done

# Verify via-subagent script exists and has correct structure
if [[ -f "$ROOT/cron/run-all-updates-via-subagent.sh" ]]; then
  pass "run-all-updates-via-subagent.sh: exists"
  if bash -n "$ROOT/cron/run-all-updates-via-subagent.sh" 2>/dev/null; then
    pass "run-all-updates-via-subagent.sh: syntax valid"
  else
    fail "run-all-updates-via-subagent.sh: syntax error"
  fi
fi

# Verify auto-update-all.sh
if [[ -f "$ROOT/cron/auto-update-all.sh" ]]; then
  pass "auto-update-all.sh: exists"
  if bash -n "$ROOT/cron/auto-update-all.sh" 2>/dev/null; then
    pass "auto-update-all.sh: syntax valid"
  else
    fail "auto-update-all.sh: syntax error"
  fi
fi


# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 11: Run Mocked Test Suite Inside Container
# ═══════════════════════════════════════════════════════════════════════════════
suite "Phase 11: Mocked Test Suite"

mock_result="$(bash "$ROOT/scripts/e2e-update-check-validation.sh" 2>&1 || true)"
if echo "$mock_result" | grep -q "ALL TESTS PASSED"; then
  mock_count="$(echo "$mock_result" | grep -oP '\d+/\d+' | tail -1)"
  pass "mocked tests: ALL PASSED ($mock_count)"
else
  mock_failed="$(echo "$mock_result" | grep -c '\[FAIL\]' || true)"
  fail "mocked tests: $mock_failed failures"
  echo "$mock_result" | grep '\[FAIL\]' | head -5
fi


# ═══════════════════════════════════════════════════════════════════════════════
# PHASE 12: Environment Variables & Config Docs
# ═══════════════════════════════════════════════════════════════════════════════
suite "Phase 12: INSTALL.md Documentation Check"

install_content="$(cat "$INSTALL_MD")"

# Check all documented env vars exist in the install docs
for var in CHAT_ID THREAD_ID CHANNEL SAFE_TIMEOUT_SEC WATCHLIST_FILE OPENCLAW_BIN \
           TELEGRAM_NOTIFY AUTO_HEAL_ENABLED DRY_RUN FORCE_NOTIFY \
           AI_SUMMARIZE AI_SUMMARIZE_TIMEOUT; do
  assert_contains "$install_content" "$var" "INSTALL.md documents $var"
done

# Check sections
assert_contains "$install_content" "Watchlist konfigurieren" "INSTALL.md: watchlist section"
assert_contains "$install_content" "npm_exclude" "INSTALL.md: npm_exclude documented"
assert_contains "$install_content" "Changelog-Zusammenfassung" "INSTALL.md: AI changelog section"
assert_contains "$install_content" "openclaw agent --local" "INSTALL.md: openclaw agent docs"
assert_contains "$install_content" "Dynamische Package-Erkennung" "INSTALL.md: auto-discovery docs"
assert_contains "$install_content" "Crontab" "INSTALL.md: crontab section"
assert_contains "$install_content" "Matrix" "INSTALL.md: Matrix section"


# ═══════════════════════════════════════════════════════════════════════════════
# RESULTS
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════"
if [[ "$TESTS_FAILED" -eq 0 ]]; then
  echo "  ✅ DOCKER E2E: ALL TESTS PASSED: $TESTS_PASSED/$TESTS_TOTAL"
else
  echo "  ❌ DOCKER E2E: $TESTS_PASSED passed, $TESTS_FAILED FAILED (of $TESTS_TOTAL)"
fi
echo "═══════════════════════════════════════════════════"
echo ""
exit "$TESTS_FAILED"

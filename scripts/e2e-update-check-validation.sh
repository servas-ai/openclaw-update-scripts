#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_SCRIPT="$ROOT/cron/check-updates-notify.sh"
COMMON_LIB="$ROOT/lib/common.sh"

fail() {
  echo "[FAIL] $*" >&2
  exit 1
}

pass() {
  echo "[PASS] $*"
}

assert_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    pass "$msg"
  else
    echo "----- output -----" >&2
    printf '%s\n' "$haystack" >&2
    echo "------------------" >&2
    fail "$msg (missing: $needle)"
  fi
}

assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local msg="$3"
  if printf '%s' "$haystack" | grep -Fq -- "$needle"; then
    echo "----- output -----" >&2
    printf '%s\n' "$haystack" >&2
    echo "------------------" >&2
    fail "$msg (found unwanted: $needle)"
  else
    pass "$msg"
  fi
}

# ─── Setup mock environment ──────────────────────────────────────────────────
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN_DIR="$TMP_DIR/bin"
mkdir -p "$BIN_DIR"

# ─── Mock: openclaw ──────────────────────────────────────────────────────────
cat > "$BIN_DIR/openclaw" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "config" && "$2" == "validate" ]]; then
  echo "invalid config: missing profile" >&2
  exit 1
fi
if [[ "$1" == "update" && "$2" == "status" ]]; then
  echo '{"update":{"registry":{"latestVersion":""}}}'
  exit 0
fi
if [[ "$1" == "message" && "$2" == "send" ]]; then
  exit 0
fi
if [[ "$1" == "--version" ]]; then
  echo "OpenClaw 2026.3.11 (mock)"
  exit 0
fi
exit 0
EOF

# ─── Mock: npm (handles scoped packages!) ────────────────────────────────────
cat > "$BIN_DIR/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"

# npm ls -g for demo-pkg
if [[ "$args" == *"ls -g"* && "$args" == *"--depth=0 --json"* ]]; then
  # Return all mocked packages in one JSON blob
  cat <<JSON
{"dependencies":{"demo-pkg":{"version":"1.0.0"},"@scope/test-pkg":{"version":"2.0.0"},"openclaw":{"version":"0.0.1"}}}
JSON
  exit 0
fi

# npm view demo-pkg version
if [[ "$args" == *"view"* && "$args" == *"demo-pkg"* && "$args" == *" version"* && "$args" != *"versions --json"* ]]; then
  echo '1.2.0'
  exit 0
fi

# npm view @scope/test-pkg version
if [[ "$args" == *"view"* && "$args" == *"@scope/test-pkg"* && "$args" == *" version"* && "$args" != *"versions --json"* ]]; then
  echo '2.5.0'
  exit 0
fi

# npm view demo-pkg repository.url
if [[ "$args" == *"view"* && "$args" == *"demo-pkg"* && "$args" == *"repository.url"* ]]; then
  echo 'https://github.com/example/demo-pkg'
  exit 0
fi

# npm view demo-pkg@1.2.0 description
if [[ "$args" == *"view"* && "$args" == *"demo-pkg@1.2.0"* && "$args" == *"description"* ]]; then
  echo 'Fallback description for demo-pkg'
  exit 0
fi

# npm view @scope/test-pkg@2.5.0 description
if [[ "$args" == *"view"* && "$args" == *"@scope/test-pkg@2.5.0"* && "$args" == *"description"* ]]; then
  echo 'Scoped package test description'
  exit 0
fi

# npm view demo-pkg versions --json
if [[ "$args" == *"view"* && "$args" == *"demo-pkg"* && "$args" == *"versions --json"* ]]; then
  echo '["0.9.0","1.0.0","1.1.0","1.2.0"]'
  exit 0
fi

# npm view @scope/test-pkg versions --json
if [[ "$args" == *"view"* && "$args" == *"@scope/test-pkg"* && "$args" == *"versions --json"* ]]; then
  echo '["1.0.0","2.0.0","2.5.0"]'
  exit 0
fi

# npm view openclaw version
if [[ "$args" == *"view openclaw version"* ]]; then
  echo '0.0.1'
  exit 0
fi

# default: empty/unknown
exit 0
EOF

# ─── Mock: curl (GitHub releases) ────────────────────────────────────────────
cat > "$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$*" == *"/repos/example/demo-pkg/releases?per_page=40"* ]]; then
  cat <<JSON
[
  {"tag_name":"v1.2.0","body":"## Changelog\n- Added scoped warnings\n- Fixed update routing"},
  {"tag_name":"v1.1.0","body":"- Improved checks\n- Better output"},
  {"tag_name":"v1.0.0","body":"- Baseline"}
]
JSON
  exit 0
fi
exit 22
EOF

chmod +x "$BIN_DIR/openclaw" "$BIN_DIR/npm" "$BIN_DIR/curl"

# ─── Test watchlist with SCOPED packages ─────────────────────────────────────
WATCHLIST_FILE="$TMP_DIR/update-watchlist.json"
cat > "$WATCHLIST_FILE" <<'JSON'
{
  "npm": ["demo-pkg", "@scope/test-pkg"],
  "snap": [],
  "go": []
}
JSON

STATE_FILE="$TMP_DIR/.state.json"
STDOUT_FILE="$TMP_DIR/stdout.txt"
STDERR_FILE="$TMP_DIR/stderr.txt"

echo ""
echo "════════════════════════════════════════════"
echo "  Scenario 1: Normal update check"
echo "════════════════════════════════════════════"
echo ""

PATH="$BIN_DIR:$PATH" \
DRY_RUN=1 \
FORCE_NOTIFY=1 \
SAFE_RUN_LOGIN=0 \
WATCHLIST_FILE="$WATCHLIST_FILE" \
STATE_FILE="$STATE_FILE" \
OPENCLAW_BIN="$BIN_DIR/openclaw" \
SAFE_TIMEOUT_SEC=5 \
bash "$TARGET_SCRIPT" >"$STDOUT_FILE" 2>"$STDERR_FILE" || true

OUT="$(cat "$STDOUT_FILE")"
ERR="$(cat "$STDERR_FILE")"

assert_contains "$OUT" "Update verfügbar" "update header rendered"
assert_contains "$OUT" "demo-pkg: 1.0.0 → 1.2.0" "update line for demo-pkg"
assert_contains "$OUT" "@scope/test-pkg: 2.0.0 → 2.5.0" "update line for scoped package (BUG FIX #2)"
assert_contains "$OUT" "Änderungen 1.0.0 → 1.2.0" "release range summary rendered"
assert_contains "$OUT" "1.2.0: Added scoped warnings" "release note bullet rendered"
assert_contains "$OUT" "Soll i updaten?" "call-to-action rendered"
assert_contains "$OUT" "---BUTTONS---" "buttons separator present"

echo ""
echo "════════════════════════════════════════════"
echo "  Scenario 2: Changelog fallback"
echo "════════════════════════════════════════════"
echo ""

# Break curl for fallback scenario
cat > "$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
chmod +x "$BIN_DIR/curl"

STDOUT_FILE2="$TMP_DIR/stdout-fallback.txt"
STDERR_FILE2="$TMP_DIR/stderr-fallback.txt"

PATH="$BIN_DIR:$PATH" \
DRY_RUN=1 \
FORCE_NOTIFY=1 \
SAFE_RUN_LOGIN=0 \
WATCHLIST_FILE="$WATCHLIST_FILE" \
STATE_FILE="$TMP_DIR/.state2.json" \
OPENCLAW_BIN="$BIN_DIR/openclaw" \
SAFE_TIMEOUT_SEC=5 \
bash "$TARGET_SCRIPT" >"$STDOUT_FILE2" 2>"$STDERR_FILE2" || true

OUT2="$(cat "$STDOUT_FILE2")"

assert_contains "$OUT2" "Fallback description for demo-pkg" "npm description fallback works"
assert_contains "$OUT2" "@scope/test-pkg: 2.0.0 → 2.5.0" "scoped pkg still detected in fallback"

echo ""
echo "════════════════════════════════════════════"
echo "  Scenario 3: lib/common.sh sources"
echo "════════════════════════════════════════════"
echo ""

# Test that common.sh can be sourced independently
(
  export PATH="$BIN_DIR:$PATH"
  export SAFE_RUN_LOGIN=0
  export OPENCLAW_BIN="$BIN_DIR/openclaw"
  source "$COMMON_LIB"

  # Test version_gt
  if version_gt "2.0.0" "1.0.0"; then
    pass "version_gt: 2.0.0 > 1.0.0"
  else
    fail "version_gt: 2.0.0 > 1.0.0"
  fi

  # Test npm_global_current_version with scoped pkg
  ver="$(npm_global_current_version "@scope/test-pkg")"
  if [[ "$ver" == "2.0.0" ]]; then
    pass "npm_global_current_version handles scoped packages"
  else
    fail "npm_global_current_version for scoped pkg returned '$ver' (expected '2.0.0')"
  fi

  # Test json_escape
  esc="$(json_escape 'hello "world"')"
  if [[ "$esc" == 'hello \"world\"' ]]; then
    pass "json_escape handles quotes"
  else
    fail "json_escape returned '$esc'"
  fi

  # Test normalize_version
  norm="$(normalize_version "v1.2.3")"
  if [[ "$norm" == "1.2.3" ]]; then
    pass "normalize_version strips v-prefix"
  else
    fail "normalize_version returned '$norm'"
  fi
)

echo ""
echo "════════════════════════════════════════════"
echo "  ✅ E2E Validation Complete"
echo "════════════════════════════════════════════"
echo ""
printf 'Proof snippet (stdout, scenario 1):\n'
head -n 25 "$STDOUT_FILE"
echo ""
printf 'Proof snippet (stdout, scenario 2 fallback):\n'
head -n 15 "$STDOUT_FILE2"
echo ""
printf 'Proof snippet (stderr):\n'
head -n 10 "$STDERR_FILE"

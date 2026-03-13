#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/coder/.openclaw/workspace"
TARGET_SCRIPT="$ROOT/cron/check-updates-notify.sh"

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
  if printf '%s' "$haystack" | grep -Fq "$needle"; then
    pass "$msg"
  else
    echo "----- output -----" >&2
    printf '%s\n' "$haystack" >&2
    echo "------------------" >&2
    fail "$msg (missing: $needle)"
  fi
}

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

BIN_DIR="$TMP_DIR/bin"
mkdir -p "$BIN_DIR"

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
exit 0
EOF

cat > "$BIN_DIR/npm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
if [[ "$args" == *"ls -g"* && "$args" == *"demo-pkg"* && "$args" == *"--depth=0 --json"* ]]; then
  echo '{"dependencies":{"demo-pkg":{"version":"1.0.0"}}}'
  exit 0
fi
if [[ "$args" == *"view"* && "$args" == *"demo-pkg"* && "$args" == *" version"* && "$args" != *"versions --json"* ]]; then
  echo '1.2.0'
  exit 0
fi
if [[ "$args" == *"view"* && "$args" == *"demo-pkg"* && "$args" == *"repository.url"* ]]; then
  echo 'https://github.com/example/demo-pkg'
  exit 0
fi
if [[ "$args" == *"view"* && "$args" == *"demo-pkg@1.2.0"* && "$args" == *"description"* ]]; then
  echo 'Fallback description for demo-pkg'
  exit 0
fi
if [[ "$args" == *"view"* && "$args" == *"demo-pkg"* && "$args" == *"versions --json"* ]]; then
  echo '["0.9.0","1.0.0","1.1.0","1.2.0"]'
  exit 0
fi
if [[ "$args" == *"ls -g openclaw --depth=0 --json"* ]]; then
  echo '{"dependencies":{"openclaw":{"version":"0.0.1"}}}'
  exit 0
fi
if [[ "$args" == *"view openclaw version"* ]]; then
  echo '0.0.1'
  exit 0
fi
# default: empty/unknown
exit 0
EOF

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

WATCHLIST_FILE="$TMP_DIR/update-watchlist.json"
cat > "$WATCHLIST_FILE" <<'JSON'
{
  "npm": ["demo-pkg"],
  "snap": []
}
JSON

STATE_FILE="$TMP_DIR/.state.json"

STDOUT_FILE="$TMP_DIR/stdout.txt"
STDERR_FILE="$TMP_DIR/stderr.txt"

PATH="$BIN_DIR:$PATH" \
DRY_RUN=1 \
FORCE_NOTIFY=1 \
WATCHLIST_FILE="$WATCHLIST_FILE" \
STATE_FILE="$STATE_FILE" \
OPENCLAW_BIN="$BIN_DIR/openclaw" \
SAFE_TIMEOUT_SEC=5 \
bash "$TARGET_SCRIPT" >"$STDOUT_FILE" 2>"$STDERR_FILE"

OUT="$(cat "$STDOUT_FILE")"
ERR="$(cat "$STDERR_FILE")"

assert_contains "$OUT" "Anzahl Updates: 1" "watchlist lookup detects one update"
assert_contains "$OUT" "• demo-pkg: 1.0.0 → 1.2.0" "update line rendered"
assert_contains "$OUT" "Änderungen 1.0.0 → 1.2.0" "intermediate version range summary rendered"
assert_contains "$OUT" "1.2.0: Added scoped warnings" "latest release note bullet rendered"
assert_contains "$OUT" "1.1.0: Improved checks" "intermediate release note bullet rendered"
assert_contains "$OUT" "⚠️ Hinweise:" "non-fatal warning section rendered"
assert_contains "$OUT" "OpenClaw config invalid" "config failure surfaced in message"
assert_contains "$ERR" "WARN: OpenClaw config invalid" "warning emitted to stderr (no silent failure)"

# scenario 2: tool/changelog failure falls back safely
cat > "$BIN_DIR/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 22
EOF
chmod +x "$BIN_DIR/curl"

STDOUT_FILE2="$TMP_DIR/stdout-fallback.txt"
STDERR_FILE2="$TMP_DIR/stderr-fallback.txt"

PATH="$BIN_DIR:$PATH" \
DRY_RUN=1 \
FORCE_NOTIFY=1 \
WATCHLIST_FILE="$WATCHLIST_FILE" \
STATE_FILE="$TMP_DIR/.state2.json" \
OPENCLAW_BIN="$BIN_DIR/openclaw" \
SAFE_TIMEOUT_SEC=5 \
bash "$TARGET_SCRIPT" >"$STDOUT_FILE2" 2>"$STDERR_FILE2"

OUT2="$(cat "$STDOUT_FILE2")"
ERR2="$(cat "$STDERR_FILE2")"

assert_contains "$OUT2" "Fallback description for demo-pkg" "fallback changelog content rendered"
assert_contains "$OUT2" "demo-pkg: GitHub release lookup fehlgeschlagen, nutze npm fallback" "tool failure warning rendered"
assert_contains "$OUT2" "demo-pkg: npm versions für Bereichsanalyse nicht verfügbar" "fallback metadata warning rendered"
assert_contains "$ERR2" "WARN: OpenClaw config invalid" "stderr warnings still present in fallback scenario"

pass "E2E update-check validation completed"
printf '\nProof snippet (stdout, scenario 1):\n'
head -n 30 "$STDOUT_FILE"
printf '\nProof snippet (stdout, scenario 2 fallback):\n'
head -n 30 "$STDOUT_FILE2"
printf '\nProof snippet (stderr):\n'
head -n 30 "$STDERR_FILE"

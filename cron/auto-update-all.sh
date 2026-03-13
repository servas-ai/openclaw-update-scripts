#!/usr/bin/env bash
set -euo pipefail

# ─── Source shared library ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="auto-update-all"
source "$SCRIPT_DIR/../lib/common.sh"

GROUP_ID="${GROUP_ID:-$CHAT_ID}"

ts="$(date '+%Y-%m-%d %H:%M:%S')"
report=()

run_update() {
  local name="$1"
  local key="$2"
  local version_cmd="$3"
  local update_cmd="$4"

  local before after status
  before="$(bash -lc "$version_cmd" 2>/dev/null || echo 'unknown')"
  if bash -lc "$update_cmd" >"/tmp/openclaw-update-${key}.log" 2>&1; then
    status="ok"
  else
    status="fail"
  fi
  after="$(bash -lc "$version_cmd" 2>/dev/null || echo 'unknown')"

  if [[ "$status" == "ok" ]]; then
    report+=("✅ ${name}: ${before} → ${after}")
  else
    local err
    err="$(tail -n 1 "/tmp/openclaw-update-${key}.log" 2>/dev/null || echo 'unknown error')"
    report+=("❌ ${name}: ${before} → ${after} (${err})")
  fi
}

run_update "Agent Browser" "agent-browser" "/usr/bin/agent-browser --version | awk '{print \$2}'" "update-agent-browser"
run_update "OpenClaw" "openclaw" "/usr/bin/openclaw --version" "update-openclaw"
run_update "Codex CLI" "codex" "/usr/bin/codex --version | awk '{print \$2}'" "update-codex-cli"

msg="🔄 VCVM Auto-Update (${ts})"$'\n'
msg+=$'━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
for line in "${report[@]}"; do
  msg+="$line"$'\n'
done

if [[ "$OPENCLAW_CLI_AVAILABLE" == "1" ]]; then
  CHAT_ID="$GROUP_ID" send_message "$msg" || log_warn "Auto-Update Nachricht fehlgeschlagen"
fi

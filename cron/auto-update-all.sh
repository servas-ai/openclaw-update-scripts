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
  local name="$1" key="$2" version_cmd="$3" update_cmd="$4"
  local before after log

  before="$(safe_run "$version_cmd" || echo 'unknown')"
  log="/tmp/openclaw-update-${key}.log"

  if run_with_retry "$update_cmd" "$log"; then
    after="$(safe_run "$version_cmd" || echo 'unknown')"
    report+=("✅ ${name}: ${before} → ${after}")
  else
    after="$(safe_run "$version_cmd" || echo 'unknown')"
    local err
    err="$(tail -n 1 "$log" 2>/dev/null || echo 'unknown error')"
    report+=("❌ ${name}: ${before} → ${after} ($(shorten_line "$err"))")
  fi
}

run_update "Agent Browser" "agent-browser" \
  "/usr/bin/agent-browser --version | awk '{print \$2}'" \
  "update-agent-browser"

run_update "OpenClaw" "openclaw" \
  "/usr/bin/openclaw --version" \
  "update-openclaw"

run_update "Codex CLI" "codex" \
  "/usr/bin/codex --version | awk '{print \$2}'" \
  "update-codex-cli"

msg="🔄 VCVM Auto-Update (${ts})"$'\n'
msg+=$'━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
for line in "${report[@]}"; do
  msg+="$line"$'\n'
done

if [[ "$OPENCLAW_CLI_AVAILABLE" == "1" ]]; then
  CHAT_ID="$GROUP_ID" send_message "$msg" || log_warn "Auto-Update Nachricht fehlgeschlagen"
fi

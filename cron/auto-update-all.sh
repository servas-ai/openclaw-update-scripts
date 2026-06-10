#!/usr/bin/env bash
# ══════════════════════════════════════════════════════════════════════════════
# auto-update-all.sh — Update all tracked packages with security scan
# ACP Agent: OME Open Agent (opencode + Sisyphus) | UI: Gemini-Sila
# ══════════════════════════════════════════════════════════════════════════════
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="auto-update-all"
source "$SCRIPT_DIR/../lib/common.sh"

GROUP_ID="${GROUP_ID:-$CHAT_ID}"

# ── State ─────────────────────────────────────────────────────────────────────
report=()
updated_count=0
failed_count=0
skipped_count=0

# ── Validate OpenClaw config ─────────────────────────────────────────────────
if ! validate_openclaw_config; then
  openclaw_validate_out="$($OPENCLAW_BIN config validate 2>&1 || true)"
  openclaw_validate_out="$(shorten_line "$openclaw_validate_out")"
  report+=("⚙️ openclaw config: fallback auf npm registry (${openclaw_validate_out})")
fi

# ── Run Full Update (npm + snap + security scan + changelog) ─────────────────
run_full_update "Auto-Update Ergebnis"

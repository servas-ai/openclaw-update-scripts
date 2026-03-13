#!/usr/bin/env bash
set -euo pipefail

# ─── Source shared library ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="run-all-updates"
source "$SCRIPT_DIR/../lib/common.sh"

# ─── Config ────────────────────────────────────────────────────────────────────
TELEGRAM_NOTIFY="${TELEGRAM_NOTIFY:-1}"

# ─── State (used by shared update functions) ───────────────────────────────────
report=()
updated_count=0
failed_count=0
skipped_count=0

# ─── Validate OpenClaw config ─────────────────────────────────────────────────
if ! validate_openclaw_config; then
  openclaw_validate_out="$($OPENCLAW_BIN config validate 2>&1 || true)"
  openclaw_validate_out="$(shorten_line "$openclaw_validate_out")"
  report+=("⚙️ openclaw config: fallback auf npm registry (${openclaw_validate_out})")
fi

# ─── Run all updates ──────────────────────────────────────────────────────────
run_full_update "Update-Lauf Ergebnis"

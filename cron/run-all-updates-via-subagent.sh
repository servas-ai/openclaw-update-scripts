#!/usr/bin/env bash
# ACP Agent: OME Open Agent (opencode + Sisyphus) | UI: Gemini-Sila
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="run-all-updates-via-subagent"
source "$SCRIPT_DIR/../lib/common.sh"
RUNNER="$SCRIPT_DIR/run-all-updates-direct.sh"
[[ ! -f "$RUNNER" ]] && { log_warn "Runner not found: $RUNNER"; exit 1; }
[[ ! -x "$RUNNER" ]] && chmod +x "$RUNNER"
OME_BIN="$(command -v oh-my-opencode 2>/dev/null || true)"
if [[ -z "$OME_BIN" ]]; then
  log_warn "oh-my-opencode nicht gefunden — Fallback auf direkten Update-Lauf"
  exec env TELEGRAM_NOTIFY="${TELEGRAM_NOTIFY:-1}" bash "$RUNNER"
fi
REASON="${AUTO_UPDATE_REASON:-scheduled update check}"
PROMPT="# Update-Pipeline — OME Open Agent (Sisyphus)
## ACP: OME Open Agent (opencode + Sisyphus) | Trigger: ${REASON} | $(date '+%Y-%m-%d %H:%M')
Fuehre aus: TELEGRAM_NOTIFY=${TELEGRAM_NOTIFY:-1} bash ${RUNNER}
| Subagent | Aufgabe | Status |
|----------|---------|--------|
| SA-1 | npm-Pakete aktualisieren | pending |
| SA-2 | snap-Pakete aktualisieren | pending |
| SA-3 | Security-Scan zusammenfassen | pending |
Regeln: Keine Rueckfragen. Bei Fehler 1x Retry. Am Ende Zusammenfassung."
log_info "Starte OME Sub-Agent Update-Lauf (Sisyphus)..."
exec "$OME_BIN" run --agent Sisyphus --directory "$(dirname "$SCRIPT_DIR")" \
  --on-complete "openclaw system event --text 'Sub-Agent Update-Lauf abgeschlossen' --mode now" \
  "$PROMPT"

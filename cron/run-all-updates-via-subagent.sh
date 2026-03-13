#!/usr/bin/env bash
set -euo pipefail

# ─── Source shared library ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="run-all-updates-via-subagent"
source "$SCRIPT_DIR/../lib/common.sh"

RUNNER="$SCRIPT_DIR/run-all-updates.sh"

if ! command -v oh-my-opencode >/dev/null 2>&1; then
  echo "oh-my-opencode fehlt" >&2
  exit 1
fi

if [[ ! -x "$RUNNER" ]]; then
  chmod +x "$RUNNER"
fi

PROMPT="$(cat <<'PROMPT_END'
Führe exakt diesen Befehl aus:

TELEGRAM_NOTIFY=1 SCRIPT_DIR RUNNER

Regeln:
- Keine Rückfragen
- Bei Fehlern 1x Retry
- Am Ende kurze Zusammenfassung (Updated/Fehler) ausgeben
- Nichts außerhalb dieses Update-Flows ändern.
PROMPT_END
)"

# Replace placeholder with actual runner path
PROMPT="${PROMPT//RUNNER/$RUNNER}"
PROMPT="${PROMPT//SCRIPT_DIR/SCRIPT_DIR=$SCRIPT_DIR}"

exec oh-my-opencode run \
  --agent Sisyphus \
  --directory "$(dirname "$SCRIPT_DIR")" \
  --on-complete "openclaw system event --text 'Sub-Agent Update-Lauf abgeschlossen' --mode now" \
  "$PROMPT"

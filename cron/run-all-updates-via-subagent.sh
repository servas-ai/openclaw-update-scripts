#!/usr/bin/env bash
set -euo pipefail

WORKDIR="/home/coder/.openclaw/workspace"
RUNNER="$WORKDIR/cron/run-all-updates.sh"

if ! command -v oh-my-opencode >/dev/null 2>&1; then
  echo "oh-my-opencode fehlt" >&2
  exit 1
fi

if [[ ! -x "$RUNNER" ]]; then
  chmod +x "$RUNNER"
fi

PROMPT=$'Führe im Verzeichnis /home/coder/.openclaw/workspace exakt diesen Befehl aus:\n\nTELEGRAM_NOTIFY=1 /home/coder/.openclaw/workspace/cron/run-all-updates.sh\n\nRegeln:\n- Keine Rückfragen\n- Bei Fehlern 1x Retry\n- Am Ende kurze Zusammenfassung (Updated/Fehler) ausgeben\n- Nichts außerhalb dieses Update-Flows ändern.'

exec oh-my-opencode run \
  --agent Sisyphus \
  --directory "$WORKDIR" \
  --on-complete "openclaw system event --text 'Sub-Agent Update-Lauf abgeschlossen' --mode now" \
  "$PROMPT"

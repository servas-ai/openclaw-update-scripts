# Installation — OpenClaw Update Scripts

## Voraussetzungen

- **Node.js** (v20+) mit npm
- **jq** (JSON-Parser)
- **OpenClaw CLI** (`openclaw`) global installiert
- Optional: **snap** (für Snap-Package-Updates)

## 1. Repo klonen

```bash
git clone https://github.com/servas-ai/openclaw-update-scripts.git
cd openclaw-update-scripts
```

## 2. Skripte ausführbar machen

```bash
chmod +x cron/*.sh scripts/*.sh
```

## 3. Watchlist konfigurieren

Die Datei `cron/update-watchlist.json` enthält die zu überwachenden Pakete:

```json
{
  "npm": ["openclaw", "@anthropic-ai/claude-code", "npm", ...],
  "npm_exclude": [],
  "snap": ["chromium", "snapd", ...],
  "go": ["gt"]
}
```

Pakete hinzufügen/entfernen nach Bedarf.

**Dynamische Package-Erkennung:** Neue global installierte npm-Packages werden automatisch bei jedem Update-Check erkannt und zur Watchlist hinzugefügt.

**Packages ausschließen:** Pakete, die nicht automatisch getracked werden sollen, in `npm_exclude` eintragen:

```json
{
  "npm_exclude": ["vite", "create-better-openclaw"]
}
```

## 4. Environment-Variablen

| Variable | Default | Beschreibung |
|----------|---------|-------------|
| `CHAT_ID` | `-1003766760589` | Telegram Chat-ID / Matrix Room |
| `THREAD_ID` | `16` | Telegram Forum-Thread-ID |
| `CHANNEL` | `telegram` | Kanal: `telegram`, `matrix`, oder `both` |
| `SAFE_TIMEOUT_SEC` | `30` | Timeout für npm-Lookups (Sekunden) |
| `WATCHLIST_FILE` | `cron/update-watchlist.json` | Pfad zur Watchlist |
| `OPENCLAW_BIN` | auto-detect | Pfad zur OpenClaw-Binary |
| `TELEGRAM_NOTIFY` | `1` | Telegram-Benachrichtigung an/aus |
| `AUTO_HEAL_ENABLED` | `1` | Auto-Heal bei kritischen Lookup-Fehlern |
| `DRY_RUN` | `0` | Nur ausgeben, nicht senden |
| `FORCE_NOTIFY` | `0` | Immer senden (auch wenn keine Änderung) |
| `AI_SUMMARIZE` | `auto` | KI-Zusammenfassung: `auto`, `1`, `0` |
| `AI_SUMMARIZE_TIMEOUT` | `30` | Timeout für KI-Zusammenfassung (Sekunden) |

## 5. KI-gestützte Changelog-Zusammenfassung

Bei Updates werden Release-Notes automatisch von GitHub Releases und npm gesammelt und per **OpenClaw AI** in 3 prägnante Bullet Points zusammengefasst.

### Voraussetzungen

- **OpenClaw CLI** mit funktionierender `openclaw agent --local` (benötigt API-Key für ein LLM, z.B. Gemini, Claude, oder OpenAI)
- Die KI-Zusammenfassung ist standardmäßig aktiv (`AI_SUMMARIZE=auto`), wenn OpenClaw verfügbar ist

### Konfiguration

```bash
# Standardmäßig aktiv wenn OpenClaw CLI verfügbar
AI_SUMMARIZE=auto

# Explizit aktivieren/deaktivieren
AI_SUMMARIZE=1   # immer KI nutzen
AI_SUMMARIZE=0   # nur raw Changelog anzeigen

# Timeout für KI-Antworten (Default: 30s)
AI_SUMMARIZE_TIMEOUT=30
```

### Fallback

Falls die KI nicht verfügbar oder zu langsam ist, wird automatisch auf die bisherige Logik zurückgefallen (Rohdaten aus GitHub Releases / npm).

## 6. OpenClaw Agents konfigurieren

OpenClaw kann eigene Agents installieren und verwalten — inklusive System-Prompts, Model-Auswahl und Tool-Freigaben. Die Update-Scripts nutzen `openclaw agent --local` für die Changelog-Zusammenfassung.

### Agent-Konfiguration via `openclaw.json`

Agents werden unter `agents.list[]` in `~/.openclaw/openclaw.json` definiert:

```json
{
  "agents": {
    "defaults": {
      "model": {
        "primary": "custom-cliproxy-servas-ai/gpt-5.3-codex"
      }
    },
    "list": [
      {
        "id": "update-summarizer",
        "name": "Update Summarizer",
        "workspace": "/path/to/workspace",
        "agentDir": "/path/to/agent-config"
      }
    ]
  }
}
```

### Agent via CLI konfigurieren

```bash
# Model-Provider einrichten (z.B. eigene API)
openclaw config set models.providers.my-proxy.baseUrl "https://cliproxy.servas.ai/v1"
openclaw config set models.providers.my-proxy.apiKey "ccs-internal-managed"
openclaw config set models.providers.my-proxy.api "openai-completions"

# Default-Model für Agents setzen
openclaw config set agents.defaults.model.primary "my-proxy/gpt-4o-mini"
```

### System-Prompt für eigene Agents

Jeder Agent kann einen eigenen System-Prompt bekommen — über das `agentDir`, das eine `models.json` und weitere Config-Dateien enthält:

```bash
# Agent-Verzeichnis erstellen
mkdir -p ~/.openclaw/agents/update-summarizer/agent

# System-Prompt als HEARTBEAT.md (wird automatisch als System-Prompt geladen)
cat > ~/.openclaw/agents/update-summarizer/agent/HEARTBEAT.md << 'EOF'
Du bist ein Package-Update-Summarizer.
Fasse Changelogs immer in genau 3 kurzen deutschen Bullet Points zusammen.
Maximal 120 Zeichen pro Punkt. Keine Emojis.
EOF
```

### Agent starten

```bash
# Lokal (mit eigenem API-Key)
openclaw agent --local --agent update-summarizer --message "Fasse zusammen: ..."

# Via Gateway (wenn OpenClaw Gateway läuft)
openclaw agent --agent update-summarizer --message "Fasse zusammen: ..."

# Default-Agent (ohne --agent Flag)
openclaw agent --local --message "Deine Anfrage"
```

### Für diese Update-Scripts

Die Scripts nutzen den Default-Agent mit `--local`. Der System-Prompt wird direkt im `--message` mitgegeben. Eigene Agent-Konfiguration ist **optional** — die Scripts funktionieren mit dem Default-Agent, solange ein Model-Provider konfiguriert ist.

```bash
# Minimal-Setup: nur Model-Provider einrichten
openclaw config set models.providers.my-api.baseUrl "https://cliproxy.servas.ai/v1"
openclaw config set models.providers.my-api.apiKey "ccs-internal-managed"
openclaw config set models.providers.my-api.api "openai-completions"
openclaw config set models.default "my-api/gpt-4o-mini"
openclaw config set models.agentModel "my-api/gpt-4o-mini"
```

## 7. Crontab einrichten

```bash
# Alle 30 Minuten auf Updates prüfen
*/30 * * * * cd /path/to/openclaw-update-scripts && bash cron/check-updates-notify.sh

# Täglich um 03:00 Auto-Update (optional)
0 3 * * * cd /path/to/openclaw-update-scripts && bash cron/auto-update-all.sh
```

## 8. Test-Lauf

```bash
# Dry-Run — zeigt Nachricht ohne zu senden
DRY_RUN=1 FORCE_NOTIFY=1 bash cron/check-updates-notify.sh

# E2E-Tests (mocked, kein Netzwerk)
bash scripts/e2e-update-check-validation.sh
```

**Erwartung:** Keine `[FAIL]`-Zeilen, alle `[PASS]`.

## 9. Matrix statt Telegram

```bash
# In der Crontab oder .env:
export CHANNEL=matrix
export CHAT_ID="!roomid:matrix.server.com"
```

Oder beide Kanäle gleichzeitig:

```bash
export CHANNEL=both
```


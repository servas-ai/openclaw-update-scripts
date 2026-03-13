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
  "snap": ["chromium", "snapd", ...],
  "go": ["gt"]
}
```

Pakete hinzufügen/entfernen nach Bedarf.

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

## 5. Crontab einrichten

```bash
# Alle 30 Minuten auf Updates prüfen
*/30 * * * * cd /path/to/openclaw-update-scripts && bash cron/check-updates-notify.sh

# Täglich um 03:00 Auto-Update (optional)
0 3 * * * cd /path/to/openclaw-update-scripts && bash cron/auto-update-all.sh
```

## 6. Test-Lauf

```bash
# Dry-Run — zeigt Nachricht ohne zu senden
DRY_RUN=1 FORCE_NOTIFY=1 bash cron/check-updates-notify.sh

# E2E-Tests (mocked, kein Netzwerk)
bash scripts/e2e-update-check-validation.sh
```

**Erwartung:** Keine `[FAIL]`-Zeilen, alle `[PASS]`.

## 7. Matrix statt Telegram

```bash
# In der Crontab oder .env:
export CHANNEL=matrix
export CHAT_ID="!roomid:matrix.server.com"
```

Oder beide Kanäle gleichzeitig:

```bash
export CHANNEL=both
```

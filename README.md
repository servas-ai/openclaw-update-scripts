# OpenClaw Update Scripts

Automatisierte Update-Überwachung und -Durchführung für npm/snap-Pakete mit schönem Telegram/Matrix UI.

## Features

- 🔔 **Update-Benachrichtigungen** via Telegram und/oder Matrix
- 📦 **Per-Package Buttons** — einzelne Pakete updaten oder alle auf einmal
- 📋 **Changelog-Highlights** — zeigt Release Notes direkt in der Nachricht
- 🛠 **Auto-Heal** — repariert sich automatisch bei kritischen Fehlern
- 🔄 **Dual-Channel** — Telegram + Matrix gleichzeitig
- ✅ **E2E-Tests** — mocked Tests ohne Netzwerk-Abhängigkeit

## Skripte

| Datei | Beschreibung |
|-------|-------------|
| `lib/common.sh` | Shared Library (Versionsvergleich, Messaging, npm-Helpers) |
| `cron/check-updates-notify.sh` | Prüft auf Updates und sendet Telegram/Matrix-Nachricht |
| `cron/run-all-updates.sh` | Führt alle verfügbaren Updates durch |
| `cron/run-all-updates-direct.sh` | Direkte Update-Ausführung (ohne Subagent) |
| `cron/run-all-updates-via-subagent.sh` | Updates via oh-my-opencode Subagent |
| `cron/auto-update-all.sh` | Auto-Update für Kernpakete (Agent Browser, OpenClaw, Codex) |
| `cron/update-watchlist.json` | Liste der überwachten Pakete (npm + snap + go) |
| `scripts/e2e-update-check-validation.sh` | E2E-Tests mit Mocks |

## Quick Start

```bash
git clone https://github.com/servas-ai/openclaw-update-scripts.git
cd openclaw-update-scripts
chmod +x cron/*.sh scripts/*.sh

# Test (Dry-Run)
DRY_RUN=1 FORCE_NOTIFY=1 bash cron/check-updates-notify.sh

# Crontab: alle 30 Minuten prüfen
*/30 * * * * cd /path/to/openclaw-update-scripts && bash cron/check-updates-notify.sh
```

## Telegram-Nachricht Beispiel

```
🔔 Update verfügbar (13.03.2026 01:30)
━━━━━━━━━━━━━━━━━━━━━━━━━

📦 3 Update(s) gefunden:

• openclaw: 2026.3.2 → 2026.3.11
  📋 Änderungen 2026.3.2 → 2026.3.11 (5 Releases)
  📋 Bug fixes and performance improvements
  📋 New CLI commands for message routing

• npm: 10.9.4 → 11.11.1
  📋 ...

━━━━━━━━━━━━━━━━━━━━━━━━━
Soll i updaten?

[✅ Alle updaten] [❌ Nein, danke]
[📦 openclaw] [📦 npm]
```

## Konfiguration

Siehe [INSTALL.md](INSTALL.md) für vollständige Setup-Anleitung.

## Hinweise

- Für produktiven Einsatz Cron-Umgebung, OpenClaw-CLI und Rechte (sudo/gh) prüfen
- `SAFE_TIMEOUT_SEC=30` (Standard) — bei langsamer Verbindung auf 45+ erhöhen
- Auto-Heal hat einen 6h Cooldown um Spam zu vermeiden

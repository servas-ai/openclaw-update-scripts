# Installation — OpenClaw Update Scripts

> Complete setup guide. Each step includes a verification command so both humans and AI agents can confirm success.

---

## Prerequisites

| Dependency | Required | Check | Install |
|------------|----------|-------|---------|
| **bash** ≥ 5.0 | ✅ | `bash --version \| head -1` | pre-installed on Linux |
| **Node.js** ≥ 20 | ✅ | `node --version` | `nvm install 20` or [nodejs.org](https://nodejs.org) |
| **npm** | ✅ | `npm --version` | comes with Node.js |
| **jq** ≥ 1.6 | ✅ | `jq --version` | `sudo apt install jq` / `brew install jq` |
| **curl** | ✅ | `curl --version \| head -1` | `sudo apt install curl` |
| **git** | ✅ | `git --version` | `sudo apt install git` |
| **OpenClaw CLI** | ✅ | `openclaw --version` | `npm install -g openclaw` |
| **snap** | ❌ optional | `snap --version` | pre-installed on Ubuntu |
| **timeout** (coreutils) | ❌ optional | `timeout --version` | `sudo apt install coreutils` |

> **AI Agent Note:** Run each "Check" command. If exit code ≠ 0, run the corresponding "Install" command first.

---

## Step 1 — Clone the Repository

```bash
git clone https://github.com/servas-ai/openclaw-update-scripts.git
cd openclaw-update-scripts
```

**✅ Verify:**
```bash
test -f lib/common.sh && test -d cron && test -d scripts && echo "OK" || echo "FAIL"
```

---

## Step 2 — Make Scripts Executable

```bash
chmod +x cron/*.sh scripts/*.sh
```

**✅ Verify:**
```bash
ls -la cron/*.sh | awk '{print $1, $NF}' | grep -q 'x' && echo "OK" || echo "FAIL"
```

---

## Step 3 — Install OpenClaw CLI

```bash
npm install -g openclaw
```

**✅ Verify:**
```bash
openclaw --version
# Expected: OpenClaw 2026.x.x (or newer)
```

---

## Step 4 — Configure OpenClaw Model Provider

The AI changelog summarization requires an LLM API. OpenClaw supports any **OpenAI-compatible** endpoint.

### Option A: Custom API Proxy (recommended)

```bash
openclaw config set models.providers.my-api.baseUrl "https://your-api.example.com/v1"
openclaw config set models.providers.my-api.apiKey "your-api-key-here"
openclaw config set models.providers.my-api.api "openai-completions"
openclaw config set models.default "my-api/gpt-4o-mini"
openclaw config set models.agentModel "my-api/gpt-4o-mini"
```

### Option B: Direct OpenAI

```bash
openclaw config set models.providers.openai.baseUrl "https://api.openai.com/v1"
openclaw config set models.providers.openai.apiKey "sk-..."
openclaw config set models.providers.openai.api "openai-completions"
openclaw config set models.default "openai/gpt-4o-mini"
openclaw config set models.agentModel "openai/gpt-4o-mini"
```

### Option C: No AI (raw changelogs only)

```bash
export AI_SUMMARIZE=0
```

**✅ Verify:**
```bash
openclaw config validate && echo "OK" || echo "FAIL — run one of the options above"
```

---

## Step 5 — Configure the Watchlist

Edit `cron/update-watchlist.json`:

```json
{
  "npm": [
    "openclaw",
    "@anthropic-ai/claude-code",
    "npm"
  ],
  "npm_exclude": [
    "create-better-openclaw"
  ],
  "snap": [
    "chromium",
    "snapd"
  ],
  "go": [
    "gt"
  ]
}
```

### Field Reference

| Field | Type | Purpose |
|-------|------|---------|
| `npm` | `string[]` | npm packages to monitor for updates |
| `npm_exclude` | `string[]` | Packages to skip during auto-discovery (never auto-added) |
| `snap` | `string[]` | Snap packages to monitor (requires `snapd`) |
| `go` | `string[]` | Go binaries to monitor |

> **Auto-Discovery:** You don't need to list every global npm package. The scripts automatically detect new globally-installed packages and add them to `npm[]` on each run. Use `npm_exclude` to block unwanted packages from being auto-added.

**✅ Verify:**
```bash
jq . cron/update-watchlist.json > /dev/null && echo "OK — valid JSON" || echo "FAIL — invalid JSON"
```

---

## Step 6 — Configure Notification Channel

### Telegram

```bash
export CHANNEL="telegram"
export CHAT_ID="-1003766760589"     # Your Telegram group/chat ID
export THREAD_ID="16"               # Forum thread (0 = no forum)
```

### Matrix

```bash
export CHANNEL="matrix"
export CHAT_ID="!roomid:matrix.server.com"
# THREAD_ID is not used for Matrix
```

### Both simultaneously

```bash
export CHANNEL="both"
```

> **AI Agent Note:** The `CHAT_ID` must be set correctly for the target platform. For Telegram groups, it typically starts with `-100`. For Matrix, it's the room ID starting with `!`.

---

## Step 7 — Run Tests

```bash
bash scripts/e2e-update-check-validation.sh
```

**✅ Verify:**
```bash
bash scripts/e2e-update-check-validation.sh 2>&1 | tail -3
# Expected: ✅ ALL TESTS PASSED: 234/234
```

---

## Step 8 — Dry-Run

Test the full pipeline without actually sending messages:

```bash
DRY_RUN=1 FORCE_NOTIFY=1 bash cron/check-updates-notify.sh
```

**✅ Verify:** Output contains:
- `🔔 Update verfügbar` header (if updates found)
- Package names with version arrows (`1.0.0 → 2.0.0`)
- `📋` changelog bullet points
- `---BUTTONS---` section with valid JSON

---

## Step 9 — Set Up Cron Jobs

```bash
crontab -e
```

Add these lines (adjust paths):

```cron
# Check for package updates every 30 minutes
*/30 * * * * cd /home/user/openclaw-update-scripts && bash cron/check-updates-notify.sh >> /tmp/openclaw-update.log 2>&1

# Optional: auto-update core packages daily at 03:00
0 3 * * * cd /home/user/openclaw-update-scripts && bash cron/auto-update-all.sh >> /tmp/openclaw-auto-update.log 2>&1
```

**✅ Verify:**
```bash
crontab -l | grep -q "check-updates-notify" && echo "OK" || echo "FAIL — cron not set"
```

---

## Environment Variables — Complete Reference

| Variable | Default | Type | Description |
|----------|---------|------|-------------|
| `CHAT_ID` | `-1003766760589` | string | Target chat/room for notifications |
| `THREAD_ID` | `16` | integer | Telegram forum thread (0 = disabled) |
| `CHANNEL` | `telegram` | enum | `telegram` \| `matrix` \| `both` |
| `DRY_RUN` | `0` | 0/1 | Print to stdout only, don't send |
| `FORCE_NOTIFY` | `0` | 0/1 | Bypass dedup, always send |
| `AI_SUMMARIZE` | `auto` | enum | `auto` \| `1` \| `0` |
| `AI_SUMMARIZE_TIMEOUT` | `30` | seconds | Max wait for AI response |
| `SAFE_TIMEOUT_SEC` | `30` | seconds | Timeout per `npm view` call |
| `AUTO_HEAL_ENABLED` | `1` | 0/1 | Self-repair on critical failures |
| `AUTO_HEAL_COOLDOWN_SEC` | `21600` | seconds | Min time between auto-heals (6h) |
| `TELEGRAM_NOTIFY` | `1` | 0/1 | Send completion report after update runs |
| `WATCHLIST_FILE` | `cron/update-watchlist.json` | path | Watchlist location |
| `OPENCLAW_BIN` | auto-detect | path | Explicit OpenClaw binary path |
| `SAFE_RUN_LOGIN` | `1` | 0/1 | Use login shell for `safe_run` |

---

## Advanced: Custom OpenClaw Agent

### Create a dedicated summarizer agent with custom system prompt:

```bash
# 1. Create agent directory
mkdir -p ~/.openclaw/agents/update-summarizer/agent

# 2. Write system prompt
cat > ~/.openclaw/agents/update-summarizer/agent/HEARTBEAT.md << 'EOF'
Du bist ein Package-Update-Summarizer.
Fasse Changelogs immer in genau 3 kurzen deutschen Bullet Points zusammen.
Maximal 120 Zeichen pro Punkt. Keine Emojis.
Wenn keine Informationen verfügbar sind, beschreibe die wahrscheinlichen Änderungen basierend auf der Versionsnummer.
EOF

# 3. Register in openclaw.json
openclaw config set agents.list '[{"id":"update-summarizer","name":"Update Summarizer"}]'

# 4. Test
openclaw agent --local --agent update-summarizer --message "Fasse zusammen: Bug fixes and performance improvements"
```

### Agent Configuration Reference (`~/.openclaw/openclaw.json`)

```json
{
  "models": {
    "default": "my-api/gpt-4o-mini",
    "agentModel": "my-api/gpt-4o-mini",
    "providers": {
      "my-api": {
        "baseUrl": "https://cliproxy.servas.ai/v1",
        "apiKey": "ccs-internal-managed",
        "api": "openai-completions"
      }
    }
  },
  "agents": {
    "defaults": {
      "model": {
        "primary": "my-api/gpt-4o-mini"
      }
    },
    "list": [
      {
        "id": "update-summarizer",
        "name": "Update Summarizer",
        "agentDir": "~/.openclaw/agents/update-summarizer/agent"
      }
    ]
  }
}
```

---

## Troubleshooting

| Problem | Cause | Solution |
|---------|-------|----------|
| `openclaw: command not found` | Not installed globally | `npm install -g openclaw` |
| `openclaw config validate` fails | No model provider configured | Run Step 4 |
| Tests show `[FAIL]` | Dependency missing or lib changed | Read error message, check prerequisites |
| No Telegram message | Wrong `CHAT_ID` or `THREAD_ID` | Verify with Telegram API / BotFather |
| AI summaries empty | Model timeout or API unreachable | Increase `AI_SUMMARIZE_TIMEOUT` or set `AI_SUMMARIZE=0` |
| Same notification keeps arriving | Dedup state file deleted | Normal — will dedup on next identical payload |
| `jq: command not found` | jq not installed | `sudo apt install jq` |
| Permission denied | Scripts not executable | `chmod +x cron/*.sh scripts/*.sh` |
| Auto-heal runs too often | Cooldown not long enough | Increase `AUTO_HEAL_COOLDOWN_SEC` |
| `npm ls -g` slow | Many global packages | Normal — cached globally, runs once per check |

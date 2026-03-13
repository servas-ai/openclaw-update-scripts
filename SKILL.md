---
name: openclaw-update-scripts
description: AI-agent skill for installing, configuring, and operating the OpenClaw Update Scripts system
---

# OpenClaw Update Scripts — AI Agent Skill

This skill enables an AI agent to install, configure, test, and operate the OpenClaw Update Scripts system on any Linux server.

## What This System Does

The OpenClaw Update Scripts monitor globally-installed npm, snap, and Go packages for updates. When updates are found, it:

1. Fetches changelogs from **GitHub Releases** and **npm registry**
2. Summarizes them into **3 bullet points** via an AI model (OpenClaw agent)
3. Sends a **rich notification** via Telegram and/or Matrix with inline buttons
4. Supports **one-click updates** from the chat, **deduplication**, and **auto-heal** on failures

---

## Prerequisites Checklist

Before installation, verify these are available:

| Tool | Required | Check Command | Install |
|------|----------|---------------|---------|
| `bash` ≥ 5.0 | ✅ | `bash --version` | pre-installed |
| `node` ≥ 20 | ✅ | `node --version` | `nvm install 20` |
| `npm` | ✅ | `npm --version` | comes with Node.js |
| `jq` | ✅ | `jq --version` | `apt install jq` / `brew install jq` |
| `openclaw` | ✅ | `openclaw --version` | `npm install -g openclaw` |
| `curl` | ✅ | `curl --version` | `apt install curl` |
| `git` | ✅ | `git --version` | `apt install git` |
| `snap` | ❌ optional | `snap --version` | pre-installed on Ubuntu |
| `timeout` | ❌ optional | `timeout --version` | `apt install coreutils` |

---

## Step-by-Step Installation

### Step 1: Clone the Repository

```bash
git clone https://github.com/servas-ai/openclaw-update-scripts.git
cd openclaw-update-scripts
```

**Verify:** Directory exists and contains `lib/common.sh`, `cron/`, `scripts/`.

### Step 2: Make All Scripts Executable

```bash
chmod +x cron/*.sh scripts/*.sh
```

**Verify:** `ls -la cron/*.sh` shows `-rwxr-xr-x` permissions.

### Step 3: Install OpenClaw CLI (if not installed)

```bash
npm install -g openclaw
```

**Verify:** `openclaw --version` returns a version string like `OpenClaw 2026.x.x`.

### Step 4: Configure OpenClaw Model Provider (for AI summaries)

This is required for AI-powered changelog summarization. The system needs an LLM API.

```bash
# Configure a model provider (any OpenAI-compatible API works)
openclaw config set models.providers.my-api.baseUrl "https://your-api-endpoint/v1"
openclaw config set models.providers.my-api.apiKey "your-api-key"
openclaw config set models.providers.my-api.api "openai-completions"

# Set as default model
openclaw config set models.default "my-api/gpt-4o-mini"
openclaw config set models.agentModel "my-api/gpt-4o-mini"
```

**Verify:** `openclaw config validate` exits with code 0.

**If no AI is available:** Set `AI_SUMMARIZE=0` in step 6. The system will use raw changelog data instead.

### Step 5: Configure the Watchlist

Edit `cron/update-watchlist.json` — this is the list of packages to monitor:

```json
{
  "npm": ["openclaw", "@anthropic-ai/claude-code", "npm"],
  "npm_exclude": ["create-better-openclaw"],
  "snap": ["chromium", "snapd"],
  "go": ["gt"]
}
```

**Key rules:**
- `npm`: Packages to monitor. Auto-discovery adds new global packages automatically.
- `npm_exclude`: Packages to skip during auto-discovery (won't be added even if globally installed).
- `snap`: Snap packages to monitor (requires `snapd`).
- `go`: Go binaries to monitor.

**Verify:** `jq . cron/update-watchlist.json` parses without error.

### Step 6: Configure Messaging Channel

Set environment variables for the notification target:

```bash
# For Telegram:
export CHANNEL="telegram"
export CHAT_ID="-1003766760589"     # Your Telegram Chat/Group ID
export THREAD_ID="16"               # Forum thread ID (0 if no forum)

# For Matrix:
export CHANNEL="matrix"
export CHAT_ID="!roomid:matrix.server.com"

# For both simultaneously:
export CHANNEL="both"
```

### Step 7: Run Tests

```bash
# Mocked E2E tests (no network, no API keys needed)
bash scripts/e2e-update-check-validation.sh
```

**Expected output:** `✅ ALL TESTS PASSED: 234/234`

### Step 8: Dry-Run Test

```bash
DRY_RUN=1 FORCE_NOTIFY=1 bash cron/check-updates-notify.sh
```

**Expected:** Prints the notification message to stdout without sending. Shows detected updates, changelog summaries, and button JSON.

### Step 9: Set Up Cron

```bash
# Add to crontab:
crontab -e

# Check for updates every 30 minutes:
*/30 * * * * cd /path/to/openclaw-update-scripts && bash cron/check-updates-notify.sh >> /tmp/openclaw-update.log 2>&1

# Optional: Auto-update core packages daily at 03:00
0 3 * * * cd /path/to/openclaw-update-scripts && bash cron/auto-update-all.sh >> /tmp/openclaw-auto-update.log 2>&1
```

**Verify:** `crontab -l` shows the entries.

---

## Environment Variables Reference

| Variable | Default | Type | Description |
|----------|---------|------|-------------|
| `CHAT_ID` | `-1003766760589` | string | Telegram Chat-ID or Matrix Room ID |
| `THREAD_ID` | `16` | integer | Telegram Forum Thread-ID (0 = no forum) |
| `CHANNEL` | `telegram` | enum | `telegram`, `matrix`, or `both` |
| `DRY_RUN` | `0` | bool | `1` = print to stdout only, no messages sent |
| `FORCE_NOTIFY` | `0` | bool | `1` = send even if no changes (bypass dedup) |
| `AI_SUMMARIZE` | `auto` | enum | `auto` = use AI if available, `1` = always, `0` = never |
| `AI_SUMMARIZE_TIMEOUT` | `30` | integer | Seconds to wait for AI response |
| `SAFE_TIMEOUT_SEC` | `30` | integer | Timeout for `npm view` lookups |
| `AUTO_HEAL_ENABLED` | `1` | bool | `1` = self-repair on critical failures |
| `AUTO_HEAL_COOLDOWN_SEC` | `21600` | integer | Seconds between auto-heal triggers (default: 6h) |
| `TELEGRAM_NOTIFY` | `1` | bool | `1` = send report after update runs |
| `WATCHLIST_FILE` | `cron/update-watchlist.json` | path | Path to watchlist JSON |
| `OPENCLAW_BIN` | auto-detect | path | Explicit path to OpenClaw binary |
| `SAFE_RUN_LOGIN` | `1` | bool | `1` = use login shell for safe_run |

---

## Script Reference

| Script | Purpose | When to Use |
|--------|---------|-------------|
| `cron/check-updates-notify.sh` | Check all watchlisted packages for updates and send notification | Cron job (every 30 min) |
| `cron/run-all-updates.sh` | Update all packages that have updates available (via subagent) | After receiving update notification |
| `cron/run-all-updates-direct.sh` | Same as above but runs directly (no AI subagent) | Fallback if subagent unavailable |
| `cron/auto-update-all.sh` | Auto-update core packages (OpenClaw, Agent Browser, Codex CLI) | Daily cron |
| `cron/run-all-updates-via-subagent.sh` | Delegates the update run to an AI subagent | Called by the notification buttons |
| `scripts/e2e-update-check-validation.sh` | Mocked test suite (234 tests, no network) | CI/CD or manual verification |
| `scripts/docker-e2e-test.sh` | Docker-based E2E test (60 assertions) | Full environment testing |
| `scripts/run-docker-e2e.sh` | Docker test runner | Launches Dockerfile.e2e |

---

## Core Library Functions (`lib/common.sh`)

Key functions an AI agent should know about:

| Function | Signature | Description |
|----------|-----------|-------------|
| `safe_run` | `safe_run "command"` | Run command with timeout, return first line of stdout |
| `safe_run_all` | `safe_run_all "command"` | Run command with timeout, return all stdout |
| `run_with_retry` | `run_with_retry "cmd" "logfile" [timeout]` | Run with 2 retries, log output |
| `version_gt` | `version_gt "a" "b"` | True if version a > b (uses `sort -V`) |
| `version_lte` | `version_lte "a" "b"` | True if version a ≤ b |
| `normalize_version` | `normalize_version "v1.2.3"` → `1.2.3` | Strip prefixes (v, V, path, scope) |
| `npm_global_current_version` | `npm_global_current_version "pkg"` | Get currently installed version |
| `npm_latest_version` | `npm_latest_version "pkg"` | Get latest version from registry |
| `openclaw_latest_version` | `openclaw_latest_version` | Get latest OpenClaw version (native or npm fallback) |
| `get_update_command` | `get_update_command "pkg"` | Get the correct update command for a package |
| `get_update_key` | `get_update_key "@scope/pkg"` | Get sanitized callback key (no `/`, `@`, spaces) |
| `send_message` | `send_message "text" "buttons_json" "channel"` | Send via OpenClaw messaging |
| `send_message_json` | `send_message_json "text" "buttons" "channel"` | Send with `--json` response format |
| `send_to_all_channels` | `send_to_all_channels "text" "buttons"` | Send to configured channel(s) |
| `json_escape` | `json_escape "string"` | Escape `"`, `\`, and newlines for JSON |
| `shorten_line` | `shorten_line "text"` | Truncate to 240 chars, collapse whitespace |
| `validate_openclaw_config` | `validate_openclaw_config` | Returns 0 if config valid |
| `github_repo_from_npm` | `github_repo_from_npm "pkg"` | Extract `owner/repo` from npm metadata |
| `gather_raw_changelog` | `gather_raw_changelog "pkg" "from" "to"` | Collect changelog context |
| `ai_summarize_changelog` | `ai_summarize_changelog "pkg" "from" "to" "ctx" arr` | AI-summarize into 3 points |
| `build_raw_points` | `build_raw_points "pkg" "from" "to" arr` | Fallback: extract raw changelog |
| `package_whats_new_points` | `package_whats_new_points "pkg" "from" "to" arr` | Full pipeline: AI → fallback |
| `discover_new_global_npm_packages` | `discover_new_global_npm_packages "wl_file"` | Find new global pkgs |
| `sync_watchlist_npm` | `sync_watchlist_npm "wl_file"` | Add discovered pkgs to watchlist |
| `invalidate_npm_cache` | `invalidate_npm_cache` | Clear cached `npm ls -g` data |
| `update_npm_if_needed` | `update_npm_if_needed "pkg"` | Update single pkg if newer version exists |
| `update_snap_packages` | `update_snap_packages` | Process all snap packages |
| `run_full_update` | `run_full_update "title"` | Full update cycle: discover → update → report → notify |
| `log_info` | `log_info "message"` | Structured info log to stderr |
| `log_warn` | `log_warn "message"` | Structured warning log to stderr |

---

## OpenClaw Agent Configuration

### Minimal Setup (Model Provider Only)

```bash
openclaw config set models.providers.my-api.baseUrl "https://cliproxy.servas.ai/v1"
openclaw config set models.providers.my-api.apiKey "ccs-internal-managed"
openclaw config set models.providers.my-api.api "openai-completions"
openclaw config set models.default "my-api/gpt-4o-mini"
openclaw config set models.agentModel "my-api/gpt-4o-mini"
```

### Custom Agent with System Prompt

```bash
# Create agent directory
mkdir -p ~/.openclaw/agents/update-summarizer/agent

# Write system prompt
cat > ~/.openclaw/agents/update-summarizer/agent/HEARTBEAT.md << 'EOF'
Du bist ein Package-Update-Summarizer.
Fasse Changelogs immer in genau 3 kurzen deutschen Bullet Points zusammen.
Maximal 120 Zeichen pro Punkt. Keine Emojis.
EOF
```

### Agent Invocation

```bash
# Default agent (used by the scripts)
openclaw agent --local --message "Fasse zusammen: ..."

# Named agent
openclaw agent --local --agent update-summarizer --message "..."

# Via gateway
openclaw agent --agent update-summarizer --message "..."
```

### Agent Configuration in `~/.openclaw/openclaw.json`

```json
{
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
        "workspace": "/path/to/workspace",
        "agentDir": "/path/to/agent-config"
      }
    ]
  }
}
```

---

## Troubleshooting for AI Agents

| Symptom | Cause | Fix |
|---------|-------|-----|
| `openclaw config validate` fails | Missing or invalid API key | Run Step 4 to configure provider |
| `npm: command not found` | Node.js not installed | `nvm install 20` or `apt install nodejs` |
| `jq: command not found` | jq not installed | `apt install jq` |
| Tests fail with `[FAIL]` | Library function changed | Run `bash scripts/e2e-update-check-validation.sh` — check error message |
| No notification sent | Wrong `CHAT_ID` / `CHANNEL` | Verify env vars in Step 6 |
| `AI_SUMMARIZE` returns empty | Model provider unreachable | Check `openclaw config validate`, set `AI_SUMMARIZE=0` as fallback |
| Permission denied on scripts | Not executable | `chmod +x cron/*.sh scripts/*.sh` |
| Dedup blocks notification | Same update seen twice | Set `FORCE_NOTIFY=1` or delete state file |
| Auto-heal keeps triggering | Cooldown too short | Increase `AUTO_HEAL_COOLDOWN_SEC` |

---

## Data Flow (for AI understanding)

```
1. Cron triggers check-updates-notify.sh
2. sync_watchlist_npm() → auto-discovers new global npm packages
3. For each package in watchlist:
   a. npm_global_current_version() → get installed version (cached via _NPM_GLOBAL_CACHE)
   b. npm_latest_version() / openclaw_latest_version() → get latest version
   c. version_gt(latest, current) → compare
   d. If newer:
      i.  gather_raw_changelog() → fetch GitHub releases + npm description
      ii. AI_SUMMARIZE=1 → ai_summarize_changelog() → 3 bullet points
      iii.AI_SUMMARIZE=0 → build_raw_points() → 3 raw points
   e. add_update() → add to notification payload
4. Dedup: hash payload, compare to STATE_FILE
5. If new → format_update_message() + build_buttons_json() → send via Telegram/Matrix
6. If same → exit silently (unless FORCE_NOTIFY=1)
```

---

## File Modification Guide (for AI agents)

### Adding a new package manager (e.g., Homebrew)

1. Add `"brew": [...]` to `update-watchlist.json` schema
2. Add `brew_latest_version()` function to `lib/common.sh`
3. Add `brew_current_version()` function to `lib/common.sh`
4. Add processing loop in `check-updates-notify.sh` (see npm loop as template)
5. Add `update_brew_packages()` to `lib/common.sh` (see `update_snap_packages()`)
6. Add test suite to `scripts/e2e-update-check-validation.sh`

### Adding a new notification channel

1. Add channel name to the `send_message()` function's case statement in `lib/common.sh`
2. Update `send_to_all_channels()` to include the new channel
3. Add env var documentation to this file

### Modifying the AI prompt

The AI prompt is constructed inline in `ai_summarize_changelog()` in `lib/common.sh`. Search for `"Du bist ein technischer Changelog-Zusammenfasser"` to find it.

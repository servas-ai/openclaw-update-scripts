#!/usr/bin/env bash
set -euo pipefail

WATCHLIST_FILE="/home/coder/.openclaw/workspace/cron/update-watchlist.json"
CHAT_ID="-1003766760589"
THREAD_ID="16"
TELEGRAM_NOTIFY="${TELEGRAM_NOTIFY:-1}"

version_gt() {
  [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ] && [ "$1" != "$2" ]
}

safe_run() {
  bash -lc "$1" 2>/dev/null | head -n1 | tr -d '\r' || true
}

run_with_retry() {
  local cmd="$1"
  local log="$2"
  if timeout 900 bash -lc "$cmd" >"$log" 2>&1; then
    return 0
  fi
  timeout 900 bash -lc "$cmd" >>"$log" 2>&1
}

report=()
updated_count=0
failed_count=0
openclaw_config_valid=1

if command -v openclaw >/dev/null 2>&1; then
  if ! openclaw_validate_out="$(openclaw config validate 2>&1)"; then
    openclaw_config_valid=0
    openclaw_validate_out="$(printf '%s' "$openclaw_validate_out" | tr '\n\r' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
    report+=("• openclaw: Hinweis: config invalid, fallback auf npm registry (${openclaw_validate_out})")
  fi
fi

update_npm_if_needed() {
  local pkg="$1"
  local before latest after cmd key

  if [[ "$pkg" == "openclaw" ]]; then
    before="$(safe_run "npm ls -g openclaw --depth=0 --json | jq -r '.dependencies[\"openclaw\"].version // empty'")"
    latest=""
    if [[ "$openclaw_config_valid" == "1" ]]; then
      latest="$(safe_run "openclaw update status --json | jq -r '.update.registry.latestVersion // empty'")"
    fi
    if [[ -z "$latest" ]]; then
      latest="$(safe_run "npm view openclaw version")"
      report+=("• openclaw: Hinweis: latest via npm fallback ermittelt")
    fi
    cmd="openclaw update --channel stable --yes"
    key="openclaw"
  elif [[ "$pkg" == "@kaitranntt/ccs" ]]; then
    before="$(safe_run "npm ls -g @kaitranntt/ccs --depth=0 --json | jq -r '.dependencies[\"@kaitranntt/ccs\"].version // empty'")"
    latest="$(safe_run "npm view @kaitranntt/ccs version")"
    cmd="ccs update"
    key="kaitranntt-ccs"
  elif [[ "$pkg" == "opencode-ai" ]]; then
    before="$(safe_run "npm ls -g opencode-ai --depth=0 --json | jq -r '.dependencies[\"opencode-ai\"].version // empty'")"
    latest="$(safe_run "npm view opencode-ai version")"
    cmd="opencode upgrade"
    key="opencode-ai"
  elif [[ "$pkg" == "vibe-kanban" ]]; then
    before="$(safe_run "npm ls -g vibe-kanban --depth=0 --json | jq -r '.dependencies[\"vibe-kanban\"].version // empty'")"
    latest="$(safe_run "npm view vibe-kanban version")"
    cmd="npx -y vibe-kanban@latest --help >/dev/null 2>&1 || true"
    key="vibe-kanban"
  else
    before="$(safe_run "npm ls -g '$pkg' --depth=0 --json | jq -r --arg p '$pkg' '.dependencies[\$p].version // empty'")"
    latest="$(safe_run "npm view '$pkg' version")"
    cmd="npm install -g '$pkg'@latest"
    key="$(echo "$pkg" | tr '@/ ' '---')"
  fi

  if [[ -z "$before" || -z "$latest" ]]; then
    report+=("• ${pkg}: übersprungen (Version nicht lesbar)")
    return
  fi

  if ! version_gt "$latest" "$before"; then
    report+=("• ${pkg}: ${before} (aktuell)")
    return
  fi

  local log="/tmp/openclaw-update-${key}.log"
  if run_with_retry "$cmd" "$log"; then
    if [[ "$pkg" == "openclaw" ]]; then
      after="$(safe_run "npm ls -g openclaw --depth=0 --json | jq -r '.dependencies[\"openclaw\"].version // empty'")"
    else
      after="$(safe_run "npm ls -g '$pkg' --depth=0 --json | jq -r --arg p '$pkg' '.dependencies[\$p].version // empty'")"
    fi
    report+=("• ${pkg}: ${before} → ${after} ✅")
    updated_count=$((updated_count + 1))
  else
    if [[ "$pkg" == "openclaw" ]]; then
      after="$(safe_run "npm ls -g openclaw --depth=0 --json | jq -r '.dependencies[\"openclaw\"].version // empty'")"
    else
      after="$(safe_run "npm ls -g '$pkg' --depth=0 --json | jq -r --arg p '$pkg' '.dependencies[\$p].version // empty'")"
    fi
    local err
    err="$(tail -n 1 "$log" 2>/dev/null || echo 'unbekannter Fehler')"
    report+=("• ${pkg}: ${before} → ${after} ❌ (${err})")
    failed_count=$((failed_count + 1))
  fi
}

# npm watchlist
while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  update_npm_if_needed "$pkg"
done < <(jq -r '.npm[]? // empty' "$WATCHLIST_FILE")

# snap watchlist (optional)
if command -v snap >/dev/null 2>&1; then
  snap_updates_raw="$(timeout 60 snap refresh --list 2>/dev/null || true)"
  if [[ -n "$snap_updates_raw" ]]; then
    while IFS= read -r snap_name; do
      [[ -z "$snap_name" ]] && continue
      if printf '%s\n' "$snap_updates_raw" | awk -v n="$snap_name" 'NR>1 && $1==n {found=1} END{exit !found}'; then
        before="$(snap list "$snap_name" 2>/dev/null | awk 'NR==2{print $2}')"
        log="/tmp/openclaw-update-snap-${snap_name}.log"
        if run_with_retry "snap refresh '$snap_name'" "$log"; then
          after="$(snap list "$snap_name" 2>/dev/null | awk 'NR==2{print $2}')"
          report+=("• snap:${snap_name}: ${before} → ${after} ✅")
          updated_count=$((updated_count + 1))
        else
          after="$(snap list "$snap_name" 2>/dev/null | awk 'NR==2{print $2}')"
          err="$(tail -n 1 "$log" 2>/dev/null || echo 'unbekannter Fehler')"
          report+=("• snap:${snap_name}: ${before} → ${after} ❌ (${err})")
          failed_count=$((failed_count + 1))
        fi
      else
        current="$(snap list "$snap_name" 2>/dev/null | awk 'NR==2{print $2}')"
        [[ -n "$current" ]] && report+=("• snap:${snap_name}: ${current} (aktuell)")
      fi
    done < <(jq -r '.snap[]? // empty' "$WATCHLIST_FILE")
  fi
fi

for line in "${report[@]}"; do
  echo "$line"
done

if [[ "$TELEGRAM_NOTIFY" == "1" ]] && command -v openclaw >/dev/null 2>&1; then
  ts="$(date '+%d.%m.%Y %H:%M')"
  msg=$'✅ Update-Lauf abgeschlossen ('"$ts"$')\n\n'
  msg+="• Updated: ${updated_count}"$'\n'
  msg+="• Fehler: ${failed_count}"$'\n\n'
  for line in "${report[@]}"; do
    msg+="$line"$'\n'
  done

  openclaw message send \
    --channel telegram \
    --target "$CHAT_ID" \
    --thread-id "$THREAD_ID" \
    --message "$msg" >/dev/null || true
fi

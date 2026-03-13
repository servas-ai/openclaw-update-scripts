#!/usr/bin/env bash
set -euo pipefail

CHAT_ID="${CHAT_ID:--1003766760589}"
THREAD_ID="${THREAD_ID:-16}"
STATE_FILE="${STATE_FILE:-/home/coder/.openclaw/workspace/cron/.last-update-notify.json}"
MESSAGE_STATE_FILE="${MESSAGE_STATE_FILE:-/home/coder/.openclaw/workspace/cron/.last-update-message.json}"
WATCHLIST_FILE="${WATCHLIST_FILE:-/home/coder/.openclaw/workspace/cron/update-watchlist.json}"
OPENCLAW_BIN="${OPENCLAW_BIN:-/home/coder/.nvm/versions/node/v25.6.0/bin/openclaw}"
SAFE_TIMEOUT_SEC="${SAFE_TIMEOUT_SEC:-15}"
AUTO_HEAL_ENABLED="${AUTO_HEAL_ENABLED:-1}"
AUTO_HEAL_STATE_FILE="${AUTO_HEAL_STATE_FILE:-/home/coder/.openclaw/workspace/cron/.auto-heal-state.json}"
AUTO_HEAL_COOLDOWN_SEC="${AUTO_HEAL_COOLDOWN_SEC:-21600}"
AUTO_HEAL_SUBAGENT_RUNNER="${AUTO_HEAL_SUBAGENT_RUNNER:-/home/coder/.openclaw/workspace/cron/run-all-updates-via-subagent.sh}"
AUTO_HEAL_FALLBACK_RUNNER="${AUTO_HEAL_FALLBACK_RUNNER:-/home/coder/.openclaw/workspace/cron/run-all-updates-direct.sh}"
AUTO_HEAL_LOG="${AUTO_HEAL_LOG:-/tmp/openclaw-auto-heal.log}"
if [[ ! -x "$OPENCLAW_BIN" ]]; then
  OPENCLAW_BIN="$(command -v openclaw || true)"
fi
if [[ -x "$OPENCLAW_BIN" ]]; then
  OPENCLAW_CLI_AVAILABLE=1
else
  OPENCLAW_CLI_AVAILABLE=0
  OPENCLAW_BIN=""
fi

changelog_warnings=()

log_warn() {
  printf '[%s] [check-updates-notify] WARN: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

version_gt() {
  [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ] && [ "$1" != "$2" ]
}

version_lte() {
  ! version_gt "$1" "$2"
}

safe_run() {
  local cmd="$1"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$SAFE_TIMEOUT_SEC" bash -lc "$cmd" 2>/dev/null | head -n1 | tr -d '\r' || true
  else
    bash -lc "$cmd" 2>/dev/null | head -n1 | tr -d '\r' || true
  fi
}

safe_run_all() {
  local cmd="$1"
  if command -v timeout >/dev/null 2>&1; then
    timeout "$SAFE_TIMEOUT_SEC" bash -lc "$cmd" 2>/dev/null || true
  else
    bash -lc "$cmd" 2>/dev/null || true
  fi
}

shorten_line() {
  local input="$1"
  input="$(printf '%s' "$input" | tr '\n\r' ' ' | sed 's/[[:space:]]\+/ /g')"
  printf '%s' "$input" | cut -c1-240
}

normalize_version() {
  local raw="$1"
  raw="${raw##*/}"
  raw="${raw##*@}"
  raw="${raw#v}"
  raw="${raw#V}"
  printf '%s' "$raw"
}

json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/}"
  printf '%s' "$s"
}

read_last_message_id() {
  local file="$1"
  [[ -f "$file" ]] || return 0
  jq -r '.message_id // empty' "$file" 2>/dev/null || true
}

write_last_message_state() {
  local file="$1"
  local message_id="$2"
  local ts now_iso
  ts="$(date +%s)"
  now_iso="$(date -u +%FT%TZ)"
  cat > "$file" <<EOF
{"message_id":"$message_id","updated_at":"$now_iso","updated_ts":$ts}
EOF
}

send_telegram_message_json() {
  local message_text="$1"
  local buttons_json="$2"
  env -u OPENCLAW_GATEWAY_URL "$OPENCLAW_BIN" message send \
    --channel telegram \
    --target "$CHAT_ID" \
    --thread-id "$THREAD_ID" \
    --message "$message_text" \
    --buttons "$buttons_json" \
    --json
}

npm_global_current_version() {
  local pkg="$1"
  local esc_pkg
  esc_pkg="$(json_escape "$pkg")"

  # Robust lookup via npm's own JSON output (works for scoped names and special chars)
  safe_run "npm ls -g --depth=0 --json | jq -r '.dependencies[\"${esc_pkg}\"].version // empty'"
}

openclaw_latest_source="none"
openclaw_latest_version() {
  local latest=""

  # Prefer native OpenClaw status when CLI/config are usable
  if [[ "$OPENCLAW_CLI_AVAILABLE" == "1" && "$openclaw_config_valid" == "1" ]]; then
    latest="$(safe_run "$OPENCLAW_BIN update status --json | jq -r '.update.registry.latestVersion // empty'")"
    if [[ -n "$latest" ]]; then
      openclaw_latest_source="openclaw"
      printf '%s' "$latest"
      return 0
    fi
  fi

  # Stable fallback: npm registry
  latest="$(safe_run "npm view openclaw version")"
  if [[ -n "$latest" ]]; then
    openclaw_latest_source="npm"
  else
    openclaw_latest_source="none"
  fi
  printf '%s' "$latest"
}

github_repo_from_npm() {
  local pkg="$1"
  local repo
  repo="$(safe_run "npm view '$pkg' repository.url")"
  [[ -z "$repo" || "$repo" == "null" ]] && repo="$(safe_run "npm view '$pkg' repository")"
  repo="${repo#git+}"
  repo="${repo%.git}"

  if [[ "$repo" =~ github\.com[:/]([^/]+/[^/]+)$ ]]; then
    printf '%s' "${BASH_REMATCH[1]}"
    return 0
  fi
  return 1
}

release_summary_line() {
  local input="$1"
  local line
  line="$(printf '%s\n' "$input" | sed -E 's/\r//g' | sed '/^\s*$/d' | sed -E '/^\s*#/d' | sed -E '/^\s*```/d' | head -n1)"
  line="$(printf '%s' "$line" | sed -E 's/^\s*[-*+]\s+//' | sed -E 's/^\s*[0-9]+[.)]\s+//' | sed 's/[[:space:]]\+/ /g' | sed 's/^ //; s/ $//')"
  printf '%s' "$(shorten_line "$line")"
}

build_points_from_github_releases() {
  local pkg="$1"
  local current="$2"
  local latest="$3"
  local -n out_points=$4

  out_points=()

  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local repo releases_json line tag body norm summary count_in_range
  repo="$(github_repo_from_npm "$pkg" || true)"
  [[ -z "$repo" ]] && return 1

  releases_json="$(timeout 12 curl -fsSL "https://api.github.com/repos/${repo}/releases?per_page=40" 2>/dev/null || true)"
  if [[ -z "$releases_json" ]]; then
    changelog_warnings+=("${pkg}: GitHub release lookup fehlgeschlagen, nutze npm fallback")
    return 1
  fi

  count_in_range=0
  while IFS= read -r line; do
    tag="$(printf '%s' "$line" | jq -r '.tag')"
    body="$(printf '%s' "$line" | jq -r '.body')"
    norm="$(normalize_version "$tag")"
    [[ -z "$norm" ]] && continue

    if version_gt "$norm" "$current" && version_lte "$norm" "$latest"; then
      count_in_range=$((count_in_range + 1))
      summary="$(release_summary_line "$body")"
      if [[ -z "$summary" ]]; then
        out_points+=("${norm}: Release notes verfügbar")
      else
        out_points+=("${norm}: ${summary}")
      fi
      [[ "${#out_points[@]}" -ge 3 ]] && break
    fi
  done < <(printf '%s' "$releases_json" | jq -c '.[] | {tag:(.tag_name // ""), body:(.body // "")}')

  if [[ "${#out_points[@]}" -gt 0 ]]; then
    out_points=("Änderungen ${current} → ${latest} (${count_in_range} Releases im Bereich)" "${out_points[@]}")
    out_points=("${out_points[@]:0:3}")
    return 0
  fi

  return 1
}

package_whats_new_points() {
  local pkg="$1"
  local current="$2"
  local latest="$3"
  local -n out_points=$4
  local points=()

  if build_points_from_github_releases "$pkg" "$current" "$latest" points; then
    out_points=("${points[@]}")
    return 0
  fi

  local desc versions range_versions
  desc="$(safe_run "npm view '$pkg@$latest' description")"
  versions="$(safe_run_all "npm view '$pkg' versions --json | jq -r 'if type==\"array\" then .[] else empty end' | tail -n 20")"
  [[ -z "$versions" ]] && changelog_warnings+=("${pkg}: npm versions für Bereichsanalyse nicht verfügbar")

  if [[ -n "$versions" ]]; then
    mapfile -t range_versions < <(printf '%s\n' "$versions" | while IFS= read -r v; do
      [[ -z "$v" ]] && continue
      if version_gt "$v" "$current" && version_lte "$v" "$latest"; then
        printf '%s\n' "$v"
      fi
    done)
  else
    range_versions=()
  fi

  if [[ -n "$desc" ]]; then
    points+=("$(shorten_line "$desc")")
  else
    points+=("Änderungen ${current} → ${latest} (Details nicht direkt verfügbar)")
  fi

  if [[ "${#range_versions[@]}" -gt 0 ]]; then
    points+=("Versionen im Bereich: $(printf '%s, ' "${range_versions[@]:0:5}" | sed 's/, $//')")
  else
    points+=("Versionen im Bereich nicht verlässlich ermittelbar")
  fi

  points+=("Details: npm view ${pkg}@${latest} readme")

  while [[ "${#points[@]}" -lt 3 ]]; do
    points+=("Keine weiteren strukturierten Release-Notes gefunden")
  done

  out_points=("${points[@]:0:3}")
}

updates=()
json_items=()
lines=()
details=()
diagnostics=()
critical_lookup_failures=()
auto_heal_triggered=0
auto_heal_status_line=""

add_update() {
  local type="$1" key="$2" name="$3" current="$4" latest="$5"
  local p1 p2 p3
  updates+=("$name")
  json_items+=("{\"type\":\"${type}\",\"key\":\"${key}\",\"name\":\"${name}\",\"current\":\"${current}\",\"latest\":\"${latest}\"}")
  lines+=("• ${name}: ${current} → ${latest}")

  __points=()
  package_whats_new_points "$name" "$current" "$latest" __points
  p1="${__points[0]:-Keine Infos gefunden}"
  p2="${__points[1]:-Keine Infos gefunden}"
  p3="${__points[2]:-Keine Infos gefunden}"
  details+=("  - ${p1}")
  details+=("  - ${p2}")
  details+=("  - ${p3}")
}

maybe_trigger_auto_heal() {
  [[ "$AUTO_HEAL_ENABLED" == "1" ]] || return 0
  [[ "${#critical_lookup_failures[@]}" -gt 0 ]] || return 0

  local now sig_sorted signature last_ts last_signature age
  now="$(date +%s)"
  sig_sorted="$(printf '%s\n' "${critical_lookup_failures[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')"
  signature="version-lookup:${sig_sorted}"

  last_ts=0
  last_signature=""
  if [[ -f "$AUTO_HEAL_STATE_FILE" ]]; then
    last_ts="$(jq -r '.last_trigger_ts // 0' "$AUTO_HEAL_STATE_FILE" 2>/dev/null || echo 0)"
    last_signature="$(jq -r '.last_signature // ""' "$AUTO_HEAL_STATE_FILE" 2>/dev/null || echo "")"
  fi

  age=$((now - last_ts))
  if [[ "$signature" == "$last_signature" && "$age" -lt "$AUTO_HEAL_COOLDOWN_SEC" ]]; then
    auto_heal_status_line="Auto-Heal nicht erneut gestartet (Cooldown aktiv, ${age}s seit letztem Trigger)."
    return 0
  fi

  local reason runner_used="" trigger_ok=0
  reason="critical version lookup failed for: ${sig_sorted}"

  if [[ -x "$AUTO_HEAL_SUBAGENT_RUNNER" ]]; then
    if nohup env TELEGRAM_NOTIFY=0 AUTO_HEAL_REASON="$reason" "$AUTO_HEAL_SUBAGENT_RUNNER" >"$AUTO_HEAL_LOG" 2>&1 < /dev/null & then
      runner_used="subagent"
      trigger_ok=1
    fi
  fi

  if [[ "$trigger_ok" -ne 1 && -x "$AUTO_HEAL_FALLBACK_RUNNER" ]]; then
    if nohup env TELEGRAM_NOTIFY=0 AUTO_HEAL_REASON="$reason" "$AUTO_HEAL_FALLBACK_RUNNER" >"$AUTO_HEAL_LOG" 2>&1 < /dev/null & then
      runner_used="direct-fallback"
      trigger_ok=1
    fi
  fi

  if [[ "$trigger_ok" -eq 1 ]]; then
    auto_heal_triggered=1
    auto_heal_status_line="Auto-Heal gestartet via ${runner_used} (Reason: ${reason})."
    printf '{"last_trigger_ts":%s,"last_signature":"%s","last_runner":"%s"}\n' \
      "$now" "$(json_escape "$signature")" "$(json_escape "$runner_used")" > "$AUTO_HEAL_STATE_FILE"
  else
    auto_heal_status_line="Auto-Heal konnte nicht gestartet werden (kein nutzbarer Runner)."
    log_warn "$auto_heal_status_line"
  fi
}

if [[ ! -f "$WATCHLIST_FILE" ]]; then
  echo "watchlist missing: $WATCHLIST_FILE" >&2
  exit 1
fi

openclaw_config_valid=1
if [[ "$OPENCLAW_CLI_AVAILABLE" == "1" ]]; then
  if ! validate_out="$($OPENCLAW_BIN config validate 2>&1)"; then
    openclaw_config_valid=0
    msg="OpenClaw config invalid: $(shorten_line "$validate_out"). Update checks continue with fallback (npm registry). Fix with: openclaw config validate"
    diagnostics+=("$msg")
    log_warn "$msg"
  fi
else
  openclaw_config_valid=0
  diagnostics+=("OpenClaw CLI not found; using npm fallback for openclaw latest version lookup.")
fi

# --- npm packages from watchlist ---
while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue

  if [[ "$pkg" == "openclaw" ]]; then
    current="$(npm_global_current_version "$pkg")"
    latest="$(openclaw_latest_version)"

    if [[ -z "$latest" ]]; then
      diagnostics+=("openclaw latest version lookup failed (openclaw + npm fallback exhausted).")
      critical_lookup_failures+=("openclaw:latest")
    elif [[ "$openclaw_latest_source" == "npm" && "$OPENCLAW_CLI_AVAILABLE" == "1" && "$openclaw_config_valid" == "1" ]]; then
      diagnostics+=("openclaw update status failed; used npm fallback for latest version.")
    fi
  else
    current="$(npm_global_current_version "$pkg")"
    latest="$(safe_run "npm view '$pkg' version")"
  fi

  if [[ -z "$current" || -z "$latest" ]]; then
    diagnostics+=("Version lookup failed for ${pkg} (current='${current:-n/a}', latest='${latest:-n/a}').")
    critical_lookup_failures+=("${pkg}")
    continue
  fi

  if version_gt "$latest" "$current"; then
    add_update "npm" "$pkg" "$pkg" "$current" "$latest"
  fi
done < <(jq -r '.npm[]? // empty' "$WATCHLIST_FILE")

# --- snap packages from watchlist ---
if command -v snap >/dev/null 2>&1; then
  snap_updates_raw="$(timeout 60 snap refresh --list 2>/dev/null || true)"
  if [[ -n "$snap_updates_raw" ]]; then
    while IFS= read -r snap_name; do
      [[ -z "$snap_name" ]] && continue
      row="$(printf '%s\n' "$snap_updates_raw" | awk -v n="$snap_name" 'NR>1 && $1==n {print $0}')"
      [[ -z "$row" ]] && continue

      current="$(snap list "$snap_name" 2>/dev/null | awk 'NR==2{print $2}')"
      latest="$(printf '%s\n' "$row" | awk '{print $2}')"
      if [[ -z "$current" || -z "$latest" ]]; then
        diagnostics+=("Version lookup failed for snap:${snap_name} (current='${current:-n/a}', latest='${latest:-n/a}').")
        critical_lookup_failures+=("snap:${snap_name}")
        continue
      fi

      add_update "snap" "$snap_name" "snap:$snap_name" "$current" "$latest"
    done < <(watchlist_entries "snap")
  fi
fi

maybe_trigger_auto_heal

count="${#updates[@]}"
payload="[$(IFS=,; echo "${json_items[*]}")]"

if [[ "${FORCE_NOTIFY:-0}" != "1" ]]; then
  last=""
  [[ -f "$STATE_FILE" ]] && last="$(cat "$STATE_FILE" 2>/dev/null || true)"
  [[ "$last" == "$payload" && "$auto_heal_triggered" -eq 0 ]] && exit 0
fi
printf '%s' "$payload" > "$STATE_FILE"

# no updates + no auto-heal -> stay quiet
if [[ "$count" -eq 0 && "$auto_heal_triggered" -eq 0 ]]; then
  for diag in "${diagnostics[@]}"; do
    log_warn "$diag"
  done
  exit 0
fi

now="$(date '+%d.%m.%Y %H:%M')"

# consolidated auto-heal message (no spam / no action buttons)
if [[ "$auto_heal_triggered" -eq 1 ]]; then
  msg=$'🛠 Auto-Heal aktiv ('"$now"$')\n\n'
  msg+="Kritischer Version-Lookup-Fehler erkannt. Reparatur-Task wurde automatisch gestartet."$'\n'
  msg+="• Betroffen: $(printf '%s, ' "$(printf '%s\n' "${critical_lookup_failures[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')" | sed 's/, $//')"$'\n'
  msg+="• Status: ${auto_heal_status_line}"$'\n'
  msg+="• Log: ${AUTO_HEAL_LOG}"$'\n'

  if [[ "$count" -gt 0 ]]; then
    msg+=$'\nParallel gefundene Updates (Kurzliste):\n'
    for l in "${lines[@]}"; do
      msg+="$l"$'\n'
    done
  fi

  if [[ "${#diagnostics[@]}" -gt 0 || "${#changelog_warnings[@]}" -gt 0 ]]; then
    msg+=$'\n⚠️ Hinweise:\n'
    for diag in "${diagnostics[@]}"; do
      msg+="• $diag"$'\n'
    done
    for warn in "${changelog_warnings[@]}"; do
      msg+="• $warn"$'\n'
    done
  fi

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '%s\n' "$msg"
    exit 0
  fi

  if ! env -u OPENCLAW_GATEWAY_URL "$OPENCLAW_BIN" message send \
    --channel telegram \
    --target "$CHAT_ID" \
    --thread-id "$THREAD_ID" \
    --message "$msg" >/dev/null; then
    log_warn "Telegram auto-heal summary failed (non-fatal)."
  fi
  exit 0
fi

msg=$'🔔 Update verfügbar ('"$now"$')\n\n'
msg+="Anzahl Updates: ${count}"$'\n\n'
if [[ "${#lines[@]}" -gt 0 ]]; then
  for i in "${!lines[@]}"; do
    msg+="${lines[$i]}"$'\n'
    base=$((i*3))
    [[ -n "${details[$base]:-}" ]] && msg+="${details[$base]}"$'\n'
    [[ -n "${details[$((base+1))]:-}" ]] && msg+="${details[$((base+1))]}"$'\n'
    [[ -n "${details[$((base+2))]:-}" ]] && msg+="${details[$((base+2))]}"$'\n'
  done
fi

if [[ "${#diagnostics[@]}" -gt 0 || "${#changelog_warnings[@]}" -gt 0 ]]; then
  msg+=$'\n⚠️ Hinweise:\n'
  for diag in "${diagnostics[@]}"; do
    msg+="• $diag"$'\n'
  done
  for warn in "${changelog_warnings[@]}"; do
    msg+="• $warn"$'\n'
  done
fi

msg+=$'\nSoll i alles updaten?'

buttons='[[{"text":"✅ Ja, alle updaten","callback_data":"update_all_yes"},{"text":"❌ Nein","callback_data":"update_all_no"}]]'

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  printf '%s\n' "$msg"
  exit 0
fi

if ! env -u OPENCLAW_GATEWAY_URL "$OPENCLAW_BIN" message send \
  --channel telegram \
  --target "$CHAT_ID" \
  --thread-id "$THREAD_ID" \
  --message "$msg" \
  --buttons "$buttons" >/dev/null; then
  log_warn "Telegram notify failed (non-fatal). Updates were still detected."
fi

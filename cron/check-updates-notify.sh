#!/usr/bin/env bash
set -euo pipefail

# ─── Source shared library ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="check-updates-notify"
source "$SCRIPT_DIR/../lib/common.sh"

# ─── Script-specific config ───────────────────────────────────────────────────
STATE_FILE="${STATE_FILE:-${SCRIPT_DIR}/.last-update-notify.json}"
MESSAGE_STATE_FILE="${MESSAGE_STATE_FILE:-${SCRIPT_DIR}/.last-update-message.json}"
AUTO_HEAL_ENABLED="${AUTO_HEAL_ENABLED:-1}"
AUTO_HEAL_STATE_FILE="${AUTO_HEAL_STATE_FILE:-${SCRIPT_DIR}/.auto-heal-state.json}"
AUTO_HEAL_COOLDOWN_SEC="${AUTO_HEAL_COOLDOWN_SEC:-21600}"
AUTO_HEAL_SUBAGENT_RUNNER="${AUTO_HEAL_SUBAGENT_RUNNER:-${SCRIPT_DIR}/run-all-updates-via-subagent.sh}"
AUTO_HEAL_FALLBACK_RUNNER="${AUTO_HEAL_FALLBACK_RUNNER:-${SCRIPT_DIR}/run-all-updates-direct.sh}"
AUTO_HEAL_LOG="${AUTO_HEAL_LOG:-/tmp/openclaw-auto-heal.log}"

# ─── State arrays ─────────────────────────────────────────────────────────────
changelog_warnings=()
updates=()
json_items=()
lines=()
details=()
diagnostics=()
critical_lookup_failures=()
auto_heal_triggered=0
auto_heal_status_line=""

# ─── Helper: read/write message state ─────────────────────────────────────────
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

# ─── Add update to tracking arrays ────────────────────────────────────────────
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
  details+=("  📋 ${p1}")
  details+=("  📋 ${p2}")
  details+=("  📋 ${p3}")
}

# ─── Auto-heal logic ──────────────────────────────────────────────────────────
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
    auto_heal_status_line="Auto-Heal Cooldown aktiv (${age}s seit letztem Trigger)."
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

# ─── Format: Telegram update message (rich UI) ────────────────────────────────
format_update_message() {
  local count="$1"
  local now
  now="$(date '+%d.%m.%Y %H:%M')"

  local msg=""
  msg+=$'🔔 Update verfügbar ('"$now"$')\n'
  msg+=$'━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
  msg+="📦 ${count} Update(s) gefunden:"$'\n\n'

  if [[ "${#lines[@]}" -gt 0 ]]; then
    for i in "${!lines[@]}"; do
      msg+="${lines[$i]}"$'\n'
      local base=$((i*3))
      [[ -n "${details[$base]:-}" ]] && msg+="${details[$base]}"$'\n'
      [[ -n "${details[$((base+1))]:-}" ]] && msg+="${details[$((base+1))]}"$'\n'
      [[ -n "${details[$((base+2))]:-}" ]] && msg+="${details[$((base+2))]}"$'\n'
      msg+=$'\n'
    done
  fi

  if [[ "${#diagnostics[@]}" -gt 0 || "${#changelog_warnings[@]}" -gt 0 ]]; then
    msg+=$'⚠️ Hinweise:\n'
    for diag in "${diagnostics[@]}"; do
      msg+="• $diag"$'\n'
    done
    for warn in "${changelog_warnings[@]}"; do
      msg+="• $warn"$'\n'
    done
    msg+=$'\n'
  fi

  msg+=$'━━━━━━━━━━━━━━━━━━━━━━━━━\n'
  msg+=$'Soll i updaten?\n'
  printf '%s' "$msg"
}

# ─── Format: Auto-heal message ────────────────────────────────────────────────
format_auto_heal_message() {
  local now
  now="$(date '+%d.%m.%Y %H:%M')"

  local msg=""
  msg+=$'🛠 Auto-Heal aktiv ('"$now"$')\n'
  msg+=$'━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
  msg+="Kritischer Version-Lookup-Fehler erkannt."$'\n'
  msg+="Reparatur-Task wurde automatisch gestartet."$'\n\n'
  msg+="• Betroffen: $(printf '%s\n' "${critical_lookup_failures[@]}" | sort -u | tr '\n' ',' | sed 's/,$//')"$'\n'
  msg+="• Status: ${auto_heal_status_line}"$'\n'
  msg+="• Log: ${AUTO_HEAL_LOG}"$'\n'

  if [[ "${#updates[@]}" -gt 0 ]]; then
    msg+=$'\n📦 Parallel gefundene Updates:\n'
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

  printf '%s' "$msg"
}

# ─── Build per-package buttons ─────────────────────────────────────────────────
build_buttons_json() {
  local count="$1"

  if [[ "$count" -le 1 ]]; then
    # Single update: simple yes/no
    echo '[[{"text":"✅ Ja, updaten","callback_data":"update_all_yes"},{"text":"❌ Nein","callback_data":"update_all_no"}]]'
    return
  fi

  # Multiple updates: all + select
  local buttons='['
  buttons+='[{"text":"✅ Alle updaten","callback_data":"update_all_yes"},{"text":"❌ Nein, danke","callback_data":"update_all_no"}]'

  # Per-package rows (max 4 to avoid Telegram limit)
  local pkg_count=0
  for i in "${!updates[@]}"; do
    [[ $pkg_count -ge 4 ]] && break
    local name="${updates[$i]}"
    local short_name="${name##*/}"  # Strip scope for display
    local cb_data="update_single_${name}"
    if [[ $((pkg_count % 2)) -eq 0 ]]; then
      buttons+=',['
    fi
    buttons+="{\"text\":\"📦 ${short_name}\",\"callback_data\":\"${cb_data}\"}"
    if [[ $((pkg_count % 2)) -eq 1 || $pkg_count -eq $((${#updates[@]} - 1)) ]]; then
      buttons+=']'
    else
      buttons+=','
    fi
    pkg_count=$((pkg_count + 1))
  done

  buttons+=']'
  echo "$buttons"
}

# ════════════════════════════════════════════════════════════════════════════════
# MAIN
# ════════════════════════════════════════════════════════════════════════════════

if [[ ! -f "$WATCHLIST_FILE" ]]; then
  echo "watchlist missing: $WATCHLIST_FILE" >&2
  exit 1
fi

# Validate OpenClaw config
if ! validate_openclaw_config; then
  msg="OpenClaw config invalid. Update checks continue with fallback (npm registry)."
  diagnostics+=("$msg")
  log_warn "$msg"
fi

# ─── Auto-discover new global npm packages ─────────────────────────────────────
sync_count="$(sync_watchlist_npm "$WATCHLIST_FILE")"
if [[ "$sync_count" -gt 0 ]]; then
  log_info "Watchlist: $sync_count new global package(s) added."
fi

# ─── npm packages from watchlist ───────────────────────────────────────────────
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
    latest="$(npm_latest_version "$pkg")"
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

# ─── snap packages from watchlist (BUG FIX: was using undefined watchlist_entries) ─
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
    done < <(jq -r '.snap[]? // empty' "$WATCHLIST_FILE")
  fi
fi

# ─── go packages from watchlist ────────────────────────────────────────────────
while IFS= read -r go_pkg; do
  [[ -z "$go_pkg" ]] && continue
  # go packages need custom handling — skip for now, just check if binary exists
  if command -v "$go_pkg" >/dev/null 2>&1; then
    current="$("$go_pkg" --version 2>/dev/null | head -1 | grep -oP '[0-9]+\.[0-9]+\.[0-9]+' || true)"
    if [[ -n "$current" ]]; then
      log_info "go package $go_pkg: current=$current (auto-update not supported)"
    fi
  fi
done < <(jq -r '.go[]? // empty' "$WATCHLIST_FILE")

# ─── Auto-heal ────────────────────────────────────────────────────────────────
maybe_trigger_auto_heal

count="${#updates[@]}"
payload="[$(IFS=,; echo "${json_items[*]}")]"

# ─── Dedup: skip if same payload and no auto-heal ─────────────────────────────
if [[ "${FORCE_NOTIFY:-0}" != "1" ]]; then
  last=""
  [[ -f "$STATE_FILE" ]] && last="$(cat "$STATE_FILE" 2>/dev/null || true)"
  [[ "$last" == "$payload" && "$auto_heal_triggered" -eq 0 ]] && exit 0
fi
printf '%s' "$payload" > "$STATE_FILE"

# No updates + no auto-heal → stay quiet
if [[ "$count" -eq 0 && "$auto_heal_triggered" -eq 0 ]]; then
  for diag in "${diagnostics[@]}"; do
    log_warn "$diag"
  done
  exit 0
fi

# ─── Send messages ─────────────────────────────────────────────────────────────

# Auto-heal message (no action buttons)
if [[ "$auto_heal_triggered" -eq 1 ]]; then
  msg="$(format_auto_heal_message)"

  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    printf '%s\n' "$msg"
    exit 0
  fi

  send_to_all_channels "$msg" || log_warn "Auto-heal Nachricht konnte nicht gesendet werden."
  exit 0
fi

# ─── Update notification with buttons ──────────────────────────────────────────
msg="$(format_update_message "$count")"
buttons="$(build_buttons_json "$count")"

if [[ "${DRY_RUN:-0}" == "1" ]]; then
  printf '%s\n' "$msg"
  echo "---BUTTONS---"
  printf '%s\n' "$buttons"
  exit 0
fi

if ! send_to_all_channels "$msg" "$buttons"; then
  log_warn "Telegram/Matrix notify failed (non-fatal). Updates were still detected."
fi

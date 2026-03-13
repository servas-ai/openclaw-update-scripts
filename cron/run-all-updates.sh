#!/usr/bin/env bash
set -euo pipefail

# ─── Source shared library ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="run-all-updates"
source "$SCRIPT_DIR/../lib/common.sh"

# ─── Script-specific config ───────────────────────────────────────────────────
TELEGRAM_NOTIFY="${TELEGRAM_NOTIFY:-1}"

# ─── State ─────────────────────────────────────────────────────────────────────
report=()
updated_count=0
failed_count=0
skipped_count=0

# ─── Validate OpenClaw config ─────────────────────────────────────────────────
if ! validate_openclaw_config; then
  openclaw_validate_out="$($OPENCLAW_BIN config validate 2>&1 || true)"
  openclaw_validate_out="$(printf '%s' "$openclaw_validate_out" | tr '\n\r' ' ' | sed 's/[[:space:]]\+/ /g' | cut -c1-220)"
  report+=("⚙️ openclaw config: fallback auf npm registry (${openclaw_validate_out})")
fi

# ─── Update a single npm package ──────────────────────────────────────────────
update_npm_if_needed() {
  local pkg="$1"
  local before latest after cmd key log

  # Get current version using the fixed scoped-package-safe function
  before="$(npm_global_current_version "$pkg")"

  # Get latest version
  if [[ "$pkg" == "openclaw" ]]; then
    latest="$(openclaw_latest_version)"
    if [[ "$openclaw_latest_source" == "npm" ]]; then
      report+=("  ℹ️ openclaw: latest via npm fallback ermittelt")
    fi
  else
    latest="$(npm_latest_version "$pkg")"
  fi

  # Get the update command from shared lib
  cmd="$(get_update_command "$pkg")"
  key="$(get_update_key "$pkg")"

  if [[ -z "$before" || -z "$latest" ]]; then
    report+=("⏭️ ${pkg}: übersprungen (Version nicht lesbar, before='${before:-?}', latest='${latest:-?}')")
    skipped_count=$((skipped_count + 1))
    return
  fi

  if ! version_gt "$latest" "$before"; then
    report+=("✅ ${pkg}: ${before} (aktuell)")
    return
  fi

  log="/tmp/openclaw-update-${key}.log"
  log_info "Updating ${pkg}: ${before} → ${latest} via: ${cmd}"

  if run_with_retry "$cmd" "$log"; then
    after="$(npm_global_current_version "$pkg")"
    if [[ -n "$after" ]] && version_gt "$after" "$before"; then
      report+=("✅ ${pkg}: ${before} → ${after}")
      updated_count=$((updated_count + 1))
    elif [[ "$after" == "$before" ]]; then
      # Command succeeded but version didn't change
      report+=("⚠️ ${pkg}: ${before} → ${after} (Befehl OK, Version unverändert)")
    else
      report+=("✅ ${pkg}: ${before} → ${after:-?}")
      updated_count=$((updated_count + 1))
    fi
  else
    after="$(npm_global_current_version "$pkg")"
    local err
    err="$(tail -n 3 "$log" 2>/dev/null | tr '\n' ' ' | cut -c1-200 || echo 'unbekannter Fehler')"
    report+=("❌ ${pkg}: ${before} → ${after:-?} (${err})")
    report+=("  📄 Log: ${log}")
    failed_count=$((failed_count + 1))
  fi
}

# ─── npm watchlist ─────────────────────────────────────────────────────────────
while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue
  update_npm_if_needed "$pkg"
done < <(jq -r '.npm[]? // empty' "$WATCHLIST_FILE")

# ─── snap watchlist ────────────────────────────────────────────────────────────
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
          report+=("✅ snap:${snap_name}: ${before} → ${after}")
          updated_count=$((updated_count + 1))
        else
          after="$(snap list "$snap_name" 2>/dev/null | awk 'NR==2{print $2}')"
          err="$(tail -n 1 "$log" 2>/dev/null || echo 'unbekannter Fehler')"
          report+=("❌ snap:${snap_name}: ${before} → ${after} (${err})")
          failed_count=$((failed_count + 1))
        fi
      else
        current="$(snap list "$snap_name" 2>/dev/null | awk 'NR==2{print $2}')"
        [[ -n "$current" ]] && report+=("✅ snap:${snap_name}: ${current} (aktuell)")
      fi
    done < <(jq -r '.snap[]? // empty' "$WATCHLIST_FILE")
  fi
fi

# ─── Console output ───────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════"
echo "  Update-Lauf Ergebnis"
echo "═══════════════════════════════════════"
echo ""
for line in "${report[@]}"; do
  echo "  $line"
done
echo ""
echo "  Updated: ${updated_count} | Fehler: ${failed_count} | Übersprungen: ${skipped_count}"
echo "═══════════════════════════════════════"

# ─── Telegram/Matrix notification ─────────────────────────────────────────────
if [[ "$TELEGRAM_NOTIFY" == "1" && "$OPENCLAW_CLI_AVAILABLE" == "1" ]]; then
  ts="$(date '+%d.%m.%Y %H:%M')"

  local_status="✅"
  [[ "$failed_count" -gt 0 ]] && local_status="⚠️"

  msg="${local_status} Update-Lauf abgeschlossen (${ts})"$'\n'
  msg+=$'━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'
  msg+="📊 Updated: ${updated_count} | Fehler: ${failed_count} | Übersprungen: ${skipped_count}"$'\n\n'

  for line in "${report[@]}"; do
    msg+="$line"$'\n'
  done

  send_to_all_channels "$msg" || log_warn "Abschluss-Nachricht konnte nicht gesendet werden."
fi

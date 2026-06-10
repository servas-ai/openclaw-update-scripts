#!/usr/bin/env bash
set -euo pipefail

# ─── Auto-Update + Notify ──────────────────────────────────────────────────────
# Checks for updates, installs them automatically, and sends a Telegram/Matrix
# report with AI-summarized changelogs (3 bullet points per package).
# No interactive buttons — fully automated.
# ─────────────────────────────────────────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT_NAME="auto-update-notify"
source "$SCRIPT_DIR/../lib/common.sh"

# ─── Config ────────────────────────────────────────────────────────────────────
TELEGRAM_NOTIFY="${TELEGRAM_NOTIFY:-1}"

# ─── State ─────────────────────────────────────────────────────────────────────
report=()
updated_count=0
failed_count=0
skipped_count=0
current_count=0

# Changelog tracking for the notification message
declare -A pkg_before=()
declare -A pkg_after=()
declare -A pkg_changelog_1=()
declare -A pkg_changelog_2=()
declare -A pkg_changelog_3=()
pkg_order=()

# ─── Validate OpenClaw config ─────────────────────────────────────────────────
if ! validate_openclaw_config; then
  log_warn "OpenClaw config invalid — AI changelogs may use fallback."
fi

# ─── Auto-discover new packages ───────────────────────────────────────────────
sync_count="$(sync_watchlist_npm "$WATCHLIST_FILE")"
[[ "$sync_count" -gt 0 ]] && log_info "Watchlist: $sync_count new global package(s) added."

# ─── Check + Update each npm package ──────────────────────────────────────────
while IFS= read -r pkg; do
  [[ -z "$pkg" ]] && continue

  before="$(npm_global_current_version "$pkg")"

  if [[ "$pkg" == "openclaw" ]]; then
    latest="$(openclaw_latest_version)"
  else
    latest="$(npm_latest_version "$pkg")"
  fi

  if [[ -z "$before" || -z "$latest" ]]; then
    log_warn "Skipping $pkg: version not readable (before='${before:-?}', latest='${latest:-?}')"
    skipped_count=$((skipped_count + 1))
    continue
  fi

  if ! version_gt "$latest" "$before"; then
    current_count=$((current_count + 1))
    continue
  fi

  # ── Update available → run update ────────────────────────────────────────
  cmd="$(get_update_command "$pkg")"
  key="$(get_update_key "$pkg")"
  log="/tmp/openclaw-update-${key}.log"

  log_info "Updating ${pkg}: ${before} → ${latest} via: ${cmd}"

  if run_with_retry "$cmd" "$log"; then
    invalidate_npm_cache
    after="$(npm_global_current_version "$pkg")"
    if [[ -n "$after" ]] && version_gt "$after" "$before"; then
      report+=("✅ ${pkg}: ${before} → ${after}")
      pkg_before["$pkg"]="$before"
      pkg_after["$pkg"]="$after"
      pkg_order+=("$pkg")
      updated_count=$((updated_count + 1))

      # Gather changelog for this package
      __points=()
      package_whats_new_points "$pkg" "$before" "$after" __points
      pkg_changelog_1["$pkg"]="${__points[0]:-Keine Infos gefunden}"
      pkg_changelog_2["$pkg"]="${__points[1]:-Keine Infos gefunden}"
      pkg_changelog_3["$pkg"]="${__points[2]:-Keine Infos gefunden}"
    elif [[ "$after" == "$before" ]]; then
      report+=("⚠️ ${pkg}: ${before} (Befehl OK, Version unverändert)")
    else
      report+=("✅ ${pkg}: ${before} → ${after:-?}")
      updated_count=$((updated_count + 1))
    fi
  else
    invalidate_npm_cache
    after="$(npm_global_current_version "$pkg")"
    local_err="$(tail -n 3 "$log" 2>/dev/null | tr '\n' ' ' | cut -c1-200 || echo 'unbekannter Fehler')"
    report+=("❌ ${pkg}: ${before} → ${after:-?} (${local_err})")
    report+=("  📄 Log: ${log}")
    failed_count=$((failed_count + 1))
  fi
done < <(jq -r '.npm[]? // empty' "$WATCHLIST_FILE")

# ─── Snap packages ────────────────────────────────────────────────────────────
update_snap_packages

# ─── DRY_RUN: print to stdout ─────────────────────────────────────────────────
if [[ "${DRY_RUN:-0}" == "1" ]]; then
  echo ""
  echo "═══════════════════════════════════════"
  echo "  Auto-Update Report (DRY_RUN)"
  echo "═══════════════════════════════════════"
  echo ""
  echo "  Updated: ${updated_count} | Fehler: ${failed_count} | Aktuell: ${current_count} | Übersprungen: ${skipped_count}"
  echo ""
  for line in "${report[@]}"; do
    echo "  $line"
  done
  if [[ "${#pkg_order[@]}" -gt 0 ]]; then
    echo ""
    echo "  Changelogs:"
    for p in "${pkg_order[@]}"; do
      echo "  • ${p}: ${pkg_before[$p]} → ${pkg_after[$p]}"
      echo "    📋 ${pkg_changelog_1[$p]}"
      echo "    📋 ${pkg_changelog_2[$p]}"
      echo "    📋 ${pkg_changelog_3[$p]}"
    done
  fi
  echo "═══════════════════════════════════════"
  exit 0
fi

# ─── Nothing updated? Exit silently ───────────────────────────────────────────
if [[ "$updated_count" -eq 0 && "$failed_count" -eq 0 ]]; then
  log_info "No updates available. ${current_count} package(s) are current."
  exit 0
fi

# ─── Build and send notification ──────────────────────────────────────────────
ts="$(date '+%d.%m.%Y %H:%M')"
status="✅"
[[ "$failed_count" -gt 0 ]] && status="⚠️"

msg="${status} Auto-Update abgeschlossen (${ts})"$'\n'
msg+=$'━━━━━━━━━━━━━━━━━━━━━━━━━\n\n'

if [[ "${#pkg_order[@]}" -gt 0 ]]; then
  msg+="📦 ${updated_count} Package(s) aktualisiert:"$'\n\n'
  for p in "${pkg_order[@]}"; do
    msg+="• ${p}: ${pkg_before[$p]} → ${pkg_after[$p]}"$'\n'
    msg+="  📋 ${pkg_changelog_1[$p]}"$'\n'
    msg+="  📋 ${pkg_changelog_2[$p]}"$'\n'
    msg+="  📋 ${pkg_changelog_3[$p]}"$'\n\n'
  done
fi

if [[ "$failed_count" -gt 0 ]]; then
  msg+=$'❌ Fehler:\n'
  for line in "${report[@]}"; do
    [[ "$line" == ❌* || "$line" == "  📄"* ]] && msg+="$line"$'\n'
  done
  msg+=$'\n'
fi

msg+="📊 Updated: ${updated_count} | Fehler: ${failed_count} | Aktuell: ${current_count}"$'\n'

if [[ "$OPENCLAW_CLI_AVAILABLE" == "1" && "${TELEGRAM_NOTIFY}" == "1" ]]; then
  send_to_all_channels "$msg" || log_warn "Auto-Update Nachricht konnte nicht gesendet werden."
fi

# Print report to stdout as well
print_update_report "Auto-Update Ergebnis"

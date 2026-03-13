#!/usr/bin/env bash
# lib/common.sh — Shared functions for openclaw-update-scripts
# Source this file: SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#                   source "$SCRIPT_DIR/../lib/common.sh"

# ─── Defaults ──────────────────────────────────────────────────────────────────
CHAT_ID="${CHAT_ID:--1003766760589}"
THREAD_ID="${THREAD_ID:-16}"
CHANNEL="${CHANNEL:-telegram}"
SAFE_TIMEOUT_SEC="${SAFE_TIMEOUT_SEC:-30}"
WATCHLIST_FILE="${WATCHLIST_FILE:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/cron/update-watchlist.json}"

# ─── Resolve OpenClaw binary ──────────────────────────────────────────────────
resolve_openclaw_bin() {
  local bin="${OPENCLAW_BIN:-}"
  if [[ -n "$bin" && -x "$bin" ]]; then
    printf '%s' "$bin"
    return 0
  fi
  # Try common locations
  for candidate in \
    "$(command -v openclaw 2>/dev/null || true)" \
    "/home/coder/.nvm/versions/node/v25.6.0/bin/openclaw" \
    "/usr/bin/openclaw" \
    "/usr/local/bin/openclaw"; do
    if [[ -n "$candidate" && -x "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  done
  return 1
}

OPENCLAW_BIN="${OPENCLAW_BIN:-$(resolve_openclaw_bin || true)}"
if [[ -n "$OPENCLAW_BIN" && -x "$OPENCLAW_BIN" ]]; then
  OPENCLAW_CLI_AVAILABLE=1
else
  OPENCLAW_CLI_AVAILABLE=0
  OPENCLAW_BIN=""
fi

# ─── Validate OpenClaw config ─────────────────────────────────────────────────
openclaw_config_valid=0
validate_openclaw_config() {
  if [[ "$OPENCLAW_CLI_AVAILABLE" != "1" ]]; then
    openclaw_config_valid=0
    return 1
  fi
  if $OPENCLAW_BIN config validate >/dev/null 2>&1; then
    openclaw_config_valid=1
    return 0
  else
    openclaw_config_valid=0
    return 1
  fi
}

# ─── Logging ───────────────────────────────────────────────────────────────────
log_warn() {
  printf '[%s] [%s] WARN: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${SCRIPT_NAME:-openclaw-update}" "$*" >&2
}

log_info() {
  printf '[%s] [%s] INFO: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "${SCRIPT_NAME:-openclaw-update}" "$*" >&2
}

# ─── Version comparison ───────────────────────────────────────────────────────
version_gt() {
  [ "$(printf '%s\n' "$1" "$2" | sort -V | tail -n1)" = "$1" ] && [ "$1" != "$2" ]
}

version_lte() {
  ! version_gt "$1" "$2"
}

# ─── Safe execution with timeout ──────────────────────────────────────────────
# Set SAFE_RUN_LOGIN=0 to use bash -c instead of bash -lc (for tests with mock PATHs)
SAFE_RUN_LOGIN="${SAFE_RUN_LOGIN:-1}"

safe_run() {
  local cmd="$1"
  local shell_flag="-lc"
  [[ "$SAFE_RUN_LOGIN" == "0" ]] && shell_flag="-c"

  if command -v timeout >/dev/null 2>&1; then
    timeout "$SAFE_TIMEOUT_SEC" bash $shell_flag "$cmd" 2>/dev/null | head -n1 | tr -d '\r' || true
  else
    bash $shell_flag "$cmd" 2>/dev/null | head -n1 | tr -d '\r' || true
  fi
}

safe_run_all() {
  local cmd="$1"
  local shell_flag="-lc"
  [[ "$SAFE_RUN_LOGIN" == "0" ]] && shell_flag="-c"

  if command -v timeout >/dev/null 2>&1; then
    timeout "$SAFE_TIMEOUT_SEC" bash $shell_flag "$cmd" 2>/dev/null || true
  else
    bash $shell_flag "$cmd" 2>/dev/null || true
  fi
}

run_with_retry() {
  local cmd="$1"
  local log="$2"
  local timeout_sec="${3:-900}"
  local shell_flag="-lc"
  [[ "$SAFE_RUN_LOGIN" == "0" ]] && shell_flag="-c"

  if timeout "$timeout_sec" bash $shell_flag "$cmd" >"$log" 2>&1; then
    return 0
  fi
  # Retry once
  sleep 2
  timeout "$timeout_sec" bash $shell_flag "$cmd" >>"$log" 2>&1
}

# ─── String helpers ────────────────────────────────────────────────────────────
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

# ─── npm version lookup (handles scoped packages correctly) ────────────────────
npm_global_current_version() {
  local pkg="$1"
  local esc_pkg
  esc_pkg="$(json_escape "$pkg")"
  # Use npm's JSON output with the escaped package name directly in jq filter
  safe_run "npm ls -g --depth=0 --json | jq -r '.dependencies[\"${esc_pkg}\"].version // empty'"
}

npm_latest_version() {
  local pkg="$1"
  safe_run "npm view '${pkg}' version"
}

# ─── OpenClaw latest version (with npm fallback) ──────────────────────────────
openclaw_latest_source="none"
openclaw_latest_version() {
  local latest=""
  openclaw_latest_source="none"

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
  latest="$(npm_latest_version "openclaw")"
  if [[ -n "$latest" ]]; then
    openclaw_latest_source="npm"
  fi
  printf '%s' "$latest"
}

# ─── Messaging (Telegram / Matrix / both) ─────────────────────────────────────
send_message() {
  local message="$1"
  local buttons="${2:-}"
  local channel="${3:-$CHANNEL}"

  [[ "$OPENCLAW_CLI_AVAILABLE" != "1" ]] && {
    log_warn "OpenClaw CLI not available, cannot send message"
    return 1
  }

  local -a cmd_args=(
    env -u OPENCLAW_GATEWAY_URL "$OPENCLAW_BIN" message send
    --channel "$channel"
    --target "$CHAT_ID"
    --message "$message"
  )

  # Thread ID only for Telegram
  if [[ "$channel" == "telegram" && -n "$THREAD_ID" ]]; then
    cmd_args+=(--thread-id "$THREAD_ID")
  fi

  if [[ -n "$buttons" && "$channel" == "telegram" ]]; then
    cmd_args+=(--buttons "$buttons")
  fi

  "${cmd_args[@]}" >/dev/null
}

send_message_json() {
  local message="$1"
  local buttons="${2:-}"
  local channel="${3:-$CHANNEL}"

  [[ "$OPENCLAW_CLI_AVAILABLE" != "1" ]] && return 1

  local -a cmd_args=(
    env -u OPENCLAW_GATEWAY_URL "$OPENCLAW_BIN" message send
    --channel "$channel"
    --target "$CHAT_ID"
    --message "$message"
    --json
  )

  if [[ "$channel" == "telegram" && -n "$THREAD_ID" ]]; then
    cmd_args+=(--thread-id "$THREAD_ID")
  fi

  if [[ -n "$buttons" && "$channel" == "telegram" ]]; then
    cmd_args+=(--buttons "$buttons")
  fi

  "${cmd_args[@]}"
}

# Send to all configured channels
send_to_all_channels() {
  local message="$1"
  local buttons="${2:-}"

  if [[ "$CHANNEL" == "both" ]]; then
    send_message "$message" "$buttons" "telegram" || true
    send_message "$message" "" "matrix" || true
  else
    send_message "$message" "$buttons" "$CHANNEL" || true
  fi
}

# ─── GitHub release info ──────────────────────────────────────────────────────
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

# ─── Gather raw changelog from all sources ────────────────────────────────────
# Collects raw release notes from GitHub + npm into a single context string.
gather_raw_changelog() {
  local pkg="$1" current="$2" latest="$3"
  local context="" repo releases_json count_in_range=0

  # GitHub releases
  repo="$(github_repo_from_npm "$pkg" || true)"
  if [[ -n "$repo" ]]; then
    releases_json="$(timeout 12 curl -fsSL "https://api.github.com/repos/${repo}/releases?per_page=40" 2>/dev/null || true)"
    if [[ -n "$releases_json" ]]; then
      while IFS= read -r line; do
        local tag body norm
        tag="$(printf '%s' "$line" | jq -r '.tag')"
        body="$(printf '%s' "$line" | jq -r '.body')"
        norm="$(normalize_version "$tag")"
        [[ -z "$norm" ]] && continue

        if version_gt "$norm" "$current" && version_lte "$norm" "$latest"; then
          count_in_range=$((count_in_range + 1))
          context+="--- Release ${norm} ---"$'\n'
          context+="$(printf '%s' "$body" | head -n 30)"$'\n\n'
          [[ $count_in_range -ge 5 ]] && break
        fi
      done < <(printf '%s' "$releases_json" | jq -c '.[] | {tag:(.tag_name // ""), body:(.body // "")}')
    fi
  fi

  # npm description as additional context
  local desc
  desc="$(safe_run "npm view '$pkg@$latest' description")"
  if [[ -n "$desc" ]]; then
    context+="--- npm description ---"$'\n'"${desc}"$'\n\n'
  fi

  # npm changelog (if available via npm view)
  local changelog
  changelog="$(safe_run "npm view '$pkg@$latest' changelog" 2>/dev/null || true)"
  if [[ -n "$changelog" && "$changelog" != "undefined" ]]; then
    context+="--- npm changelog ---"$'\n'"$(printf '%s' "$changelog" | head -n 20)"$'\n\n'
  fi

  printf '%s' "$context"
}

# ─── AI-powered summary via OpenClaw ──────────────────────────────────────────
# Summarizes raw changelog into exactly 3 concise bullet points.
# Falls back to raw extraction if AI is unavailable or fails.
AI_SUMMARIZE="${AI_SUMMARIZE:-auto}"
AI_SUMMARIZE_TIMEOUT="${AI_SUMMARIZE_TIMEOUT:-30}"

ai_summarize_changelog() {
  local pkg="$1" current="$2" latest="$3" raw_context="$4"
  local -n _ai_out=$5
  _ai_out=()

  # Check if AI summarization is enabled
  local use_ai=0
  if [[ "$AI_SUMMARIZE" == "1" || "$AI_SUMMARIZE" == "true" ]]; then
    use_ai=1
  elif [[ "$AI_SUMMARIZE" == "auto" && "$OPENCLAW_CLI_AVAILABLE" == "1" ]]; then
    use_ai=1
  fi
  [[ "$use_ai" -eq 0 ]] && return 1

  [[ -z "$raw_context" ]] && return 1

  local prompt ai_response
  prompt="Fasse die folgenden Release-Notes/Changelog-Infos für das npm-Package \"${pkg}\" (Update von ${current} auf ${latest}) in genau 3 kurzen, prägnanten deutschen Bullet Points zusammen. Jeder Punkt maximal 120 Zeichen. Keine Emojis. Nur die 3 wichtigsten Änderungen. Antworte NUR mit den 3 Punkten, einer pro Zeile, ohne Nummerierung oder Aufzählungszeichen.

${raw_context}"

  ai_response="$(timeout "$AI_SUMMARIZE_TIMEOUT" "$OPENCLAW_BIN" agent \
    --local \
    --thinking off \
    --message "$prompt" 2>/dev/null || true)"

  [[ -z "$ai_response" ]] && return 1

  # Parse the 3 lines from the AI response
  local line_count=0
  while IFS= read -r line; do
    line="$(printf '%s' "$line" | sed -E 's/^\s*[-*•·⁃▸▹►»]\s*//' | sed -E 's/^\s*[0-9]+[.):]\s*//' | sed 's/^[[:space:]]*//' | sed 's/[[:space:]]*$//')"
    [[ -z "$line" ]] && continue
    _ai_out+=("$(shorten_line "$line")")
    line_count=$((line_count + 1))
    [[ $line_count -ge 3 ]] && break
  done <<< "$ai_response"

  [[ "${#_ai_out[@]}" -ge 1 ]] && return 0
  return 1
}

# ─── Fallback: extract points from raw data without AI ────────────────────────
# Accepts optional pre-gathered raw_context ($4) to avoid duplicate API calls.
build_raw_points() {
  local pkg="$1" current="$2" latest="$3"
  local -n _raw_out=$4
  local raw_context="${5:-}"
  _raw_out=()

  # If we have pre-gathered context, extract points from it directly
  if [[ -n "$raw_context" ]]; then
    local _ctx_points=()
    local release_count=0
    while IFS= read -r block; do
      [[ -z "$block" ]] && continue
      if [[ "$block" =~ ^---\ Release\ ([0-9][^ ]*)\ ---$ ]]; then
        release_count=$((release_count + 1))
        continue
      fi
      # Skip section headers
      [[ "$block" =~ ^---\ (npm|changelog) ]] && continue
      # Extract first meaningful line from each block
      local summary
      summary="$(release_summary_line "$block")"
      if [[ -n "$summary" && "${#_ctx_points[@]}" -lt 3 ]]; then
        _ctx_points+=("$(shorten_line "$summary")")
      fi
    done <<< "$raw_context"

    if [[ "${#_ctx_points[@]}" -gt 0 ]]; then
      local header="Änderungen ${current} → ${latest}"
      [[ $release_count -gt 0 ]] && header+=" (${release_count} Releases)"
      _raw_out=("$header" "${_ctx_points[@]}")
      _raw_out=("${_raw_out[@]:0:3}")
      return 0
    fi
  fi

  # Last resort: only npm description (no extra API call)
  local desc
  desc="$(safe_run "npm view '$pkg@$latest' description")"
  if [[ -n "$desc" ]]; then
    _raw_out+=("$(shorten_line "$desc")")
  else
    _raw_out+=("Änderungen ${current} → ${latest} (Details nicht direkt verfügbar)")
  fi
  _raw_out+=("Keine Infos gefunden")
  _raw_out+=("Details: npm view ${pkg}@${latest} readme")

  return 0
}

# ─── Main entry: get 3 changelog points for a package ─────────────────────────
package_whats_new_points() {
  local pkg="$1"
  local current="$2"
  local latest="$3"
  local -n _pkg_out_points=$4
  local _points=()

  # Step 1: Gather raw changelog from all sources (single API call)
  local raw_context
  raw_context="$(gather_raw_changelog "$pkg" "$current" "$latest")"

  # Step 2: Try AI summarization
  if [[ -n "$raw_context" ]] && ai_summarize_changelog "$pkg" "$current" "$latest" "$raw_context" _points; then
    # AI summary succeeded — prefix with version range header
    _points=("Änderungen ${current} → ${latest}" "${_points[@]}")
    _points=("${_points[@]:0:3}")
    _pkg_out_points=("${_points[@]}")
    return 0
  fi

  # Step 3: Fallback — reuse the already-gathered context (no duplicate API call)
  build_raw_points "$pkg" "$current" "$latest" _points "$raw_context"
  _pkg_out_points=("${_points[@]:0:3}")

  while [[ "${#_pkg_out_points[@]}" -lt 3 ]]; do
    _pkg_out_points+=("Keine Infos gefunden")
  done
}

# ─── Update command resolver ──────────────────────────────────────────────────
get_update_command() {
  local pkg="$1"
  case "$pkg" in
    openclaw)
      echo "\"$OPENCLAW_BIN\" update --channel stable --yes"
      ;;
    "@kaitranntt/ccs")
      echo "ccs update"
      ;;
    opencode-ai)
      echo "opencode upgrade"
      ;;
    vibe-kanban)
      echo "npm install -g vibe-kanban@latest"
      ;;
    *)
      echo "npm install -g '${pkg}'@latest"
      ;;
  esac
}

get_update_key() {
  local pkg="$1"
  echo "$pkg" | tr '@/ ' '---' | sed 's/^-*//'
}

# ─── Dynamic global npm package discovery ─────────────────────────────────────
# Returns globally-installed npm packages NOT in the watchlist.
# Respects npm_exclude list in the watchlist to skip intentionally excluded packages.
discover_new_global_npm_packages() {
  local wl_file="${1:-$WATCHLIST_FILE}"
  [[ -f "$wl_file" ]] || return 0

  local installed_json
  installed_json="$(safe_run_all 'npm ls -g --depth=0 --json')"
  [[ -z "$installed_json" ]] && return 0

  local installed_pkgs wl_pkgs exclude_pkgs
  installed_pkgs="$(printf '%s' "$installed_json" | jq -r '.dependencies // {} | keys[]' 2>/dev/null | sort)"
  [[ -z "$installed_pkgs" ]] && return 0

  wl_pkgs="$(jq -r '.npm[]? // empty' "$wl_file" 2>/dev/null | sort)"
  exclude_pkgs="$(jq -r '.npm_exclude[]? // empty' "$wl_file" 2>/dev/null | sort)"

  local skip_set
  skip_set="$(printf '%s\n%s' "$wl_pkgs" "$exclude_pkgs" | sort -u)"

  comm -23 <(printf '%s\n' "$installed_pkgs") <(printf '%s\n' "$skip_set") | while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    printf '%s\n' "$pkg"
  done
}

# Adds newly discovered npm packages to the watchlist JSON.
# Returns the count of packages added.
sync_watchlist_npm() {
  local wl_file="${1:-$WATCHLIST_FILE}"
  [[ -f "$wl_file" ]] || return 0

  local new_pkgs added=0
  new_pkgs="$(discover_new_global_npm_packages "$wl_file")"
  [[ -z "$new_pkgs" ]] && { echo 0; return 0; }

  while IFS= read -r pkg; do
    [[ -z "$pkg" ]] && continue
    # Add to the npm array in the watchlist (idempotent, sorted)
    local tmp_wl
    tmp_wl="$(jq --arg p "$pkg" '.npm = (.npm + [$p] | unique | sort)' "$wl_file")"
    if [[ -n "$tmp_wl" ]]; then
      printf '%s\n' "$tmp_wl" > "$wl_file"
      log_info "Watchlist: added new global package '$pkg'"
      added=$((added + 1))
    fi
  done <<< "$new_pkgs"

  echo "$added"
}

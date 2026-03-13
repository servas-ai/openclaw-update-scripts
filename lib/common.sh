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

build_points_from_github_releases() {
  local pkg="$1"
  local current="$2"
  local latest="$3"
  local -n _out_points=$4

  _out_points=()

  command -v curl >/dev/null 2>&1 || return 1
  command -v jq >/dev/null 2>&1 || return 1

  local repo releases_json line tag body norm summary count_in_range
  repo="$(github_repo_from_npm "$pkg" || true)"
  [[ -z "$repo" ]] && return 1

  releases_json="$(timeout 12 curl -fsSL "https://api.github.com/repos/${repo}/releases?per_page=40" 2>/dev/null || true)"
  if [[ -z "$releases_json" ]]; then
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
        _out_points+=("${norm}: Release notes verfügbar")
      else
        _out_points+=("${norm}: ${summary}")
      fi
      [[ "${#_out_points[@]}" -ge 3 ]] && break
    fi
  done < <(printf '%s' "$releases_json" | jq -c '.[] | {tag:(.tag_name // ""), body:(.body // "")}')

  if [[ "${#_out_points[@]}" -gt 0 ]]; then
    _out_points=("Änderungen ${current} → ${latest} (${count_in_range} Releases)" "${_out_points[@]}")
    _out_points=("${_out_points[@]:0:3}")
    return 0
  fi

  return 1
}

package_whats_new_points() {
  local pkg="$1"
  local current="$2"
  local latest="$3"
  local -n _pkg_out_points=$4
  local _points=()

  if build_points_from_github_releases "$pkg" "$current" "$latest" _points; then
    _pkg_out_points=("${_points[@]}")
    return 0
  fi

  local desc versions range_versions
  desc="$(safe_run "npm view '$pkg@$latest' description")"
  versions="$(safe_run_all "npm view '$pkg' versions --json | jq -r 'if type==\"array\" then .[] else empty end' | tail -n 20")"

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
    _points+=("$(shorten_line "$desc")")
  else
    _points+=("Änderungen ${current} → ${latest} (Details nicht direkt verfügbar)")
  fi

  if [[ "${#range_versions[@]}" -gt 0 ]]; then
    _points+=("Versionen im Bereich: $(printf '%s, ' "${range_versions[@]:0:5}" | sed 's/, $//')")
  else
    _points+=("Versionen im Bereich nicht ermittelbar")
  fi

  _points+=("Details: npm view ${pkg}@${latest} readme")

  while [[ "${#_points[@]}" -lt 3 ]]; do
    _points+=("Keine weiteren Release-Notes gefunden")
  done

  _pkg_out_points=("${_points[@]:0:3}")
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
      echo "npx -y vibe-kanban@latest --help >/dev/null 2>&1 || true"
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

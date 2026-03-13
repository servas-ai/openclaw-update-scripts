#!/usr/bin/env bash
set -euo pipefail

# ═══════════════════════════════════════════════════════════════════════════════
# Run Docker E2E Integration Test
# ═══════════════════════════════════════════════════════════════════════════════
# Usage: bash scripts/run-docker-e2e.sh
#
# Environment:
#   AI_API_BASE  — AI proxy URL (default: https://cliproxy.servas.ai/v1)
#   AI_API_KEY   — API key (default: ccs-internal-managed)
#   AI_MODEL     — Model to use (default: gpt-4o-mini)
# ═══════════════════════════════════════════════════════════════════════════════

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

AI_API_BASE="${AI_API_BASE:-https://cliproxy.servas.ai/v1}"
AI_API_KEY="${AI_API_KEY:-ccs-internal-managed}"
AI_MODEL="${AI_MODEL:-gpt-4o-mini}"
IMAGE_NAME="openclaw-e2e-test"

echo ""
echo "═══════════════════════════════════════════════════"
echo "  🐳 Docker E2E Test — Building Image"
echo "═══════════════════════════════════════════════════"
echo ""

docker build -f "$ROOT/Dockerfile.e2e" -t "$IMAGE_NAME" "$ROOT"

echo ""
echo "═══════════════════════════════════════════════════"
echo "  🐳 Docker E2E Test — Running Container"
echo "═══════════════════════════════════════════════════"
echo ""

docker run --rm \
  --network=host \
  -e AI_API_BASE="$AI_API_BASE" \
  -e AI_API_KEY="$AI_API_KEY" \
  -e AI_MODEL="$AI_MODEL" \
  "$IMAGE_NAME"

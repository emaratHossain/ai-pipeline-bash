#!/usr/bin/env bash
# server.sh — Main entry point. Starts the socat-based webhook listener.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# ── Load env ──────────────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
  echo "ERROR: .env not found. Run setup.sh first." >&2
  exit 1
fi
set -a; source .env; set +a

PORT="${PORT:-3000}"

# ── Runtime directories ───────────────────────────────────────────────────────
mkdir -p logs state/locks

# ── Dependency check ──────────────────────────────────────────────────────────
for dep in socat jq curl openssl git; do
  if ! command -v "$dep" &>/dev/null; then
    echo "ERROR: '$dep' is required but not found in PATH." >&2
    exit 1
  fi
done

# ── Mock mode warning ─────────────────────────────────────────────────────────
if [[ "${MOCK_MODE:-false}" == "true" ]]; then
  echo "WARNING: MOCK_MODE=true — no real AI calls will be made"
fi

# ── Banner ────────────────────────────────────────────────────────────────────
echo "──────────────────────────────────────────────"
echo "  AI Triage Bot (bash) — Webhook Server"
echo "──────────────────────────────────────────────"
echo "  Port    : $PORT"
echo "  Provider: ${AI_PROVIDER:-anthropic}"
echo "  Repo    : ${GITHUB_REPO:-not set}"
echo "  RepoPath: ${REPO_PATH:-not set}"
echo "  Mock    : ${MOCK_MODE:-false}"
echo "──────────────────────────────────────────────"
echo "  Endpoints:"
echo "    POST http://localhost:$PORT/webhook"
echo "    GET  http://localhost:$PORT/health"
echo "──────────────────────────────────────────────"
echo "  Logs: ./logs/"
echo "  Press Ctrl+C to stop"
echo ""

# Tee server logs to file and stdout
exec socat "TCP-LISTEN:${PORT},fork,reuseaddr" \
  "EXEC:${SCRIPT_DIR}/handle_webhook.sh"

#!/usr/bin/env bash
# scripts/test-triage.sh — Simulate a GitHub "issues.opened" webhook locally.
# Usage: bash scripts/test-triage.sh <issue_number> [issue_title] [issue_body]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

[[ -f .env ]] && { set -a; source .env; set +a; }

ISSUE_NUMBER="${1:-1}"
ISSUE_TITLE="${2:-Test issue: something is broken}"
ISSUE_BODY="${3:-This is a test issue body for local simulation.}"
PORT="${PORT:-3000}"

# Build a realistic fake webhook payload
PAYLOAD=$(jq -n \
  --arg action "opened" \
  --argjson number "$ISSUE_NUMBER" \
  --arg title  "$ISSUE_TITLE" \
  --arg body   "$ISSUE_BODY" \
  --arg login  "test-user" \
  '{
    "action": $action,
    "issue": {
      "number": $number,
      "title":  $title,
      "body":   $body,
      "user":   {"login": $login}
    }
  }')

# Compute HMAC signature
SIG=$(printf '%s' "$PAYLOAD" | \
  openssl dgst -sha256 -hmac "${GITHUB_WEBHOOK_SECRET}" | awk '{print $NF}')

echo "Sending test 'issues.opened' webhook for issue #$ISSUE_NUMBER..."
echo ""

curl -s \
  -X POST "http://localhost:${PORT}/webhook" \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: issues" \
  -H "X-GitHub-Delivery: test-$(date +%s)-triage" \
  -H "X-Hub-Signature-256: sha256=${SIG}" \
  -d "$PAYLOAD"

echo ""
echo "Done. Watch the log:"
echo "  tail -f logs/triage-${ISSUE_NUMBER}.log"

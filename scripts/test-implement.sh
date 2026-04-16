#!/usr/bin/env bash
# scripts/test-implement.sh — Simulate a GitHub "issue_comment /approve" webhook locally.
# Usage: bash scripts/test-implement.sh <issue_number> [issue_title]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

[[ -f .env ]] && { set -a; source .env; set +a; }

ISSUE_NUMBER="${1:-1}"
ISSUE_TITLE="${2:-Test issue: something is broken}"
APPROVER="${TRUSTED_USERS%%,*}"   # use first trusted user, or empty
APPROVER="${APPROVER:-test-user}"
PORT="${PORT:-3000}"

PAYLOAD=$(jq -n \
  --arg action "created" \
  --argjson number "$ISSUE_NUMBER" \
  --arg title    "$ISSUE_TITLE" \
  --arg commenter "$APPROVER" \
  '{
    "action": $action,
    "issue": {
      "number": $number,
      "title":  $title
    },
    "comment": {
      "body":  "/approve",
      "user":  {"login": $commenter}
    }
  }')

SIG=$(printf '%s' "$PAYLOAD" | \
  openssl dgst -sha256 -hmac "${GITHUB_WEBHOOK_SECRET}" | awk '{print $NF}')

echo "Sending test '/approve' webhook for issue #$ISSUE_NUMBER (user: $APPROVER)..."
echo ""

curl -s \
  -X POST "http://localhost:${PORT}/webhook" \
  -H "Content-Type: application/json" \
  -H "X-GitHub-Event: issue_comment" \
  -H "X-GitHub-Delivery: test-$(date +%s)-approve" \
  -H "X-Hub-Signature-256: sha256=${SIG}" \
  -d "$PAYLOAD"

echo ""
echo "Done. Watch the log:"
echo "  tail -f logs/implement-${ISSUE_NUMBER}.log"

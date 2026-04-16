#!/usr/bin/env bash
# handle_webhook.sh — Reads a raw HTTP request from stdin (via socat),
# verifies the HMAC signature, deduplicates, and dispatches to triage/implement.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f .env ]] && { set -a; source .env; set +a; }

source lib/hmac.sh

LOG="logs/server.log"
mkdir -p logs state

log() { echo "[webhook] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*" >> "$LOG"; }

# ── HTTP response helpers ─────────────────────────────────────────────────────
http_respond() {
  local code="$1" phrase="$2" body="$3"
  printf "HTTP/1.1 %s %s\r\nContent-Type: text/plain\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
    "$code" "$phrase" "${#body}" "$body"
}

# ── Read request line ─────────────────────────────────────────────────────────
IFS= read -r request_line
request_line="${request_line%$'\r'}"
METHOD=$(echo "$request_line"   | cut -d' ' -f1)
REQUEST_PATH=$(echo "$request_line" | cut -d' ' -f2)

# ── Read headers ──────────────────────────────────────────────────────────────
declare -A HEADERS
while IFS= read -r line; do
  line="${line%$'\r'}"
  [[ -z "$line" ]] && break
  key="${line%%:*}"
  val="${line#*:}"
  val="${val# }"                      # strip leading space
  HEADERS["${key,,}"]="$val"
done

# ── Read body ─────────────────────────────────────────────────────────────────
CONTENT_LENGTH="${HEADERS['content-length']:-0}"
BODY=""
if [[ "$CONTENT_LENGTH" -gt 0 ]]; then
  BODY=$(head -c "$CONTENT_LENGTH")
fi

# ── Health check ──────────────────────────────────────────────────────────────
if [[ "$REQUEST_PATH" == "/health" ]]; then
  MOCK_FLAG="${MOCK_MODE:-false}"
  [[ "$MOCK_FLAG" == "true" ]] && MOCK_WARN=', "warning":"MOCK_MODE is enabled"' || MOCK_WARN=""
  PAYLOAD='{"status":"ok","provider":"'"${AI_PROVIDER:-anthropic}"'","repo":"'"${GITHUB_REPO:-}"'"'"$MOCK_WARN"'}'
  printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s" \
    "${#PAYLOAD}" "$PAYLOAD"
  exit 0
fi

# ── Only handle POST /webhook ─────────────────────────────────────────────────
if [[ "$REQUEST_PATH" != "/webhook" || "$METHOD" != "POST" ]]; then
  http_respond 404 "Not Found" "Not Found"
  exit 0
fi

# ── HMAC verification ─────────────────────────────────────────────────────────
SIG_HEADER="${HEADERS['x-hub-signature-256']:-}"
if ! verify_signature "$BODY" "${GITHUB_WEBHOOK_SECRET:-}" "$SIG_HEADER"; then
  http_respond 401 "Unauthorized" "Unauthorized"
  log "HMAC verification failed (sig='$SIG_HEADER')"
  exit 0
fi

# ── Delivery deduplication ────────────────────────────────────────────────────
DELIVERY_ID="${HEADERS['x-github-delivery']:-}"
SEEN_FILE="state/seen_ids.txt"
touch "$SEEN_FILE"

if [[ -n "$DELIVERY_ID" ]] && grep -qF "$DELIVERY_ID" "$SEEN_FILE" 2>/dev/null; then
  http_respond 200 "OK" "OK"
  log "Duplicate delivery $DELIVERY_ID — ignored"
  exit 0
fi

[[ -n "$DELIVERY_ID" ]] && {
  echo "$DELIVERY_ID $(date -u '+%Y-%m-%dT%H:%M:%SZ')" >> "$SEEN_FILE"
  # Keep only the last 2000 entries
  tail -2000 "$SEEN_FILE" > "${SEEN_FILE}.tmp" && mv "${SEEN_FILE}.tmp" "$SEEN_FILE"
}

# ── Parse event fields ────────────────────────────────────────────────────────
EVENT="${HEADERS['x-github-event']:-}"
ACTION=$(echo "$BODY" | jq -r '.action // empty' 2>/dev/null)

log "Event=$EVENT Action=$ACTION Delivery=${DELIVERY_ID:-n/a}"

# ── Send HTTP 200 immediately, then detach ────────────────────────────────────
# GitHub expects a quick response; real work runs in the background.
http_respond 200 "OK" "OK"
exec >/dev/null 2>&1   # disconnect stdout from the socket

# ── Dispatch ─────────────────────────────────────────────────────────────────
case "$EVENT" in

  issues)
    if [[ "$ACTION" == "opened" ]]; then
      ISSUE_JSON=$(echo "$BODY" | jq -c '.issue')
      ISSUE_NUMBER=$(echo "$BODY" | jq -r '.issue.number')
      log "Dispatching triage for issue #$ISSUE_NUMBER"
      setsid bash "$SCRIPT_DIR/triage.sh" "$ISSUE_JSON" \
        >> "logs/triage-${ISSUE_NUMBER}.log" 2>&1 &
      disown
    fi
    ;;

  issue_comment)
    if [[ "$ACTION" == "created" ]]; then
      COMMENT_BODY=$(echo "$BODY" | jq -r '.comment.body // ""')
      COMMENTER=$(echo    "$BODY" | jq -r '.comment.user.login // ""')
      ISSUE_NUMBER=$(echo "$BODY" | jq -r '.issue.number')
      ISSUE_TITLE=$(echo  "$BODY" | jq -r '.issue.title // ""')

      if echo "$COMMENT_BODY" | grep -qF "/approve"; then

        # ── Trusted user check ──────────────────────────────────────────────
        if [[ -n "${TRUSTED_USERS:-}" ]]; then
          TRUSTED_OK=false
          IFS=',' read -ra _TRUSTED <<< "$TRUSTED_USERS"
          for _u in "${_TRUSTED[@]}"; do
            _u="${_u// /}"           # strip whitespace
            [[ "$_u" == "$COMMENTER" ]] && TRUSTED_OK=true && break
          done
          if [[ "$TRUSTED_OK" != "true" ]]; then
            log "Untrusted user '$COMMENTER' tried /approve on #$ISSUE_NUMBER — blocked"
            exit 0
          fi
        fi

        log "Dispatching implementation for issue #$ISSUE_NUMBER"
        setsid bash "$SCRIPT_DIR/implement.sh" "$ISSUE_NUMBER" "$ISSUE_TITLE" \
          >> "logs/implement-${ISSUE_NUMBER}.log" 2>&1 &
        disown
      fi
    fi
    ;;

  ping)
    log "Ping received — webhook is connected"
    ;;

  *)
    log "Unhandled event: $EVENT"
    ;;
esac

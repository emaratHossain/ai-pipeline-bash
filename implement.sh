#!/usr/bin/env bash
# implement.sh — Implement the approved pipeline plan: git branch, AI edits, PR.
# Called by handle_webhook.sh in background with: <issue_number> <issue_title>

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

[[ -f .env ]] && { set -a; source .env; set +a; }

source lib/github.sh
source lib/ai.sh
source lib/repo_context.sh

ISSUE_NUMBER="$1"
ISSUE_TITLE="${2:-Issue #${ISSUE_NUMBER}}"
BRANCH="fix/issue-${ISSUE_NUMBER}"
LOCK_FILE="state/locks/issue-${ISSUE_NUMBER}.lock"
IMPL_OK=false

mkdir -p state/locks logs

log() { echo "[impl #${ISSUE_NUMBER}] $(date -u '+%Y-%m-%dT%H:%M:%SZ') $*"; }

# ── Exclusive lock — prevents duplicate concurrent runs ───────────────────────
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Already running for issue #${ISSUE_NUMBER} — skipping duplicate"
  exit 0
fi

# ── Cleanup on exit ───────────────────────────────────────────────────────────
cleanup() {
  local exit_code=$?
  flock -u 9
  exec 9>&-

  if [[ "$IMPL_OK" != "true" && -n "${REPO_PATH:-}" ]]; then
    log "Cleaning up local branch after failure"
    git -C "$REPO_PATH" checkout "${BASE_BRANCH:-main}" 2>/dev/null || true
    git -C "$REPO_PATH" branch -D "$BRANCH" 2>/dev/null || true
  fi

  exit "$exit_code"
}
trap cleanup EXIT

log "Starting implementation for \"$ISSUE_TITLE\""

# ── Validate repo path ────────────────────────────────────────────────────────
if [[ ! -d "${REPO_PATH:-}" ]]; then
  log "ERROR: REPO_PATH not set or does not exist: ${REPO_PATH:-}"
  exit 1
fi
if [[ ! -d "$REPO_PATH/.git" ]]; then
  log "ERROR: REPO_PATH is not a git repository: $REPO_PATH"
  exit 1
fi

# ── Validate git config ───────────────────────────────────────────────────────
GIT_USER=$(git -C "$REPO_PATH" config user.name  2>/dev/null || echo "")
GIT_EMAIL=$(git -C "$REPO_PATH" config user.email 2>/dev/null || echo "")
[[ -z "$GIT_USER"  ]] && git -C "$REPO_PATH" config user.name  "AI Pipeline Bot"
[[ -z "$GIT_EMAIL" ]] && git -C "$REPO_PATH" config user.email "bot@ai-pipeline.local"

# ── Fetch pipeline plan comment ─────────────────────────────────────────────────
log "Fetching plan comment from GitHub"
PLAN=$(get_plan_comment "$ISSUE_NUMBER")

if [[ -z "$PLAN" ]]; then
  log "ERROR: No pipeline plan comment found for issue #${ISSUE_NUMBER}"
  log "Make sure the bot posted a '## 🤖 AI Pipeline Plan' comment before /approve"
  exit 1
fi

# ── Build repo context ────────────────────────────────────────────────────────
log "Building repo context"
CONTEXT=$(build_context "$ISSUE_TITLE $PLAN")

# ── Set up git branch ─────────────────────────────────────────────────────────
BASE="${BASE_BRANCH:-main}"
log "Preparing branch: $BRANCH (base: $BASE)"

git -C "$REPO_PATH" fetch origin
git -C "$REPO_PATH" checkout "$BASE"
git -C "$REPO_PATH" pull --ff-only origin "$BASE"

# Delete stale branch if it exists
git -C "$REPO_PATH" branch -D "$BRANCH" 2>/dev/null || true
git -C "$REPO_PATH" checkout -b "$BRANCH"

# ── Call AI for implementation ────────────────────────────────────────────────
log "Calling AI for implementation (provider: ${AI_PROVIDER:-anthropic})"
AI_JSON=$(ai_implement "$PLAN" "$CONTEXT" "$ISSUE_TITLE")

if [[ -z "$AI_JSON" ]]; then
  log "ERROR: AI returned empty response"
  exit 1
fi

# ── Apply file changes ────────────────────────────────────────────────────────
PR_TITLE=$(echo "$AI_JSON" | jq -r '.pr_title // "fix: issue #'"$ISSUE_NUMBER"'"')
PR_BODY=$(echo  "$AI_JSON" | jq -r '.pr_body  // ""')
FILE_COUNT=$(echo "$AI_JSON" | jq '.files | length')

log "AI returned $FILE_COUNT file(s) to modify"

if [[ "$FILE_COUNT" -eq 0 ]]; then
  log "WARNING: AI returned no file changes — PR will have no commits"
fi

REAL_REPO=$(realpath "$REPO_PATH")
MODIFIED=0

while IFS= read -r file_entry; do
  FILE_PATH=$(echo "$file_entry" | jq -r '.path')
  FILE_CONTENT=$(echo "$file_entry" | jq -r '.content')

  # ── Security: block path traversal (including symlinks) ────────────────────
  FULL_PATH=$(realpath -m "$REPO_PATH/$FILE_PATH")
  if [[ "$FULL_PATH" != "$REAL_REPO"/* ]]; then
    log "SECURITY: Blocked path traversal attempt: $FILE_PATH"
    continue
  fi

  # Create parent dirs if needed
  mkdir -p "$(dirname "$FULL_PATH")"

  # Write file content
  printf '%s' "$FILE_CONTENT" > "$FULL_PATH"
  git -C "$REPO_PATH" add "$FILE_PATH"
  MODIFIED=$((MODIFIED + 1))
  log "Modified: $FILE_PATH"

done < <(echo "$AI_JSON" | jq -c '.files[]')

if [[ "$MODIFIED" -eq 0 && "$FILE_COUNT" -gt 0 ]]; then
  log "ERROR: All file writes were blocked (path traversal attempts?)"
  exit 1
fi

# ── Commit ────────────────────────────────────────────────────────────────────
COMMIT_MSG=$(cat <<MSG
fix: implement solution for issue #${ISSUE_NUMBER}

${ISSUE_TITLE}

Co-authored-by: AI Pipeline Bot <bot@ai-pipeline.local>
MSG
)

git -C "$REPO_PATH" commit -m "$COMMIT_MSG"
log "Committed $MODIFIED file change(s)"

# ── Push ──────────────────────────────────────────────────────────────────────
log "Pushing branch $BRANCH"
git -C "$REPO_PATH" push origin "$BRANCH"

# ── Open PR ───────────────────────────────────────────────────────────────────
FULL_PR_BODY=$(cat <<BODY
${PR_BODY}

---
Closes #${ISSUE_NUMBER}

*Implemented by [AI Pipeline Bot (bash)](https://github.com)*
BODY
)

log "Opening pull request"
PR_RESULT=$(create_pr "$PR_TITLE" "$FULL_PR_BODY" "$BRANCH")
PR_URL=$(echo "$PR_RESULT" | jq -r '.html_url // empty')

if [[ -z "$PR_URL" ]]; then
  log "ERROR: Failed to create PR — API response:"
  echo "$PR_RESULT"
  exit 1
fi

IMPL_OK=true
log "Done — PR opened: $PR_URL"

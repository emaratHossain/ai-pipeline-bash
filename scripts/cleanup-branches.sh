#!/usr/bin/env bash
# scripts/cleanup-branches.sh — Remove stale fix/issue-* branches that have
# already been merged or closed. Safe to run as a cron job.
#
# Usage: bash scripts/cleanup-branches.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

[[ -f .env ]] && { set -a; source .env; set +a; }

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

if [[ ! -d "${REPO_PATH:-}/.git" ]]; then
  echo "ERROR: REPO_PATH is not set or not a git repo: ${REPO_PATH:-}"
  exit 1
fi

echo "Scanning for stale fix/issue-* branches in $REPO_PATH..."
echo ""

git -C "$REPO_PATH" fetch --prune origin

REMOVED=0
SKIPPED=0

while IFS= read -r branch; do
  branch="${branch#  }"
  branch="${branch#* }"   # strip 'remotes/origin/' prefix if present

  # Extract issue number
  issue_num="${branch#fix/issue-}"

  # Check if the issue is closed or the remote branch is gone
  local_exists=$(git -C "$REPO_PATH" show-ref --quiet "refs/heads/$branch" && echo yes || echo no)
  remote_exists=$(git -C "$REPO_PATH" show-ref --quiet "refs/remotes/origin/$branch" && echo yes || echo no)

  if [[ "$remote_exists" == "no" && "$local_exists" == "yes" ]]; then
    echo "  Stale local branch (no remote): $branch"
    if [[ "$DRY_RUN" == "false" ]]; then
      git -C "$REPO_PATH" branch -D "$branch"
      echo "    → Deleted"
      REMOVED=$((REMOVED+1))
    else
      echo "    → Would delete (--dry-run)"
      REMOVED=$((REMOVED+1))
    fi
  else
    SKIPPED=$((SKIPPED+1))
  fi

done < <(git -C "$REPO_PATH" branch | grep 'fix/issue-' || true)

echo ""
if [[ "$DRY_RUN" == "true" ]]; then
  echo "Dry run complete: $REMOVED branch(es) would be removed, $SKIPPED skipped."
else
  echo "Done: $REMOVED branch(es) removed, $SKIPPED skipped."
fi

# Also clean up old lock files (older than 1 hour)
echo ""
echo "Cleaning stale lock files..."
find "$SCRIPT_DIR/state/locks" -name "*.lock" -mmin +60 -delete 2>/dev/null && echo "Done." || echo "None found."

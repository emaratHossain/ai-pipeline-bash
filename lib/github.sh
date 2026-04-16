#!/usr/bin/env bash
# lib/github.sh — GitHub API helpers using curl + jq

GITHUB_API="https://api.github.com"

# Internal: make a GitHub API request
# Usage: _gh_api <METHOD> <path> [json_body]
_gh_api() {
  local method="$1"
  local path="$2"
  local data="${3:-}"

  local args=(
    -s
    --max-time 30
    -X "$method"
    -H "Authorization: Bearer ${GITHUB_TOKEN}"
    -H "Accept: application/vnd.github+json"
    -H "X-GitHub-Api-Version: 2022-11-28"
    -H "Content-Type: application/json"
  )

  [[ -n "$data" ]] && args+=(-d "$data")

  curl "${args[@]}" "${GITHUB_API}${path}"
}

# Post a comment on an issue
# Usage: post_comment <issue_number> <body_text>
post_comment() {
  local issue_number="$1"
  local body="$2"
  local owner repo
  IFS='/' read -r owner repo <<< "$GITHUB_REPO"

  local payload
  payload=$(jq -n --arg body "$body" '{"body": $body}')

  _gh_api POST "/repos/$owner/$repo/issues/$issue_number/comments" "$payload"
}

# Get all comments on an issue (handles pagination)
# Usage: get_issue_comments <issue_number>
get_issue_comments() {
  local issue_number="$1"
  local owner repo
  IFS='/' read -r owner repo <<< "$GITHUB_REPO"

  local page=1
  local all="[]"

  while true; do
    local response
    response=$(_gh_api GET "/repos/$owner/$repo/issues/$issue_number/comments?per_page=100&page=$page")

    local count
    count=$(echo "$response" | jq 'length // 0')

    all=$(printf '%s\n%s' "$all" "$response" | jq -s 'add // []')

    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done

  echo "$all"
}

# Get the bot's pipeline plan comment body
# Usage: get_plan_comment <issue_number>
get_plan_comment() {
  local issue_number="$1"
  local comments
  comments=$(get_issue_comments "$issue_number")

  echo "$comments" | jq -r \
    --arg bot "$BOT_USERNAME" \
    '.[] | select(.user.login == $bot) | select(.body | contains("## 🤖 AI Pipeline Plan")) | .body' \
    | tail -1
}

# Open a pull request
# Usage: create_pr <title> <body> <head_branch>
create_pr() {
  local title="$1"
  local body="$2"
  local head="$3"
  local owner repo
  IFS='/' read -r owner repo <<< "$GITHUB_REPO"

  local base="${BASE_BRANCH:-main}"

  local payload
  payload=$(jq -n \
    --arg title "$title" \
    --arg body  "$body"  \
    --arg head  "$head"  \
    --arg base  "$base"  \
    '{"title":$title,"body":$body,"head":$head,"base":$base}')

  _gh_api POST "/repos/$owner/$repo/pulls" "$payload"
}

# Add a label to an issue (creates the label if it doesn't exist)
# Usage: add_label <issue_number> <label>
add_label() {
  local issue_number="$1"
  local label="$2"
  local owner repo
  IFS='/' read -r owner repo <<< "$GITHUB_REPO"

  local payload
  payload=$(jq -n --arg label "$label" '{"labels": [$label]}')

  _gh_api POST "/repos/$owner/$repo/issues/$issue_number/labels" "$payload" > /dev/null
}

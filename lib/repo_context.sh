#!/usr/bin/env bash
# lib/repo_context.sh — Build relevant repo context from keywords in an issue

STOP_WORDS="this that with from have been will would could should they them their
there what when where which while about after before during under over into onto
upon also just only very more some than then here your mine ours these those"

# Build a context string from files relevant to the issue text
# Usage: build_context <issue_text>
build_context() {
  local issue_text="$1"
  local max_bytes="${MAX_CONTEXT_BYTES:-40000}"

  if [[ ! -d "${REPO_PATH:-}" ]]; then
    echo "# No REPO_PATH configured — skipping context"
    return
  fi

  # Extract keywords: alphanumeric tokens > 3 chars, lowercase, deduped
  local keywords
  keywords=$(echo "$issue_text" \
    | tr '[:upper:]' '[:lower:]' \
    | grep -oE '[a-z_][a-z0-9_]{3,}' \
    | grep -vxF -f <(echo "$STOP_WORDS" | tr ' \n' '\n') \
    | sort -u \
    | head -30)

  if [[ -z "$keywords" ]]; then
    echo "# No keywords extracted from issue text"
    return
  fi

  # Track which files we've already added (avoid duplicates)
  declare -A seen_files
  local context=""
  local total_bytes=0

  while IFS= read -r keyword; do
    [[ -z "$keyword" ]] && continue

    # Find files mentioning this keyword, skip noise dirs
    while IFS= read -r file; do
      [[ -f "$file" ]] || continue
      [[ -n "${seen_files[$file]+x}" ]] && continue

      local file_size
      file_size=$(wc -c < "$file" 2>/dev/null) || continue

      # Skip binary and oversized files
      [[ "$file_size" -gt 100000 ]] && continue
      if file "$file" 2>/dev/null | grep -q "binary"; then continue; fi

      local remaining=$(( max_bytes - total_bytes ))
      [[ "$remaining" -le 100 ]] && break 2

      local content
      if [[ "$file_size" -le "$remaining" ]]; then
        content=$(cat "$file")
        total_bytes=$(( total_bytes + file_size ))
      else
        content=$(head -c "$remaining" "$file")
        content+=$'\n... [truncated — file too large]'
        total_bytes=$(( total_bytes + remaining ))
      fi

      local rel_path="${file#${REPO_PATH}/}"
      context+=$'\n'"### ${rel_path}"$'\n''```'$'\n'"${content}"$'\n''```'$'\n'
      seen_files["$file"]=1

    done < <(
      grep -rl --include="*.js" --include="*.ts" --include="*.py" \
                --include="*.go" --include="*.rb" --include="*.php" \
                --include="*.java" --include="*.sh" --include="*.json" \
                --include="*.yaml" --include="*.yml" --include="*.md" \
           "$keyword" "$REPO_PATH" 2>/dev/null \
        | grep -vE '(\.git|node_modules|vendor|dist|build|\.next|coverage)[/]' \
        | head -4
    )
  done <<< "$keywords"

  if [[ -z "$context" ]]; then
    echo "# No relevant files found for the given keywords"
    return
  fi

  printf '%s' "$context"
}

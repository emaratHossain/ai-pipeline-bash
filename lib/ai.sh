#!/usr/bin/env bash
# lib/ai.sh — Provider-agnostic AI helpers (Anthropic + OpenRouter)

# Generate a triage plan as markdown text
# Usage: ai_triage <prompt>
ai_triage() {
  local prompt="$1"
  local system="${TRIAGE_SYSTEM_PROMPT:-You are a senior software engineer triaging a GitHub issue. Be concise, specific, and actionable.}"

  if [[ "${MOCK_MODE:-false}" == "true" ]]; then
    echo "## Root Cause
Mock mode is enabled — this is a canned response.

## Fix Plan
1. This is a mock fix step
2. No real AI calls were made

## Risk Assessment
None — this is a mock response."
    return
  fi

  case "${AI_PROVIDER:-anthropic}" in
    anthropic)  _anthropic_text "$system" "$prompt" ;;
    openrouter) _openrouter_text "$system" "$prompt" ;;
    *)
      echo "[ai] ERROR: Unknown AI_PROVIDER '${AI_PROVIDER}'" >&2
      return 1
      ;;
  esac
}

# Generate file changes for implementation — returns JSON
# Usage: ai_implement <plan> <repo_context> <issue_title>
ai_implement() {
  local plan="$1"
  local context="$2"
  local issue_title="$3"

  local system='You are a senior software engineer implementing a fix.
You MUST respond with ONLY a single valid JSON object — no markdown fences, no explanation, nothing else.
The JSON must match this exact schema:
{
  "pr_title": "short imperative PR title (under 72 chars)",
  "pr_body": "markdown PR description with ## Summary and ## Changes sections",
  "files": [
    {"path": "relative/path/from/repo/root", "content": "complete new file content as a string"}
  ]
}
Rules:
- Only include files that need to be created or modified.
- "path" must be relative to the repo root (no leading slash).
- "content" must be the entire new file content, not a diff.
- If no files need changing, set "files" to an empty array and explain in pr_body.'

  local user_prompt
  user_prompt=$(printf 'Issue Title: %s\n\nTriage Plan:\n%s\n\nRepo Context:\n%s\n\nImplement the fix following the plan exactly.' \
    "$issue_title" "$plan" "$context")

  if [[ "${MOCK_MODE:-false}" == "true" ]]; then
    jq -n \
      --arg title "fix: mock implementation for $issue_title" \
      '{"pr_title":$title,"pr_body":"## Summary\nMock implementation.\n\n## Changes\n- No real changes (MOCK_MODE=true)","files":[]}'
    return
  fi

  local raw
  case "${AI_PROVIDER:-anthropic}" in
    anthropic)  raw=$(_anthropic_text "$system" "$user_prompt") ;;
    openrouter) raw=$(_openrouter_text "$system" "$user_prompt") ;;
    *)
      echo "[ai] ERROR: Unknown AI_PROVIDER '${AI_PROVIDER}'" >&2
      return 1
      ;;
  esac

  # Strip markdown code fences if the model wrapped the JSON anyway
  local json
  json=$(echo "$raw" | sed -n '/^{/,/^}/p')

  # Validate JSON
  if ! echo "$json" | jq empty 2>/dev/null; then
    echo "[ai] ERROR: AI did not return valid JSON. Raw response:" >&2
    echo "$raw" >&2
    return 1
  fi

  echo "$json"
}

# ── Internal: Anthropic messages API ─────────────────────────────────────────
_anthropic_text() {
  local system="$1"
  local user="$2"
  local model="${TRIAGE_MODEL:-claude-sonnet-4-6}"
  local max_tokens="${MAX_TOKENS:-4096}"

  local payload
  payload=$(jq -n \
    --arg model      "$model"      \
    --arg system     "$system"     \
    --arg user       "$user"       \
    --argjson max_tokens "$max_tokens" \
    '{
      "model":      $model,
      "max_tokens": $max_tokens,
      "system":     $system,
      "messages":   [{"role":"user","content":$user}]
    }')

  local response
  response=$(curl -s --max-time 120 \
    -X POST "https://api.anthropic.com/v1/messages" \
    -H "x-api-key: ${ANTHROPIC_API_KEY}" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$payload")

  local text
  text=$(echo "$response" | jq -r '.content[0].text // empty')

  if [[ -z "$text" ]]; then
    echo "[ai] ERROR: Anthropic API returned no content. Response:" >&2
    echo "$response" >&2
    return 1
  fi

  echo "$text"
}

# ── Internal: OpenRouter chat completions API ─────────────────────────────────
_openrouter_text() {
  local system="$1"
  local user="$2"
  local model="${OPENROUTER_MODEL:-anthropic/claude-sonnet-4-5}"
  local max_tokens="${MAX_TOKENS:-4096}"

  local payload
  payload=$(jq -n \
    --arg model      "$model"  \
    --arg system     "$system" \
    --arg user       "$user"   \
    --argjson max_tokens "$max_tokens" \
    '{
      "model":      $model,
      "max_tokens": $max_tokens,
      "messages": [
        {"role":"system","content":$system},
        {"role":"user",  "content":$user}
      ]
    }')

  local response
  response=$(curl -s --max-time 120 \
    -X POST "https://openrouter.ai/api/v1/chat/completions" \
    -H "Authorization: Bearer ${OPENROUTER_API_KEY}" \
    -H "Content-Type: application/json" \
    -d "$payload")

  local text
  text=$(echo "$response" | jq -r '.choices[0].message.content // empty')

  if [[ -z "$text" ]]; then
    echo "[ai] ERROR: OpenRouter API returned no content. Response:" >&2
    echo "$response" >&2
    return 1
  fi

  echo "$text"
}

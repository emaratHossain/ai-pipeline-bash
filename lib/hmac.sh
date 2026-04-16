#!/usr/bin/env bash
# lib/hmac.sh — HMAC-SHA256 webhook signature verification

# verify_signature <body> <secret> <sig_header>
# sig_header format: "sha256=<hex>"
# Returns 0 (true) if valid, 1 (false) if not
verify_signature() {
  local body="$1"
  local secret="$2"
  local sig_header="$3"

  if [[ -z "$sig_header" ]]; then
    return 1
  fi

  local expected="${sig_header#sha256=}"
  if [[ "$expected" == "$sig_header" ]]; then
    # Header didn't start with "sha256="
    return 1
  fi

  local computed
  computed=$(printf '%s' "$body" | openssl dgst -sha256 -hmac "$secret" 2>/dev/null | awk '{print $NF}')

  # Constant-time comparison to avoid timing attacks
  if [[ "${#computed}" -ne "${#expected}" ]]; then
    return 1
  fi

  local diff=0
  local i
  for (( i=0; i<${#computed}; i++ )); do
    [[ "${computed:$i:1}" != "${expected:$i:1}" ]] && diff=1
  done

  return "$diff"
}

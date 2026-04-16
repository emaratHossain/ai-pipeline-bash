#!/usr/bin/env bash
# scripts/monitor.sh — Live dashboard: health check, recent log tail, active locks.
# Usage: bash scripts/monitor.sh [interval_seconds]
# Refreshes every INTERVAL seconds (default: 5).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$SCRIPT_DIR"

[[ -f .env ]] && { set -a; source .env; set +a; }

INTERVAL="${1:-5}"
PORT="${PORT:-3000}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

while true; do
  clear
  echo -e "${BOLD}  AI Pipeline Bot (bash) — Live Monitor${NC}  $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  echo "──────────────────────────────────────────────────────"

  # ── Health check ────────────────────────────────────────────────────────────
  echo -e "\n${CYAN}HEALTH${NC}"
  HEALTH=$(curl -s --max-time 2 "http://localhost:${PORT}/health" 2>/dev/null || echo "")
  if [[ -z "$HEALTH" ]]; then
    echo -e "  ${RED}● Server not responding on port $PORT${NC}"
  else
    STATUS=$(echo "$HEALTH" | jq -r '.status // "unknown"')
    PROVIDER=$(echo "$HEALTH" | jq -r '.provider // "unknown"')
    MOCK=$(echo "$HEALTH" | jq -r '.warning // ""')
    echo -e "  ${GREEN}● Server is up${NC}  provider=$PROVIDER"
    [[ -n "$MOCK" ]] && echo -e "  ${YELLOW}⚠ $MOCK${NC}"
  fi

  # ── Active locks (in-progress implementations) ───────────────────────────────
  echo -e "\n${CYAN}ACTIVE IMPLEMENTATIONS${NC}"
  LOCKS=$(find state/locks -name "*.lock" 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$LOCKS" -eq 0 ]]; then
    echo -e "  ${DIM}None${NC}"
  else
    for lock in state/locks/*.lock; do
      issue="${lock##*/}"
      issue="${issue%.lock}"
      echo -e "  ${YELLOW}⟳${NC} $issue"
    done
  fi

  # ── Recent server log ────────────────────────────────────────────────────────
  echo -e "\n${CYAN}RECENT EVENTS (server.log)${NC}"
  if [[ -f logs/server.log ]]; then
    tail -8 logs/server.log | while IFS= read -r line; do
      echo "  $line"
    done
  else
    echo -e "  ${DIM}No server log yet${NC}"
  fi

  # ── Recent pipeline logs ───────────────────────────────────────────────────────
  echo -e "\n${CYAN}RECENT PIPELINE${NC}"
  PIPELINE_LOGS=$(ls -t logs/pipeline-*.log 2>/dev/null | head -3)
  if [[ -z "$PIPELINE_LOGS" ]]; then
    echo -e "  ${DIM}No pipeline logs yet${NC}"
  else
    while IFS= read -r logfile; do
      echo -e "  ${DIM}${logfile}${NC}"
      tail -2 "$logfile" | while IFS= read -r line; do echo "    $line"; done
    done <<< "$PIPELINE_LOGS"
  fi

  # ── Recent implement logs ────────────────────────────────────────────────────
  echo -e "\n${CYAN}RECENT IMPLEMENTATIONS${NC}"
  IMPL_LOGS=$(ls -t logs/implement-*.log 2>/dev/null | head -3)
  if [[ -z "$IMPL_LOGS" ]]; then
    echo -e "  ${DIM}No implementation logs yet${NC}"
  else
    while IFS= read -r logfile; do
      echo -e "  ${DIM}${logfile}${NC}"
      tail -2 "$logfile" | while IFS= read -r line; do echo "    $line"; done
    done <<< "$IMPL_LOGS"
  fi

  echo ""
  echo -e "${DIM}  Refreshing every ${INTERVAL}s — Ctrl+C to exit${NC}"
  sleep "$INTERVAL"
done

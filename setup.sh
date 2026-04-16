#!/usr/bin/env bash
# setup.sh — Validates the environment, dependencies, git config, and .env
# before starting the bot. Run once after cloning or after changing .env.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'; BOLD='\033[1m'; NC='\033[0m'
ERRORS=0; WARNINGS=0

fail() { echo -e "${RED}[FAIL]${NC} $*"; ERRORS=$((ERRORS+1)); }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; WARNINGS=$((WARNINGS+1)); }
ok()   { echo -e "${GREEN}[ OK ]${NC} $*"; }
hr()   { echo "──────────────────────────────────────────────────"; }

hr
echo -e "${BOLD}  AI Pipeline Bot (bash) — Setup Validator${NC}"
hr

# ── 1. System dependencies ────────────────────────────────────────────────────
echo ""
echo "Checking system dependencies..."
for dep in socat jq curl openssl git flock; do
  if command -v "$dep" &>/dev/null; then
    ok "$dep → $(command -v "$dep")"
  else
    case "$dep" in
      socat)  fail "socat not found. Install: brew install socat  OR  apt install socat" ;;
      jq)     fail "jq not found.    Install: brew install jq     OR  apt install jq" ;;
      flock)  fail "flock not found. Install: brew install util-linux  OR it may be missing on macOS (use gflock)" ;;
      *)      fail "$dep not found" ;;
    esac
  fi
done

# flock on macOS is often 'gflock' (from util-linux via homebrew)
if ! command -v flock &>/dev/null && command -v gflock &>/dev/null; then
  warn "flock not found but gflock is — consider: ln -s \$(which gflock) /usr/local/bin/flock"
fi

# ── 2. .env file ──────────────────────────────────────────────────────────────
echo ""
echo "Checking .env..."
if [[ ! -f .env ]]; then
  if [[ -f .env.example ]]; then
    warn ".env not found — copying from .env.example"
    cp .env.example .env
    echo "  Edit .env with your credentials and re-run setup.sh"
    exit 1
  else
    fail ".env not found and no .env.example to copy from"
    exit 1
  fi
fi

set -a; source .env; set +a
ok ".env loaded"

# ── 3. Required env vars ──────────────────────────────────────────────────────
echo ""
echo "Checking required variables..."

check_var() {
  local var="$1"
  local val="${!var:-}"
  if [[ -z "$val" ]]; then
    fail "$var is not set"
    return
  fi
  if [[ "$val" == *"..."* || "$val" == *"replace"* || "$val" == *"your-"* || "$val" == "owner/repo-name" ]]; then
    fail "$var still has a placeholder value"
    return
  fi
  case "$var" in
    *KEY*|*SECRET*|*TOKEN*)
      ok "$var = ${val:0:8}…(masked)" ;;
    *)
      ok "$var = $val" ;;
  esac
}

for v in GITHUB_TOKEN GITHUB_REPO GITHUB_WEBHOOK_SECRET BOT_USERNAME REPO_PATH; do
  check_var "$v"
done

AI_PROVIDER="${AI_PROVIDER:-anthropic}"
case "$AI_PROVIDER" in
  anthropic)
    check_var ANTHROPIC_API_KEY ;;
  openrouter)
    check_var OPENROUTER_API_KEY
    check_var OPENROUTER_MODEL ;;
  opencode)
    OPENCODE_BIN="${OPENCODE_PATH:-opencode}"
    if command -v "$OPENCODE_BIN" &>/dev/null; then
      ok "opencode → $(command -v "$OPENCODE_BIN")"
    else
      fail "opencode not found. Install: npm install -g opencode@latest"
    fi ;;
  *)
    fail "Unknown AI_PROVIDER '$AI_PROVIDER' — must be 'anthropic', 'openrouter', or 'opencode'" ;;
esac

# ── 4. GITHUB_REPO format ─────────────────────────────────────────────────────
echo ""
echo "Checking GITHUB_REPO format..."
GITHUB_REPO="${GITHUB_REPO:-}"
if [[ "$GITHUB_REPO" =~ ^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$ ]]; then
  ok "GITHUB_REPO format valid: $GITHUB_REPO"
else
  fail "GITHUB_REPO must be 'owner/repo', got: '$GITHUB_REPO'"
fi

# ── 5. REPO_PATH ──────────────────────────────────────────────────────────────
echo ""
echo "Checking REPO_PATH..."
REPO_PATH="${REPO_PATH:-}"
if [[ ! -d "$REPO_PATH" ]]; then
  fail "REPO_PATH does not exist: $REPO_PATH"
elif [[ ! -d "$REPO_PATH/.git" ]]; then
  fail "REPO_PATH is not a git repository: $REPO_PATH"
elif [[ ! -w "$REPO_PATH" ]]; then
  fail "REPO_PATH is not writable: $REPO_PATH"
else
  ok "REPO_PATH is a writable git repository: $REPO_PATH"
fi

# ── 6. Git user config ────────────────────────────────────────────────────────
echo ""
echo "Checking git config in REPO_PATH..."
if [[ -d "${REPO_PATH:-}/.git" ]]; then
  GIT_USER=$(git -C "$REPO_PATH" config user.name  2>/dev/null || echo "")
  GIT_EMAIL=$(git -C "$REPO_PATH" config user.email 2>/dev/null || echo "")
  if [[ -z "$GIT_USER" ]]; then
    warn "git user.name not set — auto-setting to 'AI Pipeline Bot'"
    git -C "$REPO_PATH" config user.name "AI Pipeline Bot"
  fi
  if [[ -z "$GIT_EMAIL" ]]; then
    warn "git user.email not set — auto-setting to 'bot@ai-pipeline.local'"
    git -C "$REPO_PATH" config user.email "bot@ai-pipeline.local"
  fi
  ok "git user: $(git -C "$REPO_PATH" config user.name) <$(git -C "$REPO_PATH" config user.email)>"
fi

# ── 7. Base branch ────────────────────────────────────────────────────────────
echo ""
echo "Checking base branch..."
BASE="${BASE_BRANCH:-main}"
if [[ -d "${REPO_PATH:-}/.git" ]]; then
  if git -C "$REPO_PATH" show-ref --quiet "refs/heads/$BASE" 2>/dev/null || \
     git -C "$REPO_PATH" show-ref --quiet "refs/remotes/origin/$BASE" 2>/dev/null; then
    ok "Base branch '$BASE' exists"
  else
    fail "Base branch '$BASE' not found in $REPO_PATH — check BASE_BRANCH in .env"
  fi
fi

# ── 8. Port availability ──────────────────────────────────────────────────────
echo ""
echo "Checking port availability..."
PORT="${PORT:-3000}"
if lsof -iTCP:"$PORT" -sTCP:LISTEN -n -P &>/dev/null 2>&1; then
  warn "Port $PORT is already in use — kill the existing process before starting"
else
  ok "Port $PORT is free"
fi

# ── 9. Script permissions ─────────────────────────────────────────────────────
echo ""
echo "Setting script permissions..."
chmod +x server.sh handle_webhook.sh pipeline.sh implement.sh
ok "All scripts are executable"

# ── 10. Mock mode ─────────────────────────────────────────────────────────────
echo ""
if [[ "${MOCK_MODE:-false}" == "true" ]]; then
  warn "MOCK_MODE=true — bot will NOT make real AI calls"
fi

# ── Result ────────────────────────────────────────────────────────────────────
echo ""
hr
if [[ "$ERRORS" -gt 0 ]]; then
  echo -e "${RED}Setup failed with $ERRORS error(s). Fix the issues above and re-run.${NC}"
  exit 1
else
  if [[ "$WARNINGS" -gt 0 ]]; then
    echo -e "${YELLOW}Setup passed with $WARNINGS warning(s).${NC}"
  else
    echo -e "${GREEN}All checks passed — ready to start the bot.${NC}"
  fi
  echo ""
  echo "  Start the server:  bash server.sh"
  echo "  Test pipeline:       bash scripts/test-pipeline.sh <issue_number>"
  echo "  Test implement:    bash scripts/test-implement.sh <issue_number>"
  echo "  View logs:         tail -f logs/server.log"
fi

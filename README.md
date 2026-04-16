# AI Pipeline Bot (Bash)

A lightweight GitHub bot that automatically analyzes new issues with AI and implements fixes — all from the command line, no Node.js required.

---

## What It Does

1. **A new issue is opened** on your GitHub repo
2. **The bot analyzes it** using AI and posts a plan comment like:

   > ## 🤖 AI Pipeline Plan
   > **Type:** Bug Fix
   > **Affected files:** `src/handler.js`
   > ### Root Cause / Summary
   > ...
   > ### Proposed Changes
   > 1. ...

3. **You review the plan** — edit the comment if needed
4. **Comment `/approve`** on the issue
5. **The bot creates a branch**, implements the changes, and **opens a Pull Request** automatically

---

## Requirements

| Tool | Install |
|------|---------|
| `bash` | Pre-installed on Linux/macOS |
| `socat` | `brew install socat` / `apt install socat` |
| `jq` | `brew install jq` / `apt install jq` |
| `curl` | Pre-installed on most systems |
| `openssl` | Pre-installed on most systems |
| `git` | Pre-installed on most systems |
| `opencode` | `npm install -g opencode@latest` *(if using OpenCode provider)* |

---

## Setup

### 1. Clone the repo

```bash
git clone https://github.com/emaratHossain/ai-pipeline-bash.git
cd ai-pipeline-bash
```

### 2. Create your `.env` file

```bash
cp .env.example .env
```

Open `.env` and fill in these values:

| Variable | What to put |
|----------|-------------|
| `GITHUB_TOKEN` | A GitHub Personal Access Token with Issues, Pull Requests, and Contents permissions |
| `GITHUB_REPO` | Your repo in `owner/repo` format (e.g. `alice/my-project`) |
| `GITHUB_WEBHOOK_SECRET` | Any long random string — you'll use the same value in GitHub webhook settings |
| `BOT_USERNAME` | The GitHub username whose token you're using |
| `REPO_PATH` | Absolute path to a local clone of your repo (e.g. `/home/alice/my-project`) |
| `AI_PROVIDER` | `opencode`, `anthropic`, or `openrouter` — see below |

### 3. Choose your AI provider

#### OpenCode (recommended — free)

Uses your locally installed OpenCode CLI. It explores the repo intelligently with real file tools.

```env
AI_PROVIDER=opencode
OPENCODE_PATH=opencode        # path to binary, default: opencode
OPENCODE_TIMEOUT=300          # seconds for plan step (default: 300)
```

Install OpenCode first:
```bash
npm install -g opencode@latest
```

#### Anthropic

```env
AI_PROVIDER=anthropic
ANTHROPIC_API_KEY=sk-ant-...
```

#### OpenRouter (free models available)

```env
AI_PROVIDER=openrouter
OPENROUTER_API_KEY=sk-or-...
OPENROUTER_MODEL=google/gemini-2.0-flash-exp:free
```

Free models on OpenRouter: `google/gemini-2.0-flash-exp:free`, `meta-llama/llama-3.3-70b-instruct:free`

### 4. Run the setup validator

```bash
bash setup.sh
```

This checks all dependencies and your `.env` values. Fix any errors it reports, then re-run until you see **"All checks passed"**.

### 5. Configure the GitHub Webhook

In your GitHub repo go to **Settings → Webhooks → Add webhook**:

- **Payload URL:** `http://your-server-ip:3000/webhook`
- **Content type:** `application/json`
- **Secret:** the same value you set for `GITHUB_WEBHOOK_SECRET`
- **Events:** select **Issues** and **Issue comments**

> If running locally, use a tunnel like [ngrok](https://ngrok.com): `ngrok http 3000` and use the generated URL.

### 6. Start the bot

```bash
bash server.sh
```

The bot is now listening. Open an issue on your repo to test it.

---

## How Each Provider Works

| | OpenCode | Anthropic | OpenRouter |
|---|---|---|---|
| Cost | Free | Paid | Free models available |
| Repo exploration | Reads files with real tools | Keyword-based context | Keyword-based context |
| Plan quality | Best (sees full context) | Good | Good |
| Implementation | Writes files directly | Returns JSON → bot writes files | Returns JSON → bot writes files |
| Requires API key | No | Yes | Yes |

---

## Testing Without a Real Webhook

You can trigger the pipeline or implementation manually:

```bash
# Simulate pipeline on an existing issue
bash scripts/test-pipeline.sh <issue_number>

# Simulate implementation on an approved issue
bash scripts/test-implement.sh <issue_number>
```

To test without making real AI calls, set `MOCK_MODE=true` in your `.env`.

---

## Folder Structure

```
ai-pipeline-bash/
├── server.sh             # Start the webhook server
├── handle_webhook.sh     # Receives and dispatches GitHub events
├── pipeline.sh           # Analyzes an issue and posts a plan
├── implement.sh          # Implements the plan and opens a PR
├── setup.sh              # Validates your environment before first run
├── lib/
│   ├── ai.sh             # AI API calls (Anthropic / OpenRouter / OpenCode)
│   ├── github.sh         # GitHub API helpers
│   ├── repo_context.sh   # Extracts relevant code from your repo
│   └── hmac.sh           # Webhook signature verification
├── scripts/
│   ├── test-pipeline.sh  # Manual pipeline trigger
│   ├── test-implement.sh # Manual implement trigger
│   ├── monitor.sh        # Watch logs live
│   └── cleanup-branches.sh # Remove old fix/* branches
├── logs/                 # Server and per-issue logs
└── .env.example          # Config template
```

---

## Viewing Logs

```bash
# Live server log
tail -f logs/server.log

# Log for a specific issue
tail -f logs/pipeline-42.log
tail -f logs/implement-42.log
```

---

## Trusted Users

By default, anyone who can comment on an issue can trigger `/approve`. To restrict this, set `TRUSTED_USERS` in `.env`:

```
TRUSTED_USERS=alice,bob
```

Only those usernames will be able to approve implementation.

---

## Quick Reference

| Action | Command |
|--------|---------|
| Validate setup | `bash setup.sh` |
| Start the bot | `bash server.sh` |
| Test pipeline manually | `bash scripts/test-pipeline.sh <issue_number>` |
| Test implement manually | `bash scripts/test-implement.sh <issue_number>` |
| Watch live logs | `bash scripts/monitor.sh` |
| Clean up old branches | `bash scripts/cleanup-branches.sh` |
| Health check | `curl http://localhost:3000/health` |

# statusline

A single-line Claude Code status line that shows model, directory, git state, token usage, reasoning effort, and live 5h / 7d / extra usage pulled from Anthropic's OAuth usage endpoint.

Example:

```
Opus 4.6 | claude-code-lab@main (+12 -3) | 34k/200k (17%) | effort: high | 5h 22% @3:45pm | 7d 48% @apr 18, 9:00am
```

## What it shows

- **Model** — `.model.display_name` from the statusline payload.
- **cwd + git** — current dir name, branch, and `+added -deleted` from `git diff --numstat`.
- **Token usage** — current context window usage and percent of the configured window.
- **Effort** — reads `$CLAUDE_CODE_EFFORT_LEVEL` or `effortLevel` in `~/.claude/settings.json`.
- **5h / 7d / extra** — pulled from `https://api.anthropic.com/api/oauth/usage` using your Claude Code OAuth token. Cached in `/tmp/claude/statusline-usage-cache.json` for 60s so every render doesn't hit the API.

## Supported platforms

- **macOS** — primary target. Uses BSD `date`, `security` (Keychain), `stat -f`.
- **Linux** — supported via fallbacks. Uses GNU `date`, `~/.claude/.credentials.json` or `secret-tool` (GNOME Keyring), `stat -c`.

## Prerequisites

- `bash`
- `jq`
- `curl`
- `awk`, `date` — ship with macOS/Linux
- **Claude Code** with a valid OAuth token in one of:
  - `$CLAUDE_CODE_OAUTH_TOKEN` env var
  - macOS Keychain entry `Claude Code-credentials`
  - `~/.claude/.credentials.json`
  - GNOME Keyring via `secret-tool`

If none of those resolve a token, the usage section is omitted gracefully.

Install `jq` if needed:

```sh
# macOS
brew install jq

# Debian/Ubuntu
sudo apt install jq
```

## Install

1. Copy the script into `~/.claude/`:

   ```sh
   cp statusline.sh ~/.claude/statusline.sh
   chmod +x ~/.claude/statusline.sh
   ```

2. Wire it up in `~/.claude/settings.json`:

   ```json
   {
     "statusLine": {
       "command": "~/.claude/statusline.sh"
     }
   }
   ```

3. Restart Claude Code (or start a new session).

## Notes

- The usage endpoint (`/api/oauth/usage`) is an undocumented beta endpoint Claude Code itself calls. It can change without notice — if the usage section disappears, the shape likely changed.
- The 60s cache keeps things cheap, but the first render after a stale cache will block on `curl` for up to 10s.
- All colors are ANSI truecolor (`\033[38;2;R;G;B`). Terminals without truecolor support will render them as approximations.

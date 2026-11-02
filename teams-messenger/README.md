# Teams Messenger

A Claude Code skill that lets Claude use Microsoft Teams for you.

> **"Send Jane the deck in Downloads."** **"What did John say about the release?"** **"Set up a 30 minute meeting with Jane tomorrow at 3pm about the roadmap."**

It sends 1:1 and group-chat messages and files, reads and searches chat history, and schedules Teams meetings with invites on your Outlook calendar. It works without Microsoft Graph or an admin-approved app, so no IT setup is needed.

---

## How it works

```
Claude ──▶ scripts/teams ──▶ hidden Chrome (your signed-in profile) ──▶ login passes, in memory only
                │                         closes before any work
                └──▶ plain HTTPS calls ──▶ Teams chat service   (messages, history)
                                       ──▶ SharePoint / OneDrive (people lookup, file uploads)
                                       ──▶ Outlook calendar API  (meetings + invites)
```

- **You sign in once** in a separate Chrome window (`teams auth`). Microsoft keeps you signed in inside a private browser profile used only by this skill.
- **Every command** starts that Chrome profile hidden, opens Teams on the web, takes the short-lived login passes Teams itself uses, and closes Chrome. All real work then happens over plain HTTPS. The passes stay in memory and are never written to disk or printed.
- **It never touches the Teams app** on your computer, your normal browser, or your screen.
- **It checks its work.** Every recipient is matched to an exact person in your company directory. After every send it reads the chat back to confirm the message landed. After every meeting it reads the event back to confirm the title, time, attendees, Teams link, and that invites went out. Receipts stop accidental duplicate sends.

## Requirements

- **macOS** (built and tested on macOS 26). Linux will probably work but is untested. Windows is not supported.
- **Google Chrome**, installed normally. The skill uses your real Chrome, not a downloaded test browser.
- **Node.js 18 or newer** and **Python 3**.
- **Playwright**, the library the skill uses to start Chrome hidden. Install it globally (step 2 below).
- **A work Microsoft 365 account** that can open Teams on the web. Meetings also need an Outlook mailbox, and file sends need OneDrive.
- **[Claude Code](https://claude.com/claude-code)**.

## Setup

1. **Install the skill.** Copy this folder to Claude Code's skills folder:

   ```bash
   cp -R teams-messenger ~/.claude/skills/teams-messenger
   ```

2. **Install Playwright.** No `npx playwright install` is needed, because the skill uses your installed Chrome.

   ```bash
   npm install -g playwright
   ```

   If Playwright ends up outside `/opt/homebrew/lib/node_modules` or `/usr/local/lib/node_modules`, tell the skill where it is with `PLAYWRIGHT_NODE_PATH`.

3. **Create your contacts file.** This lets you say "Jane" instead of a full email address. Use one `Full Name = email` line per person. The file is gitignored, so your coworkers' details stay private.

   ```bash
   cp ~/.claude/skills/teams-messenger/scripts/teams_contacts.example.txt ~/.claude/skills/teams-messenger/scripts/teams_contacts.txt
   ```

4. **Sign in once.** A Chrome window opens. Sign in to Teams with your work account and finish MFA. The window closes on its own when Teams has loaded.

   ```bash
   ~/.claude/skills/teams-messenger/scripts/teams auth
   ```

5. **Check it works.** This should print `"authenticated": true`.

   ```bash
   ~/.claude/skills/teams-messenger/scripts/teams status
   ```

You only repeat step 4 when Microsoft signs you out (for example after a password change or when your company's sign-in policy expires the session).

## Using it

Just ask Claude in plain words. Claude picks the right command, and **always shows you a meeting before sending the invite**.

You can also run the commands yourself:

```bash
scripts/teams lookup "Jane"                                   # find someone's exact email
scripts/teams send jane.d@example.com "Hi Jane"
scripts/teams send-file jane.d@example.com /absolute/path/report.pdf --message "Latest numbers"
scripts/teams read jane.d@example.com --limit 20
scripts/teams search jane.d@example.com "release date"
scripts/teams list                                            # recent chats, including group chat IDs
scripts/teams group-send "<group-chat-id>" "<exact group name>" "Hello team"

# Meetings: preview first (sends nothing), then create
scripts/teams meeting-preview "Roadmap review" --start 2026-11-03T15:00 --duration 30 --attendees jane.d@example.com
scripts/teams meeting         "Roadmap review" --start 2026-11-03T15:00 --duration 30 --attendees jane.d@example.com
```

Meeting notes:

- `--start` is the local time in `--timezone`. The default zone is `India Standard Time`. Pass `--timezone` with one of the supported Windows zone names (the error message lists them) if you are elsewhere.
- `--duration` is 5 to 480 minutes, default 30. Leave out `--attendees` to make a meeting with a Teams link on your own calendar only.
- Only people in your own company email domain can be invited.
- Moving or cancelling meetings is not supported yet.

`SKILL.md` has the full rules Claude follows, including what each result field means.

## Troubleshooting

| Message | What to do |
| --- | --- |
| `authentication_required` | Run `scripts/teams auth` and sign in again. |
| `playwright_missing` | Install Playwright (setup step 2) or set `PLAYWRIGHT_NODE_PATH`. |
| `token_browser_unavailable` | Another copy of the skill's Chrome profile is open. Wait for the other command to finish, or close that Chrome window. |
| `operation_in_progress` | Another Teams command is running. The skill runs one at a time. Try again in a moment. |
| `outlook_auth_unavailable` | The Teams calendar did not load in time. Try again. If it keeps happening, run `scripts/teams auth`. |
| `send_result_ambiguous` | The send or meeting may or may not have gone through. Check Teams or your calendar before retrying with `--force`. |
| Sign-in is blocked | Your company may only allow sign-in from managed devices or browsers. This skill cannot work around that. |

## Where things are stored

Everything lives in `~/Library/Application Support/Codex Teams Messenger/` (change it with `TEAMS_WEB_APP_DIR`):

- `browser-profile/`: the private Chrome profile that keeps you signed in.
- `receipts.json`: proof of past sends and meetings, used to block duplicates. It holds hashes and IDs, not message text.
- `auth-resources.json`: your user ID and your company's SharePoint addresses. No passwords or tokens.

## Limits

- Messages and invites always come from the person who signed in.
- The skill relies on parts of Teams on the web that are not a public API. A Microsoft update can break it until the code is updated.
- Existing chats only. It does not start new chats or post to channels.

## Tests

The unit tests make no network calls and need no browser:

```bash
node --test scripts/tests/api.test.cjs
```

`scripts/tests/live-regression.cjs` sends real messages and files. Only run it on purpose, with a test recipient who has agreed to it.

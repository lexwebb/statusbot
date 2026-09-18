# statusbot

Three cooperating cron-style jobs that use the Claude CLI to keep one person on
top of their team's GitHub + Slack, and to act on their behalf. Each is a plain
bash script scheduled by a macOS launchd agent; all instance-specific settings
live in a single gitignored `config.json`.

| Script | Schedule | What it does |
|--------|----------|--------------|
| `run.sh` | every 30 min, 09:00–18:00 | Collects recent GitHub/Slack state (`collect.sh`), has `claude -p` write a short digest, posts it to your Slack notify channel. First run each day is a fuller "morning brief". |
| `review.sh` | every 5 min, 24/7 | Finds open org PRs that aren't yours and that no human has engaged, checks each out into a throwaway worktree, and a `claude -p` sub-agent posts a review **to GitHub as you**, plus a one-line verdict routed by workstream. Keyed by head SHA: one review per push. A cheap `/notifications` change-gate makes idle passes nearly free (a 304 costs no quota), so the tight cadence is cheap and recovers fast after a network blip. Runs overnight too — a review isn't time-of-day sensitive and the author gets feedback sooner. |
| `slack-watch.sh` | every 5 min, 09:00–18:00 | Reads new messages in the watched channels + the bot's DMs. Per message: **reply** (mentions/DMs), **flag** a code issue (investigate + brief you), **ask** (an allowlisted teammate's code question → code-grounded answer in-thread), or **review** (an allowlisted teammate's "review PR X" → runs `review.sh --pr` for it). |
| `slack-socket.mjs` | resident daemon (optional) | Socket Mode WebSocket. On a live @-mention or DM, invokes `slack-watch.sh --once <channel> --respect-hours` for a **seconds-fast** reply instead of waiting up to 5 min for the poll. Reuses all of `slack-watch.sh`'s logic — it's just a faster trigger. Only installed when `config.json` has an `appToken`; the 5-min poll stays as the backstop. |

`collect.sh` is a helper for `run.sh` (prints a plain-text state bundle).
`lib.sh` is sourced by every script for PATH setup and macOS/Linux `date`/`stat`
shims. The `*-prompt.md` files are the system prompts; they use `{{OWNER}}` /
`{{GITHUB_USER}}` placeholders that the scripts fill from config at runtime.

## Requirements

- **macOS** (launchd) or **Linux** (systemd user timers, or cron). Windows via WSL.
- `bash`, `jq`, `perl`, `git`, `curl`, and the GitHub `gh` CLI (`gh auth login`).
- The **Claude CLI** (`claude`), logged in — this is what does the reasoning.
- A **Slack app / bot** in your workspace with a bot token (`xoxb-…`).

### Slack bot scopes

`chat:write`, `chat:write.public`, `channels:history`, `groups:history`,
`im:history`, `im:read`, `users:read`, `app_mentions:read`, `channels:read`,
`groups:read`, `channels:join`. To *read* a channel the bot must be a **member**
of it — `slack-watch.sh` self-joins discovered `feature*` public channels
(`channels:join`); otherwise `/invite @your-bot`. `chat:write.public` only covers
posting.

### Socket Mode daemon (optional — faster @-mention/DM replies)

The 5-min poll answers a direct @-mention or DM within ~5 min. For a
seconds-fast reply, enable the `slack-socket.mjs` daemon:

1. In your Slack app config, turn on **Socket Mode**.
2. Create an **app-level token** (`xapp-…`) with the `connections:write` scope;
   put it in `config.json` as `appToken`.
3. Under **Event Subscriptions → Subscribe to bot events**, add `app_mention`
   and `message.im` (needs `app_mentions:read` + `im:history`, already listed).
4. Re-run `./install.sh`. It validates the app token (`apps.connections.open`),
   runs `npm install` for `@slack/socket-mode`, and installs a `KeepAlive`
   launchd/systemd daemon. Omit `appToken` to stay poll-only.

The daemon only fast-tracks **direct address** (mentions + DMs). Channel
watching and the flag/investigate path stay on the poll — deliberately, so the
daemon can't make the bot chattier, only quicker. The poll is also the backstop:
if the daemon dies or misses an event, the next poll still handles it.

### On-demand requests (ask / review)

Teammates can direct the bot to act:

- **Ask a code question** — "@bot how does the auth flow work in auth-service?"
  The bot checks out the repo (read-only, budget-capped) and answers in-thread,
  grounded in the code.
- **Review a PR** — "@bot review PR price-comparison-tool#1963" (or paste a PR
  URL). The bot runs a full review that posts to the GitHub PR **as you** and to
  the routed Slack channel.

Both are **allowlist-gated**: only people in `config.users` (by Slack user id)
can invoke them. A request from anyone else is silently ignored (logged, no
reply). Authorization is enforced in `slack-watch.sh`, not by the classifier —
a prompt-injected "ignore the rules" message can't act unless its *sender* is on
the allowlist. `reply`/`flag` are unprivileged and open to anyone as before.

## Setup

1. `cp config.example.json config.json` and fill it in (it's gitignored). See
   the field notes below.
2. Invite the bot to every channel you list under `watch` and to any channel in
   the review routing `channels` map.
3. Run **`./install.sh`**. It checks prerequisites, validates config, writes
   `path.env` (the tool dirs the schedulers need), sanity-checks the Slack token
   and channel membership, then installs and starts the schedulers:
   - macOS → three launchd agents in `~/Library/LaunchAgents/`
   - Linux → three systemd user timers (or crontab lines if systemd is absent)

   Re-run any time after editing config. `./install.sh --no-schedule` validates
   without touching the scheduler; `./install.sh --uninstall` removes it.
4. Smoke-test: `./run.sh --dry-run`, `./review.sh --dry-run --pr owner-repo#123`,
   `./slack-watch.sh --dry-run`.

On Linux, add `sudo loginctl enable-linger $(whoami)` if you want the timers to
run while you're logged out.

### config.json fields

| Field | Meaning |
|-------|---------|
| `botToken` | Slack bot token (`xoxb-…`). |
| `githubOrg` | GitHub org the review + investigate passes operate on. |
| `githubUser` | Your GitHub login — PRs by you are skipped; reviews post as you. |
| `ownerName` | Your name, injected into prompts (`{{OWNER}}`). |
| `botUserId` | The bot's Slack user id (`U…`) — used to ignore its own messages. |
| `notifyChannel` / `notifyUserId` | Where digests + issue flags go, and who to @. |
| `defaultChannel` | Fallback channel for `collect.sh` context. |
| `botLogins` | GitHub logins treated as bots and skipped by the review pass. |
| `default` / `fallback` / `channels` | PR-review Slack routing (by workstream). |
| `users` | GitHub login → Slack user id, for @-mentions in write-ups. |
| `watch` | `[{id,name}]` channels `slack-watch.sh` monitors (bot must be a member). |
| `repos` | `[{name,for}]` the classifier can route an issue to and investigate. |

## State & safety

- Runtime state lives in `state/` (gitignored): per-conversation cursors, seen
  SHAs, Slack thread anchors, logs, a bare-clone cache in `repos/`, and
  throwaway worktrees in `wt/`.
- `slack-watch.sh` seeds a conversation's cursor at "now" on first sighting, so
  it never replies to backlog; it skips the bot's own messages (no loops) and
  caps replies + investigations per pass. Replies are **auto-sent** as the bot.
- Each runs one-at-a-time via a `mkdir` lock. `run.sh` and `slack-watch.sh` only
  act 09:00–18:00; `review.sh` runs 24/7 (a review isn't time-of-day sensitive).

Tune caps/models/hours via the constants at the top of each script (or the
`REVIEW_MODEL` / `SLACK_WATCH_MODEL` / `SLACK_INVESTIGATE_MODEL` env vars).

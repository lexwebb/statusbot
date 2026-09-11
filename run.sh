#!/usr/bin/env bash
# run.sh — collect state, digest it with the Claude CLI, post to Slack.
# Scheduled by ~/Library/LaunchAgents/me.lex.claude-statusbot.plist (every 30 min).
# Manual dry run (prints, posts nothing):  run.sh --dry-run
set -uo pipefail

DIR="${HOME}/.claude/statusbot"
STATE="$DIR/state"
LOG="$STATE/run.log"
LOCK="$STATE/lock.d"
CONFIG="$DIR/config.json"
MODEL="sonnet"

# Only bother Lex during the working day. Last tick is 17:30.
START_HOUR=9
END_HOUR=18

DRY_RUN=0
SINCE_OVERRIDE=""
FORCE_MORNING=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --since)   SINCE_OVERRIDE="${2:-}"; shift 2 ;;
    --morning) FORCE_MORNING=1; shift ;;   # test the 9am brief on demand
    *)         echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$STATE"
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }

# launchd can overlap a slow run with the next tick; one at a time.
# ponytail: mkdir mutex — macOS has no flock(1). Stale lock cleared after 20 min.
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +20 2>/dev/null)" ]; then
    log "clearing stale lock"
    rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null || { log "lock busy, skipping"; exit 0; }
  else
    log "previous run still going, skipping"
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

# PATH for launchd, which starts with a bare environment.
export PATH="${HOME}/.nvm/versions/node/v22.17.0/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

NOW=$(date +%s)
HOUR=$(date +%H); HOUR=${HOUR#0}
TODAY=$(date +%Y-%m-%d)

if [ "$DRY_RUN" = "0" ] && { [ "$HOUR" -lt "$START_HOUR" ] || [ "$HOUR" -ge "$END_HOUR" ]; }; then
  exit 0
fi

# First run of a new day is a full recap of the previous working day, not a
# 30-minute delta. On Monday "the day before" means Friday, or the brief would
# summarise a quiet weekend.
MODE="normal"
if [ "$FORCE_MORNING" = "1" ] || [ "$(cat "$STATE/last-morning" 2>/dev/null)" != "$TODAY" ]; then
  MODE="morning"
  if [ "$(date +%u)" = "1" ]; then
    MORNING_SINCE=$(date -v-3d -v0H -v0M -v0S +%s)   # Monday → back to Friday
  else
    MORNING_SINCE=$(date -v-1d -v0H -v0M -v0S +%s)
  fi
fi

if [ -n "$SINCE_OVERRIDE" ]; then
  SINCE="$SINCE_OVERRIDE"
elif [ "$MODE" = "morning" ]; then
  SINCE="$MORNING_SINCE"
else
  SINCE=$(cat "$STATE/last-run" 2>/dev/null || echo $(( NOW - 1800 )))
fi

DUMP=$("$DIR/collect.sh" "$SINCE" "$MODE" 2>>"$LOG")
if [ -z "$DUMP" ]; then
  log "collect.sh produced nothing — aborting"
  exit 1
fi

if [ "$MODE" = "morning" ]; then
  # A recap is supposed to restate yesterday, so give it nothing to dedupe against.
  PREV="(none — this is the morning brief, restate the day in full)"
  DUMP="=== MODE: MORNING BRIEF ===
$DUMP"
else
  PREV=$(cat "$STATE/last-digest.md" 2>/dev/null)
  [ -z "$PREV" ] && PREV="(none — first run)"
fi

# `cd` to a non-repo dir so no project CLAUDE.md or LSP gets pulled in, and give
# the model no tools: it only has to read the dump it was handed.
DIGEST=$(cd "$DIR" && claude -p "$DUMP

=== PREVIOUS DIGEST (what you already told Lex last run) ===
$PREV" \
  --append-system-prompt "$(cat "$DIR/prompt.md")" \
  --model "$MODEL" \
  --allowed-tools '' 2>>"$LOG")
RC=$?

if [ $RC -ne 0 ] || [ -z "$DIGEST" ]; then
  log "claude failed (rc=$RC), digest empty"
  # Report a broken bot once, not every 30 minutes.
  if [ "$(cat "$STATE/last-error" 2>/dev/null)" != "claude-failed" ] && [ "$DRY_RUN" = "0" ]; then
    DIGEST="⚠️ status bot could not run \`claude -p\` (rc=$RC). Check \`$LOG\` — likely an expired login."
    echo "claude-failed" >"$STATE/last-error"
  else
    exit 1
  fi
else
  rm -f "$STATE/last-error"
  # Advance the window only on a good real run, so neither a failure nor a
  # --dry-run swallows activity the next post should have covered. The morning
  # stamp lands only after a successful post, so a failed 9am brief retries.
  if [ "$DRY_RUN" = "0" ]; then
    echo "$NOW" >"$STATE/last-run"
    [ "$MODE" = "morning" ] && echo "$TODAY" >"$STATE/last-morning"
  fi
fi

if [ "${DIGEST:0:9}" = "NO_UPDATE" ]; then
  if [ "$MODE" != "morning" ]; then
    log "no update worth posting"
    exit 0
  fi
  # The morning brief always goes out, even after a genuinely dead weekend.
  DIGEST="Nothing moved since the last working day. Review queue and tickets below are still worth a look."
fi

if [ "$DRY_RUN" = "1" ]; then
  printf '%s\n' "$DIGEST"
  exit 0
fi

TOKEN=$(jq -r '.botToken // empty' "$CONFIG" 2>/dev/null)
CHANNEL=$(jq -r '.notifyChannel // "C0B68775U64"' "$CONFIG" 2>/dev/null)
USER_ID=$(jq -r '.notifyUserId // "U06K1K67Y8P"' "$CONFIG" 2>/dev/null)
if [ -z "$TOKEN" ]; then
  log "no botToken in $CONFIG — cannot post"
  exit 1
fi

# The FEBot bot token is what actually notifies Lex; a user-token message to
# himself is treated as a self-message and stays silent.
if [ "$MODE" = "morning" ]; then
  HEADER="🌅 *Morning brief* · $(date '+%A %d %b')  <@${USER_ID}>"
else
  HEADER="🕐 *Status* · $(date '+%a %H:%M')  <@${USER_ID}>"
fi

PAYLOAD=$(jq -n --arg ch "$CHANNEL" \
  --arg text "$HEADER
$DIGEST" \
  '{channel: $ch, text: $text, unfurl_links: false, unfurl_media: false}')

RESP=$(curl -sS -X POST https://slack.com/api/chat.postMessage \
  -H "Authorization: Bearer ${TOKEN}" \
  -H "Content-Type: application/json; charset=utf-8" \
  --data "$PAYLOAD" 2>&1)

if [ "$(printf '%s' "$RESP" | jq -r '.ok // false' 2>/dev/null)" = "true" ]; then
  printf '%s' "$DIGEST" >"$STATE/last-digest.md"
  log "posted ($(printf '%s' "$DIGEST" | wc -c | tr -d ' ') bytes)"
else
  log "slack error: $(printf '%s' "$RESP" | jq -r '.error // .' 2>/dev/null)"
  exit 1
fi

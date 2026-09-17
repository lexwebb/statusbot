#!/usr/bin/env bash
# slack-watch.sh — third sibling to run.sh (talks to the owner) and review.sh (talks
# to the org's PRs). This one watches Slack: it reads new messages in the
# watched channels + the bot's DMs and, per message, either replies as the bot,
# or flags a code-related issue to the owner after investigating it against the repo.
#
# Scheduled by ~/Library/LaunchAgents/me.lex.claude-slack-watch.plist.
#
#   slack-watch.sh              # normal pass: reply + flag + investigate
#   slack-watch.sh --dry-run    # classify, print what it WOULD do, send nothing,
#                               # and do NOT advance the per-conversation cursors
#   slack-watch.sh --once C123  # only this channel id, ignoring the watch list
set -uo pipefail

DIR="${HOME}/.claude/statusbot"
STATE="$DIR/state"
LOG="$STATE/slack-watch.log"
LOCK="$STATE/slack-watch-lock.d"
SEEN="$STATE/slack-seen"          # <conversationId> → last ts processed
USERCACHE="$STATE/slack-users.json"
CONFIG="$DIR/config.json"         # all instance config: token, org, watch list, repos
REPOS="$DIR/repos"                # reuse review.sh's bare-clone cache
WORKTREES="$DIR/wt"
. "$DIR/lib.sh"                   # PATH for schedulers + cross-platform date/stat shims

CLASSIFY_MODEL="${SLACK_WATCH_MODEL:-sonnet}"
INVESTIGATE_MODEL="${SLACK_INVESTIGATE_MODEL:-opus}"

MAX_REPLIES=5         # replies sent per pass — a blast cap
MAX_INVESTIGATE=2     # code investigations per pass — a cost cap
HIST_LIMIT=50         # messages pulled per conversation per pass
BUDGET_USD=2          # per investigation sub-agent
START_HOUR=9          # same working-day window as the siblings; a reply or a
END_HOUR=18           # flag landing at 4am is the wrong time for both.

DRY_RUN=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --once)    ONLY="${2:-}"; shift 2 ;;
    *)         echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$STATE" "$SEEN" "$REPOS" "$WORKTREES"
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }

# One pass at a time. ponytail: mkdir mutex, same as run.sh/review.sh (no flock
# on macOS). 30 min is well past a normal pass even with two investigations.
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +30 2>/dev/null)" ]; then
    log "clearing stale lock"; rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null || { log "lock busy"; exit 0; }
  else
    log "previous pass still going, skipping"; exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

HOUR=$(date +%H); HOUR=${HOUR#0}
if [ "$DRY_RUN" = "0" ] && [ -z "$ONLY" ] && { [ "$HOUR" -lt "$START_HOUR" ] || [ "$HOUR" -ge "$END_HOUR" ]; }; then
  exit 0
fi

TOKEN=$(jq -r '.botToken // empty' "$CONFIG" 2>/dev/null)
NOTIFY=$(jq -r '.notifyChannel // empty' "$CONFIG" 2>/dev/null)
NOTIFY_USER=$(jq -r '.notifyUserId // empty' "$CONFIG" 2>/dev/null)
BOT=$(jq -r '.botUserId // empty' "$CONFIG" 2>/dev/null)
ORG=$(jq -r '.githubOrg // empty' "$CONFIG" 2>/dev/null)
OWNER=$(jq -r '.ownerName // "the owner"' "$CONFIG" 2>/dev/null)
GHUSER=$(jq -r '.githubUser // empty' "$CONFIG" 2>/dev/null)
# Inject config values into a prompt template's {{OWNER}} / {{GITHUB_USER}} slots.
prompt_file() { OWNER="$OWNER" GHUSER="$GHUSER" perl -pe 's/\{\{OWNER\}\}/$ENV{OWNER}/g; s/\{\{GITHUB_USER\}\}/$ENV{GHUSER}/g' "$1"; }
# Repo menu the classifier picks from, built from config so cloners edit one file.
REPO_LIST=$(jq -r '.repos[] | "- \(.name) — \(.for)"' "$CONFIG" 2>/dev/null)
if [ -z "$TOKEN" ] || [ -z "$BOT" ] || [ "$BOT" = "null" ]; then
  log "missing botToken or botUserId in $CONFIG — cannot run"; exit 1
fi

NOW=$(date +%s)
replies_sent=0
investigated=0

# --- slack helpers -----------------------------------------------------------
# Always write the response to a temp file and jq from the file: message text
# can contain characters that break shell interpolation.
TMP=$(mktemp -d "${TMPDIR:-/tmp}/slackwatch.XXXXXX")
trap 'rm -rf "$TMP"; rmdir "$LOCK" 2>/dev/null || true' EXIT

api_get() {  # api_get method key=val key=val ...  → response written to $TMP/resp
  local method="$1"; shift
  local args=(); local kv
  for kv in "$@"; do args+=(--data-urlencode "$kv"); done
  curl -sS --get "https://slack.com/api/$method" \
    -H "Authorization: Bearer $TOKEN" "${args[@]}" >"$TMP/resp" 2>>"$LOG"
}
api_post() { # api_post method <json-payload>  → response written to $TMP/resp
  curl -sS -X POST "https://slack.com/api/$1" \
    -H "Authorization: Bearer $TOKEN" \
    -H "Content-Type: application/json; charset=utf-8" \
    --data "$2" >"$TMP/resp" 2>>"$LOG"
}

# slack user id → display name, cached so we don't hammer users.info.
[ -f "$USERCACHE" ] || echo '{}' >"$USERCACHE"
name_of() {
  local uid="$1" name
  name=$(jq -r --arg u "$uid" '.[$u] // empty' "$USERCACHE")
  if [ -z "$name" ]; then
    api_get users.info "user=$uid"
    name=$(jq -r '.user.profile.display_name // .user.profile.real_name // .user.name // empty' "$TMP/resp" 2>/dev/null)
    [ -z "$name" ] && name="$uid"
    jq --arg u "$uid" --arg n "$name" '.[$u]=$n' "$USERCACHE" >"$USERCACHE.tmp" && mv "$USERCACHE.tmp" "$USERCACHE"
  fi
  printf '%s' "$name"
}

permalink() { # channel ts → url (best-effort; falls back to empty)
  api_get chat.getPermalink "channel=$1" "message_ts=$2"
  jq -r '.permalink // empty' "$TMP/resp" 2>/dev/null
}

send_reply() { # channel thread_ts text
  [ "$replies_sent" -ge "$MAX_REPLIES" ] && { log "reply cap $MAX_REPLIES hit, holding rest for next pass"; return 1; }
  if [ "$DRY_RUN" = "1" ]; then printf '  WOULD REPLY in %s:\n    %s\n' "$1" "$3"; return 0; fi
  local payload
  payload=$(jq -n --arg ch "$1" --arg ts "$2" --arg t "$3" \
    '{channel:$ch, thread_ts:$ts, text:$t, unfurl_links:false, unfurl_media:false}')
  api_post chat.postMessage "$payload"
  if [ "$(jq -r '.ok // false' "$TMP/resp" 2>/dev/null)" = "true" ]; then
    replies_sent=$(( replies_sent + 1 )); log "replied in $1 (thread $2)"; return 0
  fi
  log "reply failed in $1: $(jq -r '.error // .' "$TMP/resp" 2>/dev/null)"; return 1
}

join_channel() { # channel_id — self-join a public channel so we can read it.
  # Idempotent: joining a channel we're already in returns ok. Public only.
  [ "$DRY_RUN" = "1" ] && { printf '  WOULD JOIN %s\n' "$1"; return 0; }
  api_post conversations.join "$(jq -n --arg ch "$1" '{channel:$ch}')"
  if [ "$(jq -r '.ok // false' "$TMP/resp" 2>/dev/null)" = "true" ]; then
    log "joined $1"; return 0
  fi
  log "join failed for $1: $(jq -r '.error // .' "$TMP/resp" 2>/dev/null)"; return 1
}

notify_owner() { # text
  if [ "$DRY_RUN" = "1" ]; then printf '  WOULD NOTIFY OWNER:\n%s\n' "$1"; return 0; fi
  local payload
  payload=$(jq -n --arg ch "$NOTIFY" --arg t "$1" \
    '{channel:$ch, text:$t, unfurl_links:false, unfurl_media:false}')
  api_post chat.postMessage "$payload"
  [ "$(jq -r '.ok // false' "$TMP/resp" 2>/dev/null)" = "true" ] || \
    log "notify failed: $(jq -r '.error // .' "$TMP/resp" 2>/dev/null)"
}

# --- investigate a flagged issue against the repo ----------------------------
# Detached checkout of the repo's default-branch head, handed to a sub-agent.
# Read-only: no Edit/Write, no MCP, budget-capped. Findings go to the owner only.
investigate() { # repo issue_text reporter link
  local repo="$1" issue="$2" reporter="$3" link="$4"
  local bare="$REPOS/$repo.git" wt="$WORKTREES/watch-$repo-$NOW-$RANDOM"

  if [ ! -d "$bare" ]; then
    gh repo clone "$ORG/$repo" "$bare" -- --bare -q >>"$LOG" 2>&1 || { log "clone $repo failed"; return 1; }
  fi
  git -C "$bare" fetch -q --prune origin "+refs/heads/*:refs/heads/*" >>"$LOG" 2>&1
  local sha; sha=$(git -C "$bare" rev-parse HEAD 2>>"$LOG")   # bare HEAD = default branch
  git -C "$bare" worktree prune >>"$LOG" 2>&1
  if ! git -C "$bare" worktree add --detach -q "$wt" "$sha" >>"$LOG" 2>&1; then
    log "$repo: could not check out $sha for investigation"; return 1
  fi

  local findings
  findings=$(cd "$wt" && claude -p "Someone raised this in Slack. Investigate it against this repo ($ORG/$repo).

--- REPORTED BY: $reporter ---
$issue
--- END ---

Slack link: ${link:-(none)}" \
    --append-system-prompt "$(prompt_file "$DIR/slack-investigate-prompt.md")" \
    --model "$INVESTIGATE_MODEL" \
    --allowed-tools 'Bash,Read,Grep,Glob' \
    --disallowed-tools 'Edit,Write,NotebookEdit' \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --max-budget-usd "$BUDGET_USD" \
    --no-session-persistence 2>>"$LOG")
  local rc=$?

  git -C "$bare" worktree remove --force "$wt" >>"$LOG" 2>&1 || rm -rf "$wt"
  if [ $rc -ne 0 ] || [ -z "$findings" ]; then log "$repo: investigation failed (rc=$rc)"; return 1; fi
  printf '%s' "$findings"
}

# --- process one conversation ------------------------------------------------
# conv id, human label, and is_dm flag. Reads messages newer than the stored
# cursor, classifies them in one batch, then acts. First sighting of a
# conversation just seeds the cursor at "now" so we never reply to backlog.
process_conv() {
  local conv="$1" label="$2" is_dm="$3"
  # Never watch the notify channel — it is the owner's private brief, output only.
  [ "$conv" = "$NOTIFY" ] && return 0

  local seenf="$SEEN/$conv" last
  if [ ! -f "$seenf" ]; then
    [ "$DRY_RUN" = "0" ] && printf '%s' "$NOW" >"$seenf"
    log "$label ($conv): first sighting, seeded cursor at $NOW"
    return 0
  fi
  last=$(cat "$seenf")

  api_get conversations.history "channel=$conv" "oldest=$last" "inclusive=false" "limit=$HIST_LIMIT"
  if [ "$(jq -r '.ok // false' "$TMP/resp" 2>/dev/null)" != "true" ]; then
    local err; err=$(jq -r '.error // .' "$TMP/resp" 2>/dev/null)
    [ "$err" = "not_in_channel" ] && log "$label ($conv): bot not a member — invite the bot to this channel to watch it" \
                                  || log "$label ($conv): history error: $err"
    return 0
  fi

  # Drop the bot's own messages (loop guard) and other bots; keep only human,
  # non-empty messages. Build the batch the classifier sees.
  local batch
  batch=$(jq -c --arg bot "$BOT" \
    '[ .messages[]
       | select(.subtype == null) | select(.bot_id == null)
       | select(.user != $bot) | select((.text // "") != "")
       | {ts, user, text} ]
     | sort_by(.ts)' "$TMP/resp")
  local n; n=$(printf '%s' "$batch" | jq 'length')
  # Advance the cursor to the newest message we pulled regardless of disposition,
  # so an ignored message is not re-examined next pass.
  local newest; newest=$(jq -r '[.messages[].ts] | max // empty' "$TMP/resp")
  [ "$n" = "0" ] && { [ -n "$newest" ] && [ "$DRY_RUN" = "0" ] && printf '%s' "$newest" >"$seenf"; return 0; }

  # Attach display names for context.
  local enriched="[]" row uid nm
  while IFS= read -r row; do
    uid=$(printf '%s' "$row" | jq -r '.user')
    nm=$(name_of "$uid")
    enriched=$(printf '%s' "$enriched" | jq -c --argjson r "$row" --arg nm "$nm" '. + [$r + {name:$nm}]')
  done < <(printf '%s' "$batch" | jq -c '.[]')

  log "$label ($conv): $n new message(s), classifying"
  local ctx="Conversation: $label"
  [ "$is_dm" = "1" ] && ctx="Conversation: direct message (1:1 with the bot)"

  local out
  out=$(cd "$DIR" && claude -p "$ctx
Bot user id: $BOT

Repos available to flag/investigate (use an exact name, or null):
$REPO_LIST

Messages (JSON):
$enriched" \
    --append-system-prompt "$(prompt_file "$DIR/slack-watch-prompt.md")" \
    --model "$CLASSIFY_MODEL" \
    --allowed-tools '' 2>>"$LOG")

  # Pull the JSON array out of the model output defensively.
  local decisions
  decisions=$(printf '%s' "$out" | sed -n '/\[/,/\]/p' | jq -c '.' 2>/dev/null)
  if [ -z "$decisions" ]; then
    log "$label: classifier returned no usable JSON — leaving cursor, will retry"
    printf '%s\n' "$out" >>"$LOG"
    return 0
  fi

  local d disp ts text reporter link findings repo why
  while IFS= read -r d; do
    disp=$(printf '%s' "$d" | jq -r '.disposition')
    ts=$(printf '%s' "$d" | jq -r '.ts')
    text=$(printf '%s' "$enriched" | jq -r --arg ts "$ts" '.[] | select(.ts==$ts) | .text' | head -c 4000)
    reporter=$(printf '%s' "$enriched" | jq -r --arg ts "$ts" '.[] | select(.ts==$ts) | .name')
    case "$disp" in
      reply)
        send_reply "$conv" "$ts" "$(printf '%s' "$d" | jq -r '.reply // empty')" ;;
      flag)
        repo=$(printf '%s' "$d" | jq -r '.repo // empty')
        why=$(printf '%s' "$d" | jq -r '.why // empty')
        link=$(permalink "$conv" "$ts")
        if [ -n "$repo" ] && [ "$repo" != "null" ] && [ "$investigated" -lt "$MAX_INVESTIGATE" ]; then
          investigated=$(( investigated + 1 ))
          log "$label: investigating flagged issue in $repo (by $reporter)"
          findings=$(investigate "$repo" "$text" "$reporter" "$link")
          # The findings are reporter-facing: post them in-thread, and send the
          # same text to the owner as an FYI (not an action — the owner is only
          # pulled in when specifically asked). A failed investigation is not
          # posted publicly; it stays a private note so nothing is lost.
          if [ -n "$findings" ]; then
            send_reply "$conv" "$ts" "$findings"
            notify_owner "🔎 *Issue raised in $label* by *$reporter* (FYI, no action needed)
> $(printf '%s' "$text" | head -c 500)
${link:+<$link|open in Slack> · }repo: \`$repo\`

$findings"
          else
            notify_owner "🔎 *Issue raised in $label* by *$reporter* <@${NOTIFY_USER}>
> $(printf '%s' "$text" | head -c 500)
${link:+<$link|open in Slack> · }repo: \`$repo\`

(investigation failed — see slack-watch.log)"
          fi
        else
          # No repo pinned, or the investigate cap is spent — flag it raw so the owner
          # never silently loses a report.
          notify_owner "⚠️ *Possible issue in $label* by *$reporter* <@${NOTIFY_USER}>
> $(printf '%s' "$text" | head -c 500)
${link:+<$link|open in Slack> · }${why:+_${why}_ · }repo: ${repo:-unclear}${investigated:+ (not investigated: $( [ "$investigated" -ge "$MAX_INVESTIGATE" ] && echo cap reached || echo no repo ))}"
        fi ;;
      *) : ;;  # ignore
    esac
  done < <(printf '%s' "$decisions" | jq -c '.[]')

  [ -n "$newest" ] && [ "$DRY_RUN" = "0" ] && printf '%s' "$newest" >"$seenf"
}

# --- gather conversations and run --------------------------------------------
if [ -n "$ONLY" ]; then
  process_conv "$ONLY" "$ONLY" 0
else
  # Watched channels: the explicit list from config, plus every public channel
  # named feature* the bot can see. Discovery each pass means a new feature-
  # channel is watched with no config edit; we merge on id so an explicitly
  # listed channel keeps its friendly config name.
  WATCH_TSV=$(jq -r '.watch[] | [.id, .name] | @tsv' "$CONFIG")
  # ponytail: one conversations.list page (200) of public, non-archived channels.
  # If the workspace ever exceeds 200 public channels, paginate on next_cursor.
  api_get conversations.list "types=public_channel" "exclude_archived=true" "limit=200"
  if [ "$(jq -r '.ok // false' "$TMP/resp" 2>/dev/null)" = "true" ]; then
    known_ids=$(printf '%s' "$WATCH_TSV" | cut -f1)
    while IFS=$'\t' read -r id name member; do
      [ -z "$id" ] && continue
      # Self-join any feature* channel we're not yet a member of, so we can read
      # its history. Needs channels:join on the bot token. Idempotent + public-only.
      [ "$member" != "true" ] && join_channel "$id"
      printf '%s\n' "$known_ids" | grep -qxF "$id" && continue  # already explicit
      WATCH_TSV="${WATCH_TSV}"$'\n'"${id}"$'\t'"${name}"
    done < <(jq -r '.channels[] | select(.name | startswith("feature")) | [.id, .name, (.is_member|tostring)] | @tsv' "$TMP/resp")
  else
    log "conversations.list(public) error: $(jq -r '.error // .' "$TMP/resp" 2>/dev/null) — using explicit watch list only"
  fi

  while IFS=$'\t' read -r id name; do
    [ -n "$id" ] && process_conv "$id" "$name" 0
  done < <(printf '%s\n' "$WATCH_TSV")

  # DMs: every open IM except Slackbot and the bot's own.
  api_get conversations.list "types=im" "limit=200"
  if [ "$(jq -r '.ok // false' "$TMP/resp" 2>/dev/null)" = "true" ]; then
    while IFS=$'\t' read -r id uid; do
      [ "$uid" = "USLACKBOT" ] && continue
      [ "$uid" = "$BOT" ] && continue
      process_conv "$id" "DM:$(name_of "$uid")" 1
    done < <(jq -r '.channels[] | [.id, .user] | @tsv' "$TMP/resp")
  else
    log "conversations.list(im) error: $(jq -r '.error // .' "$TMP/resp" 2>/dev/null)"
  fi
fi

# Reuse review.sh's cleanup discipline for any worktree admin left behind.
for bare in "$REPOS"/*.git; do [ -d "$bare" ] && git -C "$bare" worktree prune 2>>"$LOG"; done
log "pass done: $replies_sent repl(y/ies), $investigated investigation(s)"

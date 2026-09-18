#!/usr/bin/env bash
# slack-watch.sh — third sibling to run.sh (talks to the owner) and review.sh (talks
# to the org's PRs). This one watches Slack: it reads new messages in the
# watched channels + the bot's DMs and, per message, either replies as the bot,
# or flags a code-related issue to the owner after investigating it against the repo.
#
# Scheduled by launchd agent com.<user>.statusbot.slackwatch (every 5 min, the
# backstop). The com.<user>.statusbot.slacksocket daemon (slack-socket.mjs) also
# invokes this with `--once <channel> --respect-hours` on a live @-mention/DM for
# a faster reply; the two share the mkdir lock, so a skipped --once falls back to
# the 5-min poll.
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
RESPECT_HOURS=0        # --once normally ignores the working-hours window (manual
                       # use); the Socket Mode daemon passes --respect-hours so a
                       # 2am mention doesn't get an instant out-of-hours reply.
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)       DRY_RUN=1; shift ;;
    --once)          ONLY="${2:-}"; shift 2 ;;
    --respect-hours) RESPECT_HOURS=1; shift ;;
    *)               echo "unknown arg: $1" >&2; exit 2 ;;
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

# Working-hours gate. Applies to a normal scheduled pass, and to a daemon-driven
# --once run only when it asked to respect hours. A manual --once (no flag) still
# bypasses it. --dry-run always bypasses.
HOUR=$(date +%H); HOUR=${HOUR#0}
if [ "$DRY_RUN" = "0" ] && { [ -z "$ONLY" ] || [ "$RESPECT_HOURS" = "1" ]; } \
   && { [ "$HOUR" -lt "$START_HOUR" ] || [ "$HOUR" -ge "$END_HOUR" ]; }; then
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

RECONSIDER_LOOKBACK=7200   # seconds of recent channel activity the judge weighs
RECONSIDER_MAX_THREADS=6   # threads to expand replies for — a cost cap

# Before posting, weigh the draft against ALL recent activity in the channel —
# not just the triggering thread. The same issue is often already being worked in
# a sibling thread or the main channel, and a parallel answer there is noise even
# though our own thread looks empty. Gather recent top-level messages and the
# replies of recently-touched threads, hand the lot to a cheap judge, and let it
# decide skip / post / revise-to-add-only-what's-new. Echoes text to post (empty
# = skip). conv, trigger_ts, candidate_text → stdout.
reconsider_reply() {
  local conv="$1" trig="$2" candidate="$3"
  local since=$(( ${trig%.*} - RECONSIDER_LOOKBACK ))

  # Recent channel history (top-level messages within the lookback window).
  api_get conversations.history "channel=$conv" "oldest=$since" "limit=$HIST_LIMIT"
  [ "$(jq -r '.ok // false' "$TMP/resp" 2>/dev/null)" = "true" ] || { printf '%s' "$candidate"; return 0; }
  local hist
  hist=$(jq -c --arg bot "$BOT" \
    '[ .messages[]
       | select(.subtype == null) | select(.bot_id == null) | select(.user != $bot)
       | select((.text // "") != "")
       | {ts, user, text, reply_count: (.reply_count // 0)} ]' "$TMP/resp")

  # Expand replies for the most recent threads that have any (incl. the trigger's
  # own thread). Bounded by RECONSIDER_MAX_THREADS to keep it cheap.
  local context="$hist" root_ts replies
  for root_ts in $(printf '%s' "$hist" | jq -r 'sort_by(.ts) | reverse | .[] | select(.reply_count > 0) | .ts' | head -n "$RECONSIDER_MAX_THREADS"); do
    api_get conversations.replies "channel=$conv" "ts=$root_ts" "limit=50"
    [ "$(jq -r '.ok // false' "$TMP/resp" 2>/dev/null)" = "true" ] || continue
    replies=$(jq -c --arg bot "$BOT" \
      '[ .messages[]
         | select(.subtype == null) | select(.bot_id == null) | select(.user != $bot)
         | select((.text // "") != "")
         | {ts, user, text} ]' "$TMP/resp")
    context=$(printf '%s' "$context" | jq -c --argjson r "$replies" '. + $r')
  done
  # Dedup by ts and order oldest→newest for the judge.
  context=$(printf '%s' "$context" | jq -c 'unique_by(.ts) | sort_by(.ts)')
  # Nothing recent to weigh against — post the draft, no need to spend a model call.
  [ "$(printf '%s' "$context" | jq 'length')" = "0" ] && { printf '%s' "$candidate"; return 0; }

  log "reconsider: judging against $(printf '%s' "$context" | jq length) recent channel message(s)"
  local verdict
  verdict=$(cd "$DIR" && claude -p "We are about to post a reply in a Slack thread. Below is our draft, then ALL
recent human activity in the same channel (top-level messages and thread replies,
oldest first) — including other threads. Decide if posting still helps.

--- OUR DRAFT REPLY ---
$candidate
--- RECENT CHANNEL ACTIVITY (JSON) ---
$context
--- END ---" \
    --append-system-prompt "$(cat "$DIR/slack-reconsider-prompt.md")" \
    --model "$CLASSIFY_MODEL" --allowed-tools '' 2>>"$LOG")
  # Prompt returns JSON: {"action":"skip|post|revise","text":"<only if revise>"}.
  # grep the object out greedily (to the last }) — tolerant of stray prose and of
  # braces inside text. No JSON at all → fall back to posting the draft.
  local obj action text
  obj=$(printf '%s' "$verdict" | grep -o '{.*}')
  action=$(printf '%s' "$obj" | jq -r '.action // "post"' 2>/dev/null); action=${action:-post}
  case "$action" in
    skip)   log "reconsider: skipping — already covered in recent channel activity"; printf '' ;;
    revise) text=$(printf '%s' "$obj" | jq -r '.text // empty' 2>/dev/null)
            [ -n "$text" ] && { log "reconsider: posting revised addition"; printf '%s' "$text"; } || printf '%s' "$candidate" ;;
    *)      printf '%s' "$candidate" ;;
  esac
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

# Team principle: post a short summary as the top-line reply, and the full detail
# as a further reply in the same thread just beneath it. Splits its input on a
# ---DETAIL--- line; if the marker is absent, the whole thing is treated as the
# summary (never dump undelimited detail into the channel top-line). Both posts
# thread under the original message ($2). Counts as one against the reply cap.
post_summary_detail() { # channel thread_ts text
  local summary detail
  if printf '%s' "$3" | grep -q '^---DETAIL---$'; then
    summary=$(printf '%s' "$3" | sed '/^---DETAIL---$/,$d')
    detail=$(printf '%s' "$3" | sed '1,/^---DETAIL---$/d')
  else
    summary="$3"; detail=""
  fi
  # Trim leading/trailing blank lines from each part.
  summary=$(printf '%s' "$summary" | sed '/./,$!d' | sed -e :a -e '/^\n*$/{$d;N;ba}' 2>/dev/null)
  send_reply "$1" "$2" "$summary" || return 1
  # The detail follows in the same thread. It does not consume another cap slot —
  # a summary without its detail is worse than useless, so if the summary posted,
  # the detail always follows (posted directly, bypassing the cap check).
  if [ -n "$(printf '%s' "$detail" | tr -d '[:space:]')" ] && [ "$DRY_RUN" = "0" ]; then
    api_post chat.postMessage "$(jq -n --arg ch "$1" --arg ts "$2" --arg t "$detail" \
      '{channel:$ch, thread_ts:$ts, text:$t, unfurl_links:false, unfurl_media:false}')"
    [ "$(jq -r '.ok // false' "$TMP/resp" 2>/dev/null)" = "true" ] || \
      log "detail post failed in $1: $(jq -r '.error // .' "$TMP/resp" 2>/dev/null)"
  elif [ -n "$detail" ] && [ "$DRY_RUN" = "1" ]; then
    printf '  WOULD POST DETAIL in %s:\n    %s\n' "$1" "$detail"
  fi
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

# Allowlist: only known teammates may direct the bot to act (ask/review). The
# roster is config.users' VALUES (slack user ids); the classifier only proposes a
# privileged disposition — the bash decides here whether the sender is on it, so
# a prompt-injected "ignore the rules" message can't act unless its author is.
is_allowed() { # slack_user_id → 0 if allowlisted
  jq -e --arg u "$1" '.users | to_entries | any(.value == $u)' "$CONFIG" >/dev/null 2>&1
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

# --- investigate a flagged issue / answer a code question against the repo ---
# Detached checkout of the repo's default-branch head, handed to a sub-agent.
# Read-only: no Edit/Write, no MCP, budget-capped. Mode "issue" (default) triages
# a reported problem; mode "question" answers a directed code question — same
# checkout + sandbox, only the framing line differs.
investigate() { # repo issue_text reporter link [mode]
  local repo="$1" issue="$2" reporter="$3" link="$4" mode="${5:-issue}"
  local bare="$REPOS/$repo.git" wt="$WORKTREES/watch-$repo-$NOW-$RANDOM"
  local intro="Someone raised this in Slack. Investigate it against this repo ($ORG/$repo)."
  [ "$mode" = "question" ] && intro="Someone asked this question in Slack. Answer it against this repo ($ORG/$repo), grounded in the code."

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
  findings=$(cd "$wt" && claude -p "$intro

--- FROM: $reporter ---
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

  local d disp ts text reporter suid link findings repo why to_post num answer
  while IFS= read -r d; do
    disp=$(printf '%s' "$d" | jq -r '.disposition')
    ts=$(printf '%s' "$d" | jq -r '.ts')
    text=$(printf '%s' "$enriched" | jq -r --arg ts "$ts" '.[] | select(.ts==$ts) | .text' | head -c 4000)
    reporter=$(printf '%s' "$enriched" | jq -r --arg ts "$ts" '.[] | select(.ts==$ts) | .name')
    suid=$(printf '%s' "$enriched" | jq -r --arg ts "$ts" '.[] | select(.ts==$ts) | .user')
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
            # The thread may have been triaged by a human while we investigated.
            # Decide whether chiming in still helps before posting.
            to_post=$(reconsider_reply "$conv" "$ts" "$findings")
            if [ -n "$to_post" ]; then
              # Unchanged full answer → summary top-line + threaded detail. A
              # revision (no ---DETAIL--- marker) is already short → post as-is.
              if printf '%s' "$to_post" | grep -q '^---DETAIL---$'; then
                post_summary_detail "$conv" "$ts" "$to_post"
              else
                send_reply "$conv" "$ts" "$to_post"
              fi
            fi
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
      ask)
        # A directed code question from an allowlisted teammate → answer it,
        # grounded in the repo, via the same read-only investigate machinery.
        if ! is_allowed "$suid"; then
          log "$label: ignoring 'ask' from non-allowlisted $reporter ($suid)"
        else
          repo=$(printf '%s' "$d" | jq -r '.repo // empty')
          if [ -z "$repo" ] || [ "$repo" = "null" ]; then
            log "$label: 'ask' from $reporter but no repo pinned — skipping"
          elif [ "$investigated" -ge "$MAX_INVESTIGATE" ]; then
            log "$label: 'ask' from $reporter but investigate cap reached — skipping this pass"
          else
            investigated=$(( investigated + 1 ))
            log "$label: answering question from $reporter against $repo"
            link=$(permalink "$conv" "$ts")
            answer=$(investigate "$repo" "$text" "$reporter" "$link" question)
            if [ -n "$answer" ]; then
              to_post=$(reconsider_reply "$conv" "$ts" "$answer")
              if [ -n "$to_post" ]; then
                if printf '%s' "$to_post" | grep -q '^---DETAIL---$'; then
                  post_summary_detail "$conv" "$ts" "$to_post"
                else
                  send_reply "$conv" "$ts" "$to_post"
                fi
              fi
            else
              send_reply "$conv" "$ts" "Sorry — I couldn't work that out from the code just now."
            fi
          fi
        fi ;;
      review)
        # On-demand PR review from an allowlisted teammate → fire review.sh --pr
        # for that PR (backgrounded; it posts to GitHub + the routed channel).
        if ! is_allowed "$suid"; then
          log "$label: ignoring 'review' from non-allowlisted $reporter ($suid)"
        else
          repo=$(printf '%s' "$d" | jq -r '.repo // empty')
          num=$(printf '%s' "$d" | jq -r '.num // empty')
          if ! jq -e --arg r "$repo" '.repos | any(.name == $r)' "$CONFIG" >/dev/null 2>&1; then
            log "$label: 'review' from $reporter — unknown repo '$repo', skipping"
            send_reply "$conv" "$ts" "I don't recognise that repo — I can review PRs in: $(jq -r '[.repos[].name] | join(\", \")' "$CONFIG")."
          elif ! printf '%s' "$num" | grep -qE '^[0-9]+$'; then
            log "$label: 'review' from $reporter — bad PR number '$num', skipping"
            send_reply "$conv" "$ts" "I couldn't find a PR number in that — try e.g. \`review $repo#1234\`."
          else
            log "$label: on-demand review of $repo#$num requested by $reporter"
            send_reply "$conv" "$ts" "On it — reviewing \`$repo#$num\`. The review will post to the PR and the usual channel."
            [ "$DRY_RUN" = "0" ] && ( "$DIR/review.sh" --pr "$repo#$num" >>"$LOG" 2>&1 & )
          fi
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

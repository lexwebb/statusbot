#!/usr/bin/env bash
# review.sh — automated PR review pass. Sibling to run.sh: run.sh talks to the owner,
# review.sh talks to the org's PRs.
#
# Every open PR in the org that isn't the owner's and that no human has looked at gets
# its head SHA checked out into a throwaway worktree and handed to a `claude -p`
# sub-agent, which posts the review to GitHub as the owner (config githubUser). State is keyed by head
# SHA: a PR is reviewed once per push, and re-reviewed when the author pushes
# again. Scheduled by ~/Library/LaunchAgents/me.lex.claude-review.plist.
#
#   review.sh                  # normal pass, posts to GitHub
#   review.sh --dry-run        # review, print, post nothing, record nothing
#   review.sh --pr repo#123    # just this one, ignoring the head-SHA state
#   review.sh --max 2          # cap the number of reviews this pass
set -uo pipefail

DIR="${HOME}/.claude/statusbot"
STATE="$DIR/state"
LOG="$STATE/review.log"
LOCK="$STATE/review-lock.d"
SEEN="$STATE/reviewed"           # <repo>#<num> → head SHA already reviewed
THREADS="$STATE/threads"         # <repo>#<num> → "<channel> <parent ts> <verdict>",
                                 # so a PR's re-reviews stay in one Slack thread
LEDGER="$STATE/reviews.log"      # append-only, epoch-stamped; collect.sh reads
                                 # the slice inside its window, so nothing has to
                                 # be cleared and no post can race a review
REPOS="$DIR/repos"               # bare clone cache, kept between runs
WORKTREES="$DIR/wt"              # throwaway checkouts, deleted after each review
NOTIF_CURSOR="$STATE/last-poll"  # GitHub notifications Last-Modified high-water mark:
                                 # a cheap conditional gate that lets an idle pass
                                 # exit in one (free, 304) API call instead of the
                                 # full search + per-PR fan-out.

SLACK_CONFIG="$DIR/config.json"     # all instance config: token, org, routing, users
ROUTING="$SLACK_CONFIG"             # .channels menu + .users github→slack map live here too
. "$DIR/lib.sh"                     # PATH for schedulers + cross-platform date/stat shims

# Instance-specific values come from config.json so this repo can be cloned.
ORG=$(jq -r '.githubOrg' "$SLACK_CONFIG" 2>/dev/null)
ME=$(jq -r '.githubUser' "$SLACK_CONFIG" 2>/dev/null)
OWNER=$(jq -r '.ownerName // "the owner"' "$SLACK_CONFIG" 2>/dev/null)
MODEL="${REVIEW_MODEL:-opus}"
# Inject config values into a prompt template's {{OWNER}} / {{GITHUB_USER}} slots.
prompt_file() { OWNER="$OWNER" GHUSER="$ME" perl -pe 's/\{\{OWNER\}\}/$ENV{OWNER}/g; s/\{\{GITHUB_USER\}\}/$ENV{GHUSER}/g' "$1"; }

MAX_PARALLEL=3        # sub-agents at once
MAX_PER_RUN=4         # reviews per pass — a cap on cost and on how much of
                      # the owner's name lands on the org's PRs in one go
BUDGET_USD=2          # per sub-agent
STALE_DAYS=14         # same cutoff collect.sh uses: an untouched PR is dead

# Bot authors to skip, built from config.botLogins.
BOTS="^($(jq -r '.botLogins | join("|")' "$SLACK_CONFIG" 2>/dev/null))(\\[bot\\])?\$"

DRY_RUN=0
ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --pr)      ONLY="${2:-}"; shift 2 ;;
    --max)     MAX_PER_RUN="${2:-}"; shift 2 ;;
    *)         echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$STATE" "$SEEN" "$THREADS" "$REPOS" "$WORKTREES"
log() { printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG"; }

# A review pass outlives its 30-minute tick easily; never run two at once.
# ponytail: same mkdir mutex as run.sh — macOS has no flock(1). 90 min is long
# enough for MAX_PER_RUN sub-agents that are actually still working.
if ! mkdir "$LOCK" 2>/dev/null; then
  if [ -n "$(find "$LOCK" -maxdepth 0 -mmin +90 2>/dev/null)" ]; then
    log "clearing stale lock"
    rmdir "$LOCK" 2>/dev/null && mkdir "$LOCK" 2>/dev/null || { log "lock busy, skipping"; exit 0; }
  else
    log "previous pass still going, skipping"
    exit 0
  fi
fi
trap 'rmdir "$LOCK" 2>/dev/null || true' EXIT

NOW=$(date +%s)
STALE_BEFORE=$(( NOW - STALE_DAYS * 86400 ))

# Same working-day window as run.sh. A review lands in someone's notifications
# under the owner's name; 4am is the wrong time for that, and it can wait for 9.
# A manual --pr or --dry-run ignores the window.
HOUR=$(date +%H); HOUR=${HOUR#0}
if [ "$DRY_RUN" = "0" ] && [ -z "$ONLY" ] && { [ "$HOUR" -lt 9 ] || [ "$HOUR" -ge 18 ]; }; then
  exit 0
fi

# --------------------------------------------------- change-signal gate -----
# Before the unconditional search + per-PR fan-out, ask GitHub's notifications
# feed whether ANYTHING has happened since our last pass, using a conditional
# request (If-Modified-Since against a stored Last-Modified). A 304 costs no rate
# quota and means "nothing changed" → skip the whole pass. A 200 means there's
# fresh activity → fall through to the normal full scan (the head-SHA gate still
# prevents re-reviewing unchanged PRs, so we don't try to pin down *which* PR
# changed here — early-exit-when-idle is the whole win, and the safe one).
#
# Only gates scheduled passes: a manual --pr or --dry-run always scans. First run
# (no cursor) also scans, seeding the cursor. Any API error falls through to a
# full scan rather than risking a silently-skipped PR.
# NEW_CURSOR holds the Last-Modified we'll persist — but only in teardown, AFTER
# the scan runs, so a crashed/locked pass never advances past activity it didn't
# review. Empty = don't touch the cursor.
NEW_CURSOR=""
extract_lm() { grep -i '^last-modified:' | head -1 | sed 's/^[Ll]ast-[Mm]odified: *//; s/\r$//'; }
if [ "$DRY_RUN" = "0" ] && [ -z "$ONLY" ]; then
  if [ -f "$NOTIF_CURSOR" ]; then
    since=$(cat "$NOTIF_CURSOR")
    hdrs=$(gh api "/notifications?all=false" -H "If-Modified-Since: $since" --include 2>>"$LOG")
    rc=$?
    if [ $rc -ne 0 ] && printf '%s' "$hdrs" | grep -qi '304 Not Modified'; then
      log "no PR activity since $since — skipping pass (304)"
      exit 0
    fi
    # 200 (or any non-304 outcome, incl. a transient error): scan. On a genuine
    # 200 we captured a fresh Last-Modified to persist post-scan; on an error
    # NEW_CURSOR stays empty so the cursor is left as-is and we retry next pass.
    NEW_CURSOR=$(printf '%s' "$hdrs" | extract_lm)
    log "activity since $since — scanning"
  else
    # First run: seed the cursor from a fresh fetch, then scan normally.
    NEW_CURSOR=$(gh api "/notifications?all=false" --include 2>>"$LOG" | extract_lm)
    log "no notifications cursor yet — seeding, scanning this pass"
  fi
fi

# ------------------------------------------------------------- candidates ----
# One search call for open PRs, plus every PR already in the state dir so a new
# push still gets a fresh pass after our own review made the PR look "engaged".
candidates() {
  if [ -n "$ONLY" ]; then
    printf '%s %s\n' "${ONLY%%#*}" "${ONLY##*#}"
    return
  fi
  ME="$ME" gh search prs --owner "$ORG" --state open --limit 100 \
      --json number,repository,isDraft,author \
      -q '.[] | select(.isDraft | not) | select(.author.login != env.ME)
          | "\(.repository.name) \(.number)"' 2>>"$LOG"
  for f in "$SEEN"/*; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    printf '%s %s\n' "${b%%#*}" "${b##*#}"
  done
}

CANDS=$(candidates | sort -u)
if [ -z "$CANDS" ]; then
  log "no candidate PRs (gh search returned nothing?) — nothing to do"
  exit 0
fi

# ------------------------------------------------------------- slack --------
# Posts one write-up per PR, in the channel the sub-agent chose. Channels are
# routed by the PR's feature workstream rather than its repo, matching the
# convention already running in #backend-pr-reviews / #feature-*.
slack_post() {
  local channel_name="$1" text="$2" slug="$3" verb="$4"
  local token candidates channel resp err payload
  local thread_file="$THREADS/$slug"
  local prev_channel="" prev_ts="" prev_verb=""
  [ -f "$thread_file" ] && read -r prev_channel prev_ts prev_verb <"$thread_file"

  token=$(jq -r '.botToken // empty' "$SLACK_CONFIG" 2>/dev/null)
  if [ -z "$token" ]; then
    log "$slug: no botToken in $SLACK_CONFIG — Slack write-up not posted"
    return 1
  fi

  # Chosen channel, then the default, then the fallback — deduped, in order. A
  # write-up is never lost to a routing mistake or a channel the bot can't reach;
  # the default is private, so until the bot is invited every post lands on the
  # fallback and the log says which channel it was meant for.
  candidates=$(jq -r --arg n "$channel_name" \
    '[.channels[$n].id, .default, .fallback] | map(select(. != null))
     | reduce .[] as $c ([]; if index($c) then . else . + [$c] end) | .[]' "$ROUTING")

  for channel in $candidates; do
    local thread_ts="" broadcast="false"
    # Re-reviews of the same PR hang off the first post rather than repeating it
    # in the channel. A verdict *change* still gets broadcast to the channel —
    # approve → request-changes is the one thing nobody should have to unfold a
    # thread to see.
    if [ -n "$prev_ts" ] && [ "$channel" = "$prev_channel" ]; then
      thread_ts="$prev_ts"
      [ "$verb" != "$prev_verb" ] && broadcast="true"
    fi

    payload=$(jq -n --arg ch "$channel" --arg text "$text" --arg ts "$thread_ts" \
                    --argjson bc "$broadcast" \
      '{channel: $ch, text: $text, unfurl_links: false, unfurl_media: false}
       + (if $ts == "" then {} else {thread_ts: $ts, reply_broadcast: $bc} end)')

    resp=$(curl -sS -X POST https://slack.com/api/chat.postMessage \
      -H "Authorization: Bearer ${token}" \
      -H "Content-Type: application/json; charset=utf-8" \
      --data "$payload" 2>&1)

    if [ "$(printf '%s' "$resp" | jq -r '.ok // false' 2>/dev/null)" = "true" ]; then
      # The anchor is the *first* post in the thread, never a reply's own ts.
      local anchor
      if [ -n "$thread_ts" ]; then
        anchor="$thread_ts"
      else
        anchor=$(printf '%s' "$resp" | jq -r '.ts')
      fi
      printf '%s %s %s\n' "$channel" "$anchor" "$verb" >"$thread_file"
      log "$slug: slack → $channel (chose #$channel_name)${thread_ts:+ [thread reply${broadcast:+, broadcast=$broadcast}]}"
      return 0
    fi

    err=$(printf '%s' "$resp" | jq -r '.error // .' 2>/dev/null)
    if [ "$err" = "not_in_channel" ] || [ "$err" = "channel_not_found" ]; then
      log "$slug: bot cannot post to $channel ($err) — invite the bot; trying next channel"
      continue
    fi
    log "$slug: slack error on $channel: $err"
    return 1
  done

  log "$slug: no channel accepted the write-up — not posted"
  return 1
}

# ------------------------------------------------------- checkout a PR -------
# All git happens here, in the parent, one PR at a time: two sub-agents reviewing
# two PRs of the same repo would otherwise fetch into the same clone at once and
# one would lose a ref lock. Prints the worktree path on success.
prepare_worktree() {
  local repo="$1" num="$2" sha="$3"
  local bare="$REPOS/$repo.git"
  local wt="$WORKTREES/$repo-$num"

  if [ ! -d "$bare" ]; then
    log "$repo#$num: cloning $repo"
    gh repo clone "$ORG/$repo" "$bare" -- --bare -q >>"$LOG" 2>&1 || {
      log "$repo#$num: clone failed"; return 1; }
  fi
  # The head may live on a fork, so take it from refs/pull as well as heads.
  git -C "$bare" fetch -q --prune origin \
      "+refs/heads/*:refs/heads/*" "+refs/pull/$num/head:refs/pull/$num/head" >>"$LOG" 2>&1

  rm -rf "$wt"
  git -C "$bare" worktree prune >>"$LOG" 2>&1
  if ! git -C "$bare" worktree add --detach -q "$wt" "$sha" >>"$LOG" 2>&1; then
    log "$repo#$num: could not check out $sha"
    return 1
  fi
  printf '%s' "$wt"
}

# ----------------------------------------------------------- review a PR -----
# Runs backgrounded, one per PR. Touches no git — just the sub-agent, which
# reads the checkout it was handed and posts its own review.
review_pr() {
  local repo="$1" num="$2" sha="$3" base="$4" url="$5" title="$6" wt="$7"
  local slug="$repo#$num"

  local posting="Post the review to GitHub."
  [ "$DRY_RUN" = "1" ] && posting="DRY RUN: do NOT post anything to GitHub. Print the review you would have posted."

  # The script owns the github→slack identity map, so the agent never guesses a
  # mention: it gets either a real mention or the bare login to print as text.
  local mention
  mention=$(jq -r --arg a "$author" '.users[$a] // empty' "$ROUTING")
  if [ -n "$mention" ]; then mention="<@$mention>"; else mention="$author (no Slack mention known)"; fi
  local menu
  menu=$(jq -r '.channels | to_entries[] | "  \(.key) — \(.value.for)"' "$ROUTING")

  local out
  out=$(cd "$wt" && claude -p "Review pull request $ORG/$repo#$num.

  title:     $title
  url:       $url
  head SHA:  $sha
  base:      $base
  author:    $author
  mention:   $mention

Your working directory is a checkout of this PR's head commit. The base branch is
available locally as \`$base\`. $posting

Open the Slack write-up with the author's mention exactly as given above.

Slack channels for the write-up, routed by the PR's subject, not its repo.
Copy one name verbatim — an invented name falls back to the default:
$menu" \
    --append-system-prompt "$(prompt_file "$DIR/review-prompt.md")" \
    --model "$MODEL" \
    --allowed-tools 'Bash,Read,Grep,Glob' \
    --disallowed-tools 'Edit,Write,NotebookEdit' \
    --strict-mcp-config --mcp-config '{"mcpServers":{}}' \
    --max-budget-usd "$BUDGET_USD" \
    --no-session-persistence \
    2>>"$LOG")
  local rc=$?

  rm -rf "$wt"   # the parent prunes the worktree admin entries after `wait`

  if [ $rc -ne 0 ] || [ -z "$out" ]; then
    log "$slug: sub-agent failed (rc=$rc)"
    return 1
  fi

  # The sub-agent's last line is its verdict; anything above it is its own notes.
  local verdict
  verdict=$(printf '%s' "$out" | grep -E '^VERDICT\|' | tail -1)
  if [ -z "$verdict" ]; then
    log "$slug: no VERDICT line — treating as failed, will retry next pass"
    printf '%s\n' "$out" >>"$LOG"
    return 1
  fi

  # Everything between the markers is the Slack post; the channel is the line
  # above it. A missing or unknown channel routes to the default, never nowhere.
  local slack_channel slack_text
  slack_channel=$(printf '%s' "$out" | grep -E '^SLACK_CHANNEL:' | tail -1 | sed 's/^SLACK_CHANNEL: *//; s/^#//')
  slack_text=$(printf '%s' "$out" | awk '/^SLACK>>>$/{f=1;next} /^<<<SLACK$/{f=0} f')
  if [ -z "$slack_channel" ] || [ "$(jq -r --arg n "$slack_channel" '.channels[$n].id // empty' "$ROUTING")" = "" ]; then
    log "$slug: unknown slack channel \"$slack_channel\" — using default"
    slack_channel=$(jq -r --arg d "$(jq -r '.default' "$ROUTING")" '.channels | to_entries[] | select(.value.id == $d) | .key' "$ROUTING")
  fi

  local verb clause
  verb=$(printf '%s' "$verdict" | cut -d'|' -f2)
  clause=$(printf '%s' "$verdict" | cut -d'|' -f3-)

  if [ "$DRY_RUN" = "1" ]; then
    printf '=== %s\n%s\n\n' "$slug" "$out"
    return 0
  fi

  # A skipped review posted nothing to GitHub, so it has nothing to announce.
  if [ -n "$slack_text" ] && ! printf '%s' "$verdict" | grep -q '^VERDICT|skipped'; then
    slack_post "$slack_channel" "$slack_text" "$slug" "$verb"
  else
    log "$slug: no slack write-up posted (skipped verdict or empty SLACK block)"
  fi

  # Only a posted review advances the SHA. A failed one is retried next pass.
  printf '%s' "$sha" >"$SEEN/$slug"
  printf '%s\t• <%s|%s> — *%s* — %s\n' "$(date +%s)" "$url" "$slug" "$verb" "$clause" >>"$LEDGER"
  log "$slug: $verdict"
}

# ------------------------------------------------------------------ pass -----
reviewed=0
while read -r repo num; do
  [ -n "$repo" ] || continue
  [ "$reviewed" -ge "$MAX_PER_RUN" ] && { log "hit MAX_PER_RUN=$MAX_PER_RUN, rest wait for the next pass"; break; }

  slug="$repo#$num"
  meta=$(gh pr view -R "$ORG/$repo" "$num" \
           --json state,isDraft,author,headRefOid,baseRefName,url,title,updatedAt,reviews,comments 2>>"$LOG")
  if [ -z "$meta" ]; then
    log "$slug: could not read PR, skipping"
    continue
  fi

  state=$(printf '%s' "$meta" | jq -r '.state')
  if [ "$state" != "OPEN" ]; then
    rm -f "$SEEN/$slug" "$THREADS/$slug"   # merged or closed — stop tracking it
    continue
  fi

  author=$(printf '%s' "$meta" | jq -r '.author.login')
  draft=$(printf '%s' "$meta" | jq -r '.isDraft')
  sha=$(printf '%s' "$meta" | jq -r '.headRefOid')
  base=$(printf '%s' "$meta" | jq -r '.baseRefName')
  url=$(printf '%s' "$meta" | jq -r '.url')
  title=$(printf '%s' "$meta" | jq -r '.title')
  updated=$(printf '%s' "$meta" | jq -r '.updatedAt | fromdate')

  # Never review the owner's own work, a draft, or another bot's PR.
  [ "$author" = "$ME" ] && continue
  [ "$draft" = "true" ] && continue
  printf '%s' "$author" | grep -qiE "$BOTS" && continue

  if [ -n "$ONLY" ]; then
    :                            # --pr means review it regardless of state
  else
    [ "$updated" -lt "$STALE_BEFORE" ] && continue
    [ "$sha" = "$(cat "$SEEN/$slug" 2>/dev/null)" ] && continue

    # A PR a human has already engaged with is theirs, not ours — unless we
    # reviewed it before, in which case the human in the thread may be us.
    if [ ! -f "$SEEN/$slug" ]; then
      humans=$(printf '%s' "$meta" | jq -r --arg bots "$BOTS" --arg author "$author" \
        '[ (.reviews[]?.author.login), (.comments[]?.author.login) ]
         | map(select(. != null)) | map(select(test($bots; "i") | not))
         | map(select(. != $author)) | unique | length')
      [ "${humans:-0}" -gt 0 ] && continue
    fi
  fi

  # ponytail: bounded fan-out with a poll — bash has no `wait -n` worth using
  # across versions, and the pass is minutes long so a 5s granularity is free.
  while [ "$(jobs -rp | wc -l)" -ge "$MAX_PARALLEL" ]; do sleep 5; done
  wt=$(prepare_worktree "$repo" "$num" "$sha") || continue
  log "$slug: reviewing $sha ($title)"
  review_pr "$repo" "$num" "$sha" "$base" "$url" "$title" "$wt" &
  reviewed=$(( reviewed + 1 ))
done <<EOF
$CANDS
EOF

wait
# Advance the notifications cursor only now the scan has completed, so a pass that
# died mid-flight doesn't 304 past activity it never reviewed.
[ -n "$NEW_CURSOR" ] && printf '%s' "$NEW_CURSOR" >"$NOTIF_CURSOR"
for bare in "$REPOS"/*.git; do
  [ -d "$bare" ] && git -C "$bare" worktree prune 2>>"$LOG"
done
log "pass done, $reviewed review(s) started"

#!/usr/bin/env bash
# collect.sh — gather local + GitHub state for the Slack status bot.
# Prints a plain-text bundle on stdout; run.sh pipes it into `claude -p`.
# Usage: collect.sh [since-epoch] [normal|morning]
set -uo pipefail

SINCE="${1:-$(( $(date +%s) - 1800 ))}"
MODE="${2:-normal}"
NOW=$(date +%s)
CONFIG="${HOME}/.claude/statusbot/config.json"   # single source of instance config
ORG=$(jq -r '.githubOrg' "$CONFIG" 2>/dev/null)
ME=$(jq -r '.githubUser' "$CONFIG" 2>/dev/null)

# A PR with no activity for this long is dead, not queued — drop it.
# Measured on updatedAt, so an old PR that got a push yesterday still shows.
# Switch to _created in the sort/filter below to measure from opened date instead.
STALE_DAYS=14
STALE_BEFORE=$(( $(date +%s) - STALE_DAYS * 86400 ))

# Bot authors to skip, from config.botLogins (edit config, not this script).
BOTS="^($(jq -r '.botLogins | join("|")' "$CONFIG" 2>/dev/null))(\\[bot\\])?\$"

SRC_DIR="${HOME}/src"
PROJECTS_DIR="${HOME}/.claude/projects"

iso() { date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ; }
mins_ago() { echo $(( (NOW - $1) / 60 )); }

echo "=== WINDOW ==="
echo "now:   $(iso "$NOW")"
echo "since: $(iso "$SINCE") ($(mins_ago "$SINCE") min ago)"

# ---------------------------------------------------------------- local git ---
echo
echo "=== LOCAL GIT ACTIVITY ==="
for d in "$SRC_DIR"/*/; do
  [ -d "${d}.git" ] || continue
  repo=$(basename "$d")
  commits=$(git -C "$d" log --since="@$SINCE" --oneline --no-merges 2>/dev/null | head -20)
  dirty=$(git -C "$d" status --porcelain 2>/dev/null | wc -l | tr -d ' ')
  branch=$(git -C "$d" rev-parse --abbrev-ref HEAD 2>/dev/null)
  upstream=$(git -C "$d" rev-parse --abbrev-ref '@{upstream}' 2>/dev/null)
  ahead=0
  [ -n "$upstream" ] && ahead=$(git -C "$d" rev-list --count "${upstream}..HEAD" 2>/dev/null || echo 0)

  # Only report repos that are actually in play.
  [ -z "$commits" ] && [ "$dirty" = "0" ] && [ "$ahead" = "0" ] && continue

  echo "--- $repo [$branch]"
  [ "$dirty" != "0" ] && echo "  uncommitted: $dirty file(s)"
  [ "$ahead" != "0" ] && echo "  unpushed: $ahead commit(s) vs $upstream"
  [ -n "$commits" ] && printf '  new commit: %s\n' "$commits"
done

# ------------------------------------------------------- claude transcripts ---
echo
echo "=== CLAUDE SESSIONS TOUCHED IN WINDOW ==="
for f in "$PROJECTS_DIR"/*/*.jsonl; do
  [ -f "$f" ] || continue
  mtime=$(stat -f %m "$f" 2>/dev/null) || continue
  [ "$mtime" -lt "$SINCE" ] && continue

  project=$(basename "$(dirname "$f")")
  # Last real user prompt: string content, or text blocks; drop tool results and
  # system-reminder/command wrappers.
  last_prompt=$(jq -r 'select(.isSidechain!=true) | select(.type=="user") | .message.content as $c |
      (if ($c|type)=="string" then $c
       else ([$c[]? | select(.type=="text") | .text] | join("\n")) end)
      | select(. != null and . != "")' "$f" 2>/dev/null \
    | grep -v '^<' | grep -v '^$' | tail -1 | cut -c1-400)

  last_reply=$(jq -r 'select(.isSidechain!=true) | select(.type=="assistant") |
      (.message.content[]? | select(.type=="text") | .text)' "$f" 2>/dev/null \
    | tail -c 900)

  # Nothing readable (tool-only or empty transcript) — skip rather than emit noise.
  [ -z "$last_prompt" ] && [ -z "$last_reply" ] && continue

  echo "--- $project :: $(basename "$f" .jsonl)"
  echo "  idle: $(mins_ago "$mtime") min (last activity $(iso "$mtime"))"
  echo "  last prompt from the owner: ${last_prompt:-<none>}"
  echo "  tail of last reply: ${last_reply:-<none>}"
done

# --------------------------------------------------------------------- PRs ----
echo
echo "=== OPEN PRS ($ORG) ==="
# One search call finds the repos with open PRs; the search API rate-limits hard,
# so retry once before giving up.
gh_repos() {
  gh search prs --owner "$ORG" --state open --limit 100 --json repository \
    -q '.[].repository.name' 2>"$ERRFILE" | sort -u
}
ERRFILE=$(mktemp)
trap 'rm -f "$ERRFILE"' EXIT
repos=$(gh_repos)
if [ -z "$repos" ]; then
  sleep 5
  repos=$(gh_repos)
fi

if [ -z "$repos" ]; then
  echo "COLLECTION FAILURE: gh search returned no repos: $(tr '\n' ' ' <"$ERRFILE" | cut -c1-300)"
else
  # Pull every repo's open PRs into one stream, then classify, filter and sort in
  # a single pass so ordering is global rather than per-repo.
  ALLPRS=$(mktemp)
  trap 'rm -f "$ERRFILE" "$ALLPRS"' EXIT
  # GitHub throws intermittent 503s on this query. A silent miss would quietly
  # shrink the review queue and read as "nothing to review", so: retry, then fall
  # back to the last good copy rather than dropping the repo.
  CACHE="$(dirname "$0")/state/prcache"
  mkdir -p "$CACHE"
  for repo in $repos; do
    json=""
    for attempt in 1 2 3 4; do
      json=$(gh pr list -R "$ORG/$repo" --state open --limit 100 \
        --json number,title,url,author,isDraft,createdAt,updatedAt,reviewDecision,reviews,comments,reviewRequests \
        2>"$ERRFILE")
      [ -n "$json" ] && break
      sleep $(( attempt * attempt + 1 ))
    done

    if [ -n "$json" ]; then
      printf '%s' "$json" >"$CACHE/$repo.json"
    elif [ -s "$CACHE/$repo.json" ]; then
      age=$(( (NOW - $(stat -f %m "$CACHE/$repo.json")) / 60 ))
      echo "NOTE: GitHub 503 on $repo — using cached PR data from ${age} min ago, may be out of date."
      json=$(cat "$CACHE/$repo.json")
    else
      echo "COLLECTION FAILURE: could not list PRs for $repo and no cache: $(tr '\n' ' ' <"$ERRFILE" | cut -c1-160)"
      continue
    fi
    printf '%s' "$json" | jq -c --arg repo "$repo" 'map(. + {_repo: $repo}) | .[]' >>"$ALLPRS"
  done

  # Reviews and PR-level comments are unioned: a human who only left an issue
  # comment has still engaged, and an APPROVED review still carries a body.
  # ponytail: inline review comments are omitted — GitHub attaches them to a
  # review, so they already show up in .reviews.
  # Sorted newest-opened first; stale PRs are dropped here, not left to the model.
  jq -rs --arg bots "$BOTS" --arg me "$ME" --argjson now "$NOW" \
         --argjson cutoff "$STALE_BEFORE" --argjson days "$STALE_DAYS" '
    def isbot: test($bots; "i");
    def logins: [ (.reviews[]?.author.login), (.comments[]?.author.login) ]
                | map(select(. != null));
    def days_since($t): (($now - $t) / 86400 | floor);

    [ .[] as $pr
      | ($pr | logins) as $all
      | ($all | map(select(isbot | not)) | map(select(. != $pr.author.login)) | unique) as $humans
      | $pr + {
          _humans: $humans,
          _bots:   ($all | map(select(isbot)) | unique),
          _others: ($humans | map(select(. != $me))),
          _created: ($pr.createdAt | fromdate),
          _updated: ($pr.updatedAt | fromdate)
        } ]
    | map(. + {
        _needs:  ((.isDraft | not) and (.author.login != $me) and ((._humans | length) == 0)),
        _mine:   ((.author.login == $me) and ((._others | length) > 0)),
        _stale:  (._updated < $cutoff)
      })
    | map(select(._needs or ._mine)) as $actionable
    | ($actionable | map(select(._stale | not)) | sort_by(-._created)) as $show
    | ($actionable | map(select(._stale)) | length) as $nstale
    | (map(select((._needs or ._mine) | not)) | length) as $nengaged
    | ($show | map(
        "\(._repo)#\(.number) | \(.title)
  author: \(.author.login) | opened: \(.createdAt) (\(days_since(._created))d ago) | last activity: \(days_since(._updated))d ago
  reviewDecision: \(.reviewDecision // "none") | review requested from: \((.reviewRequests // [] | map(.login // .name) | join(",")) | if . == "" then "nobody" else . end)
  humans engaged: \(if (._humans | length) == 0 then "NONE" else (._humans | join(", ")) end) | bots: \(if (._bots | length) == 0 then "none" else (._bots | join(", ")) end)
  \(if ._needs then "NEEDS_HUMAN_REVIEW: YES" else "MINE_WITH_FEEDBACK: YES (\(._others | join(", ")))" end)
  \(.url)"))
      + [ "(listed \($show | length) actionable PR(s), newest opened first — this is the COMPLETE queue, show every one.
\($nstale) further PR(s) need review but are stale — no activity in over \($days) days — and were dropped.
\($nengaged) other open PR(s) already have human engagement, are drafts, or are the owner'"'"'s own with no feedback yet.)" ]
    | .[]
  ' "$ALLPRS"
fi

# ---------------------------------------------------------- auto reviews ----
# What review.sh posted to GitHub as the owner inside this window. Epoch-stamped so
# the slice is a plain filter — nothing to drain, no race with a concurrent pass.
echo
echo "=== AUTOMATED PR REVIEWS POSTED AS LEX IN WINDOW ==="
LEDGER="$(dirname "$0")/state/reviews.log"
if [ -s "$LEDGER" ]; then
  posted=$(awk -F'\t' -v s="$SINCE" '$1 >= s { print $2 }' "$LEDGER")
  echo "${posted:-(none)}"
else
  echo "(none)"
fi

# ------------------------------------------------------------ linear (am) ----
# Only the morning brief needs these; the half-hourly digest doesn't.
if [ "$MODE" = "morning" ]; then
  echo
  echo "=== LEX'S OPEN LINEAR TICKETS (assigned, not done) ==="
  tickets=$(linear issue query --all-teams --assignee lex \
              --state started --state unstarted --state triage \
              --sort priority --limit 50 --json 2>&1 | sed 's/\x1b\[[0-9;]*m//g')
  # The CLI returns a bare array for some flag combinations and {nodes:[…]} for
  # others, so normalise before reading.
  if printf '%s' "$tickets" | jq -e '(if type=="array" then . else (.nodes // .issues) end) | type=="array"' >/dev/null 2>&1; then
    printf '%s' "$tickets" | jq -r '(if type=="array" then . else (.nodes // .issues) end) | .[]
      | "\(.identifier) [\(.state.name)] \(.title)
  project: \(.project.name // "none") | updated: \(.updatedAt // "?")"'
  else
    echo "COLLECTION FAILURE: linear CLI returned no issue array: $(printf '%s' "$tickets" | tr '\n' ' ' | cut -c1-200)"
  fi
fi

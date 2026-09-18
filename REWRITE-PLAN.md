# statusbot → TypeScript rewrite plan

## Context

The bot (`~/.claude/statusbot`, git remote `lexwebb/statusbot`) is ~1,725 lines of
bash across 5 scripts + a 100-line Node daemon + 272 lines of prompts. It works and
was hardened this session (review change-gate, whole-channel reconsider, summary/
detail Slack posts, allowlist authz, on-demand ask/review, 24/7 reviews, 5-min
cadence). The goal is to **rewrite it in TypeScript** for portability and
maintainability — the shell leans on `jq` (127×), `perl`, `sed`/`awk`/`stat`/`find`
with macOS-vs-Linux shims, and 3 scheduler backends, all of which are portability
tax that TS + a couple libs erase.

**Decisions locked in:**
- Full rewrite in one go (not incremental).
- Node 22 + `tsx` (matches the existing `slack-socket.mjs`; no new runtime).
- OS schedulers stay (launchd/systemd/cron) firing short-lived TS processes; the
  installer keeps generating them. The socket daemon stays a long-running process.

**The risk of "one go":** silently dropping a hard-won fix. Mitigation = the
**Behavior-parity checklist** (bottom); the shell scripts are NOT deleted until every
item is verified against the TS version.

## Target layout

```
~/.claude/statusbot/
  package.json            # deps + bin scripts; type: module
  tsconfig.json
  src/
    config.ts             # load+validate config.json (typed); replaces every jq config read
    lib/
      slack.ts            # postMessage, thread reply, getPermalink, users.info cache, conversations.*
      github.ts           # gh/git wrappers (spawn), notifications conditional-GET, PR list/view, review post
      claude.ts           # run `claude -p` (spawn): model, allowed-tools, budget, append-system-prompt, cwd
      state.ts            # state/ dir: cursors, seen SHAs, reviewed/, threads/, prcache/, ledger, logs, locks
      time.ts             # iso_utc, epoch-days-ago-midnight, mins-ago (native Date; kills the date/stat shims)
      prompts.ts          # load *-prompt.md + {{OWNER}}/{{GITHUB_USER}} substitution (kills perl)
      log.ts              # per-job append logger, [ISO] line format
    jobs/
      digest.ts           # run.sh + collect.sh merged (collect is a pure function returning the bundle string)
      review.ts           # review.sh: notifications gate → discover → filter → review → record → slack summary
      slack-watch.ts      # slack-watch.sh: poll channels/DMs, classify, reply/flag/ask/review, reconsider
      socket.ts           # slack-socket.mjs port (long-running daemon; @slack/socket-mode)
    bin/
      digest.ts review.ts slack-watch.ts socket.ts   # thin entrypoints (argv parse → job)
    install.ts            # replaces install.sh: validate, write scheduler units, npm install
  prompts/                # UNCHANGED — the *-prompt.md files move here verbatim
```

Each job keeps its own CLI flags (`--dry-run`, `--pr`, `--once`, `--respect-hours`,
`--max`, `--since`, `--morning`, `--reply-thread`) — parsed in `bin/*`.

## Dependency elimination (the portability win)

| Shell dependency | Uses | TS replacement |
| --- | --- | --- |
| `jq` | 127× JSON | native `JSON.parse`/typed objects |
| `perl` | template subst | `String.replaceAll` in `prompts.ts` |
| `date`/`stat` GNU/BSD shims | timestamps, mtimes | `Date`, `fs.statSync().mtimeMs` in `time.ts` |
| `sed`/`awk`/`find`/`tr`/`cut` | parsing, ledger filter, stale-lock | native string/array ops, `fs` |
| `curl` | Slack API | `fetch` (Node 22 built-in) |
| mkdir-mutex lock | one-at-a-time | keep the same mkdir-mutex idea via `fs.mkdirSync` (portable, no `flock`) |
| **still shelled out** | `gh`, `git`, `claude` | `child_process` wrappers in `github.ts`/`claude.ts` — TS doesn't remove these, just types their in/out |

Libs to add: `@slack/socket-mode` (already present). Everything else is Node built-ins
(`fetch`, `fs`, `child_process`, `Date`). `tsx` as a devDep-run to execute `.ts` directly.

## Job specs to preserve (from the behavioral maps)

**digest (`run.sh`+`collect.sh`):** working-hours 9–18 gate; morning-vs-normal mode
(driven by `last-morning != today`, Monday reaches back to Friday); SINCE resolution
(`--since` > morning > `last-run` > now-1800); collect bundle = the exact `=== SECTION ===`
plain-text format (WINDOW, LOCAL GIT ACTIVITY, CLAUDE SESSIONS, OPEN PRS with the
needs/mine/stale classifier, AUTOMATED PR REVIEWS ledger slice, morning-only LINEAR);
`claude -p` sonnet no-tools; NO_UPDATE handling (normal=skip, morning=fixed fallback);
one top-level Slack post to `notifyChannel` (🌅 morning / 🕐 status header, no thread);
**state-advance ordering is load-bearing** — `last-run`/`last-morning` after a good
claude run, `last-digest.md` only after Slack ok; dry-run advances nothing; one-time
`claude-failed` error post via `last-error`. `prcache/` write-through on gh 503.

**review (`review.sh`):** 24/7 (no hours gate); `/notifications` conditional-GET gate
(If-Modified-Since `state/last-poll`, 304=skip, cursor advances only after a completed
scan); discover = `gh search prs` ∪ `state/reviewed/*`; per-PR filter (open/not-draft/
not-me/not-bot/stale-14d/head-SHA-unchanged/first-touch-human-engaged); MAX_PARALLEL=3,
MAX_PER_RUN=4, BUDGET_USD=2; sandboxed `claude -p` opus (Bash/Read/Grep/Glob only);
verdict summary line to routed channel (`emoji *<url|slug>* — verb: clause`); re-review
threading + verdict-change broadcast via `state/threads/`; `--pr` bypasses gate+hours;
`--reply-thread ch:ts` posts verdict back to the requesting thread; SHA recorded only
after a posted review; ledger append.

**slack-watch (`slack-watch.sh`):** 9–18 gate (bypassed by manual `--once`, honored with
`--respect-hours`); discover watched channels + auto-discover/join `feature*` public
channels (`conversations.join`); per-conversation cursor (seed at now on first sighting,
no backlog); classify batch via `claude -p` sonnet no-tools → dispositions
ignore/reply/flag/ask/review; `flag`→investigate (read-only checkout, budget) →
summary+`---DETAIL---` thread + owner FYI; `ask`→investigate question-mode
(allowlisted); `review`→`review.sh --pr … --reply-thread` (allowlisted, repo-in-config,
numeric); **allowlist = config.users values, enforced in code not the model**;
whole-channel reconsider before posting (2h lookback, 6 threads, skip/post/revise);
caps MAX_REPLIES=5/MAX_INVESTIGATE=2.

**socket (`slack-socket.mjs`):** near-verbatim TS port; app_mention + message.im → debounced
`slack-watch --once <ch> --respect-hours`; per-channel debounce+in-flight guard; KeepAlive.

**install (`install.sh`):** validate config + bot token (`auth.test`) + app token
(`apps.connections.open` when set) + watch-channel membership; write `path.env`;
generate launchd/systemd/cron units (review+slackwatch+digest as INTERVAL/timed,
socket as DAEMON/KeepAlive, gated on appToken); `npm install`; `--no-schedule`,
`--uninstall`.

## Config & state compatibility

- **`config.json` is unchanged** — same keys, same file (gitignored, symlinked from
  `~/.config/claude-slack/`). `config.ts` reads+validates it once, typed.
- **`state/` is unchanged and reused as-is** — the TS version reads the *existing*
  cursors/SHAs/threads/ledger so there's no reset on cutover (a review already done
  stays done, the digest's `last-run` continues). This is critical: it makes cutover
  seamless and reversible.

## Cutover

1. Build the TS suite alongside the shell (nothing deleted).
2. Run each TS job with `--dry-run` and diff its behavior/output against the shell
   version (same cursors, same Slack payloads, same collect bundle).
3. Point the schedulers at the TS entrypoints (regenerate units via `install.ts`).
4. Watch one full cycle live (a real digest, a real review, a real mention).
5. Only then `git rm` the `.sh` files + `lib.sh`. Keep them in git history for rollback.

## Behavior-parity checklist (must all pass before deleting shell)

- [ ] Review: 304 skip on unchanged; scan on change; cursor advances only post-scan.
- [ ] Review: head-SHA dedup (no re-review at same SHA); `--pr` force works; verdict summary format identical; `--reply-thread` posts to requesting thread.
- [ ] Review: runs after 18:00 (24/7).
- [ ] slack-watch: `feature*` auto-discover + self-join; no-backlog cursor seeding.
- [ ] slack-watch: reply/flag/ask/review dispositions; allowlist denies non-config.users; summary+detail thread; whole-channel reconsider skips when already handled.
- [ ] digest: morning vs normal; NO_UPDATE handling; collect bundle sections byte-comparable; state-advance ordering; one-time error post.
- [ ] socket: connects; mention → debounced --once; KeepAlive restart.
- [ ] install: generates all units incl. DAEMON; validates both tokens; --uninstall removes all; runs on a clean checkout (portability proof — ideally test on Linux).
- [ ] No `jq`/`perl`/`sed`/`awk`/`stat`/`date`-shim left in the running path (grep proves it).
- [ ] `config.json` + existing `state/` consumed unchanged (no reset on cutover).

## Rough effort

Sizeable — ~1,700 lines reimagined as typed modules, plus parity verification. The
lib layer (slack/github/claude/state/time/prompts) is the foundation and unblocks all
jobs; build it first, then the 4 jobs, then install.ts, then cutover. The collect
classifier and the review notifications-gate are the two fiddliest pieces to match
exactly.

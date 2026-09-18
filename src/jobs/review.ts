// Review job — port of review.sh. Finds open org PRs that aren't the owner's and
// that no human has engaged, reviews each with a sandboxed claude sub-agent that
// posts to GitHub, then posts a one-line verdict to the routed Slack channel.
// Runs 24/7. A /notifications conditional-GET gate skips idle passes cheaply.
import { rmSync, existsSync, readdirSync } from "node:fs";
import { join } from "node:path";
import { DIR, loadConfig, isBotLogin, type Config } from "../lib/config.ts";
import { makeLogger } from "../lib/log.ts";
import { acquireLock, readFile, writeFile, readKey, writeKey, removeKey, appendLedger, listKeys } from "../lib/state.ts";
import { nowEpoch, httpDate } from "../lib/time.ts";
import { gh, git, checkNotifications, ensureBareClone, headSha, addWorktree, removeWorktree } from "../lib/github.ts";
import { runClaude } from "../lib/claude.ts";
import { Slack } from "../lib/slack.ts";
import { loadPrompt } from "../lib/prompts.ts";

const log = makeLogger("review.log");
const REPOS = join(DIR, "repos");
const WORKTREES = join(DIR, "wt");
const STALE_DAYS = 14;
const MAX_PARALLEL = 3;
const DEFAULT_MAX_PER_RUN = 4;
const BUDGET_USD = 2;
const MODEL = process.env.REVIEW_MODEL ?? "opus";

export interface ReviewArgs {
  dryRun: boolean;
  only?: string; // "repo#num"
  maxPerRun: number;
  replyThread?: string; // "channel:ts"
}

interface PrMeta {
  state: string;
  isDraft: boolean;
  author: { login: string };
  headRefOid: string;
  baseRefName: string;
  url: string;
  title: string;
  updatedAt: string;
  reviews?: { author?: { login?: string } }[];
  comments?: { author?: { login?: string } }[];
}

export async function runReview(args: ReviewArgs): Promise<void> {
  const cfg = loadConfig();
  const lock = acquireLock("review-lock.d", 90);
  if (!lock) {
    log("previous pass still going, skipping");
    return;
  }
  try {
    const now = nowEpoch();
    const staleBefore = now - STALE_DAYS * 86400;

    // --- change-signal gate (scheduled passes only; --pr/--dry-run always scan) ---
    let newCursor = "";
    if (!args.dryRun && !args.only) {
      const cursor = readFile("last-poll");
      const check = checkNotifications(cursor);
      if (cursor && check.status === 304) {
        log(`no PR activity since ${cursor} — skipping pass (304)`);
        return;
      }
      newCursor = check.lastModified ?? "";
      log(cursor ? `activity since ${cursor} — scanning` : "no notifications cursor yet — seeding, scanning this pass");
    }

    const slack = new Slack(cfg.botToken);

    // --- discover candidates: gh search ∪ state/reviewed/* ---
    const cands = discover(cfg, args.only);
    if (cands.length === 0) {
      log("no candidate PRs — nothing to do");
      return;
    }

    // --- per-candidate filter + bounded-parallel review ---
    let reviewed = 0;
    const inflight: Promise<void>[] = [];
    for (const { repo, num } of cands) {
      if (reviewed >= args.maxPerRun) {
        log(`hit MAX_PER_RUN=${args.maxPerRun}, rest wait for the next pass`);
        break;
      }
      const slug = `${repo}#${num}`;
      const meta = readPr(cfg, repo, num);
      if (!meta) {
        log(`${slug}: could not read PR, skipping`);
        continue;
      }
      if (meta.state !== "OPEN") {
        removeKey("reviewed", slug);
        removeKey("threads", slug);
        continue;
      }
      const author = meta.author.login;
      if (author === cfg.githubUser) continue;
      if (meta.isDraft) continue;
      if (isBotLogin(author)) continue;

      const sha = meta.headRefOid;
      if (!args.only) {
        const updated = Math.floor(new Date(meta.updatedAt).getTime() / 1000);
        if (updated < staleBefore) continue;
        if (sha === readKey("reviewed", slug)) continue;
        // First-touch gate: a PR a human already engaged is theirs — unless we've
        // reviewed it before (then the human in the thread may be us).
        if (readKey("reviewed", slug) === undefined) {
          const logins = [
            ...(meta.reviews ?? []).map((r) => r.author?.login),
            ...(meta.comments ?? []).map((c) => c.author?.login),
          ].filter((l): l is string => !!l);
          const humans = [...new Set(logins.filter((l) => !isBotLogin(l) && l !== author))];
          if (humans.length > 0) continue;
        }
      }

      // throttle to MAX_PARALLEL
      while (inflight.filter((p) => (p as Promise<void> & { done?: boolean }).done !== true).length >= MAX_PARALLEL) {
        await Promise.race(inflight);
      }
      const wt = prepareWorktree(cfg, repo, num, sha);
      if (!wt) continue;
      log(`${slug}: reviewing ${sha} (${meta.title})`);
      const p = reviewPr(cfg, slack, { repo, num, sha, base: meta.baseRefName, url: meta.url, title: meta.title, author, wt }, args)
        .then(() => {
          (p as Promise<void> & { done?: boolean }).done = true;
        });
      inflight.push(p);
      reviewed++;
    }
    await Promise.all(inflight);

    // advance cursor only after a completed scan
    if (newCursor && !args.dryRun) writeFile("last-poll", newCursor);
    for (const bare of listBareClones()) git(["-C", bare, "worktree", "prune"]);
    log(`pass done, ${reviewed} review(s) started`);
  } finally {
    lock.release();
  }
}

function discover(cfg: Config, only?: string): { repo: string; num: string }[] {
  if (only) {
    const [repo, num] = only.split("#");
    return repo && num ? [{ repo, num }] : [];
  }
  const set = new Set<string>();
  const r = gh([
    "search", "prs", "--owner", cfg.githubOrg, "--state", "open", "--limit", "100",
    "--json", "number,repository,isDraft,author",
    "-q", `.[] | select(.isDraft | not) | select(.author.login != "${cfg.githubUser}") | "\\(.repository.name) \\(.number)"`,
  ]);
  if (r.ok) {
    for (const line of r.stdout.split("\n").filter(Boolean)) {
      const [repo, num] = line.split(" ");
      if (repo && num) set.add(`${repo} ${num}`);
    }
  }
  // union with already-tracked PRs (state/reviewed/<repo>#<num>)
  for (const key of listReviewedKeys()) {
    const hash = key.lastIndexOf("#");
    if (hash > 0) set.add(`${key.slice(0, hash)} ${key.slice(hash + 1)}`);
  }
  return [...set].sort().map((s) => {
    const [repo, num] = s.split(" ");
    return { repo: repo!, num: num! };
  });
}

function listReviewedKeys(): string[] {
  // state/reviewed/ filenames are "<repo>#<num>"
  return listKeys("reviewed");
}

function readPr(cfg: Config, repo: string, num: string): PrMeta | undefined {
  const r = gh([
    "pr", "view", "-R", `${cfg.githubOrg}/${repo}`, num,
    "--json", "state,isDraft,author,headRefOid,baseRefName,url,title,updatedAt,reviews,comments",
  ]);
  if (!r.ok || !r.stdout) return undefined;
  try {
    return JSON.parse(r.stdout) as PrMeta;
  } catch {
    return undefined;
  }
}

function prepareWorktree(cfg: Config, repo: string, num: string, sha: string): string | undefined {
  const bare = join(REPOS, `${repo}.git`);
  if (!ensureBareClone(cfg.githubOrg, repo, bare)) {
    log(`${repo}#${num}: clone failed`);
    return undefined;
  }
  git(["-C", bare, "fetch", "-q", "--prune", "origin", "+refs/heads/*:refs/heads/*", `+refs/pull/${num}/head:refs/pull/${num}/head`]);
  const wt = join(WORKTREES, `${repo}-${num}`);
  rmSync(wt, { recursive: true, force: true });
  if (!addWorktree(bare, wt, sha)) {
    log(`${repo}#${num}: could not check out ${sha}`);
    return undefined;
  }
  return wt;
}

interface ReviewCtx {
  repo: string; num: string; sha: string; base: string; url: string; title: string; author: string; wt: string;
}

async function reviewPr(cfg: Config, slack: Slack, ctx: ReviewCtx, args: ReviewArgs): Promise<void> {
  const slug = `${ctx.repo}#${ctx.num}`;
  const posting = args.dryRun
    ? "DRY RUN: do NOT post anything to GitHub. Print the review you would have posted."
    : "Post the review to GitHub.";
  const mentionId = cfg.users[ctx.author];
  const mention = mentionId ? `<@${mentionId}>` : `${ctx.author} (no Slack mention known)`;
  const menu = Object.entries(cfg.channels).map(([k, v]) => `  ${k} — ${v.for}`).join("\n");

  const res = await runClaude({
    prompt: `Review pull request ${cfg.githubOrg}/${ctx.repo}#${ctx.num}.

  title:     ${ctx.title}
  url:       ${ctx.url}
  head SHA:  ${ctx.sha}
  base:      ${ctx.base}
  author:    ${ctx.author}
  mention:   ${mention}

Your working directory is a checkout of this PR's head commit. The base branch is
available locally as \`${ctx.base}\`. ${posting}

Open the Slack write-up with the author's mention exactly as given above.

Slack channels for the write-up, routed by the PR's subject, not its repo.
Copy one name verbatim — an invented name falls back to the default:
${menu}`,
    systemPrompt: loadPrompt("review-prompt.md"),
    model: MODEL,
    allowedTools: "Bash,Read,Grep,Glob",
    disallowedTools: "Edit,Write,NotebookEdit",
    strictEmptyMcp: true,
    budgetUsd: BUDGET_USD,
    cwd: ctx.wt,
    logAppend: log,
  });

  rmSync(ctx.wt, { recursive: true, force: true });

  if (!res.ok) {
    log(`${slug}: sub-agent failed (rc=${res.code})`);
    return;
  }
  const out = res.output;
  const verdictLine = out.split("\n").filter((l) => l.startsWith("VERDICT|")).pop();
  if (!verdictLine) {
    log(`${slug}: no VERDICT line — treating as failed, will retry next pass`);
    return;
  }

  // channel routing from the SLACK_CHANNEL: line (the write-up text itself is ignored)
  let channelName = out.split("\n").filter((l) => l.startsWith("SLACK_CHANNEL:")).pop()
    ?.replace(/^SLACK_CHANNEL:\s*/, "").replace(/^#/, "") ?? "";
  if (!channelName || !cfg.channels[channelName]) {
    // fall back to the default channel's name
    channelName = Object.entries(cfg.channels).find(([, v]) => v.id === cfg.default)?.[0] ?? channelName;
    log(`${slug}: unknown slack channel — using default`);
  }

  const parts = verdictLine.split("|");
  const verb = parts[1] ?? "";
  const clause = parts.slice(2).join("|");

  if (args.dryRun) {
    process.stdout.write(`=== ${slug}\n${out}\n\n`);
    return;
  }

  const emoji = verb === "approved" ? ":white_check_mark:" : verb === "request-changes" ? ":warning:" : ":speech_balloon:";
  const summary = `${emoji} *<${ctx.url}|${slug}>* — ${verb}${clause ? `: ${clause}` : ""}`;
  const skipped = verb === "skipped";
  if (!skipped) await slackPost(cfg, slack, channelName, summary, slug, verb);
  else log(`${slug}: skipped verdict — nothing to announce`);

  // requesting-thread reply (on-demand review from Slack)
  if (args.replyThread) {
    const [rtCh, rtTs] = args.replyThread.split(":");
    const rtext = skipped ? `${emoji} *<${ctx.url}|${slug}>* — skipped: ${clause || "no review posted"}` : summary;
    if (rtCh && rtTs) {
      const r = await slack.postMessage(rtCh, rtext, { threadTs: rtTs });
      log(r.ok ? `${slug}: posted verdict back to requesting thread ${rtCh}/${rtTs}` : `${slug}: failed to post to requesting thread ${rtCh}/${rtTs}`);
    }
  }

  // record only after a posted review
  writeKey("reviewed", slug, ctx.sha);
  appendLedger(`${nowEpoch()}\t• <${ctx.url}|${slug}> — *${verb}* — ${clause}`);
  log(`${slug}: ${verdictLine}`);
}

// Slack routing: chosen channel → default → fallback, deduped; threads re-reviews,
// broadcasts a verdict change. Records the thread anchor in state/threads/<slug>.
async function slackPost(cfg: Config, slack: Slack, channelName: string, text: string, slug: string, verb: string): Promise<void> {
  const prev = readKey("threads", slug);
  let prevChannel = "", prevTs = "", prevVerb = "";
  if (prev) {
    const p = prev.split(" ");
    prevChannel = p[0] ?? "";
    prevTs = p[1] ?? "";
    prevVerb = p[2] ?? "";
  }
  const ids = [cfg.channels[channelName]?.id, cfg.default, cfg.fallback].filter((x): x is string => !!x);
  const candidates = [...new Set(ids)];
  for (const channel of candidates) {
    const threadTs = prevTs && channel === prevChannel ? prevTs : undefined;
    const broadcast = threadTs ? verb !== prevVerb : false;
    const r = await slack.postMessage(channel, text, { threadTs, broadcast });
    if (r.ok) {
      const anchor = threadTs ?? r.ts ?? "";
      writeKey("threads", slug, `${channel} ${anchor} ${verb}`);
      log(`${slug}: slack → ${channel} (chose #${channelName})${threadTs ? ` [thread reply${broadcast ? ", broadcast" : ""}]` : ""}`);
      return;
    }
    if (r.error === "not_in_channel" || r.error === "channel_not_found") {
      log(`${slug}: bot cannot post to ${channel} (${r.error}) — trying next channel`);
      continue;
    }
    log(`${slug}: slack error on ${channel}: ${r.error}`);
    return;
  }
  log(`${slug}: no channel accepted the write-up — not posted`);
}

function listBareClones(): string[] {
  if (!existsSync(REPOS)) return [];
  return readdirSync(REPOS).filter((d) => d.endsWith(".git")).map((d) => join(REPOS, d));
}

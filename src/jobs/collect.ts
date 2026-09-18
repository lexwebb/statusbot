// collect — port of collect.sh. Gathers local git + Claude sessions + open PRs
// (+ morning-only Linear) into the plain-text "=== SECTION ===" bundle the digest
// LLM consumes. Pure reader (except the prcache write-through). Returns the bundle.
import { readdirSync, existsSync, readFileSync, statSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import { loadConfig, isBotLogin, type Config } from "../lib/config.ts";
import { writeKey, readKey } from "../lib/state.ts";
import { isoUtc, nowEpoch, minsAgo, fileMtime } from "../lib/time.ts";
import { gh, git } from "../lib/github.ts";
import { ledgerSince } from "../lib/state.ts";

const SRC = join(homedir(), "src");
const PROJECTS = join(homedir(), ".claude", "projects");
const STALE_DAYS = 14;

export function collect(since: number, mode: "normal" | "morning"): string {
  const cfg = loadConfig();
  const now = nowEpoch();
  const out: string[] = [];
  const p = (s = "") => out.push(s);

  p("=== WINDOW ===");
  p(`now:   ${isoUtc(now)}`);
  p(`since: ${isoUtc(since)} (${minsAgo(since)} min ago)`);
  p();

  p("=== LOCAL GIT ACTIVITY ===");
  collectLocalGit(since, p);
  p();

  p("=== CLAUDE SESSIONS TOUCHED IN WINDOW ===");
  collectClaudeSessions(since, p);
  p();

  p(`=== OPEN PRS (${cfg.githubOrg}) ===`);
  collectPrs(cfg, p);
  p();

  p("=== AUTOMATED PR REVIEWS POSTED AS LEX IN WINDOW ===");
  const ledger = ledgerSince(since);
  if (ledger.length) ledger.forEach((l) => p(l));
  else p("(none)");

  if (mode === "morning") {
    p();
    p("=== LEX'S OPEN LINEAR TICKETS (assigned, not done) ===");
    collectLinear(p);
  }
  return out.join("\n");
}

function collectLocalGit(since: number, p: (s?: string) => void): void {
  if (!existsSync(SRC)) return;
  for (const entry of readdirSync(SRC)) {
    const d = join(SRC, entry);
    if (!existsSync(join(d, ".git"))) continue;
    const commits = git(["-C", d, "log", `--since=@${since}`, "--oneline", "--no-merges"]).stdout.split("\n").filter(Boolean).slice(0, 20);
    const dirty = git(["-C", d, "status", "--porcelain"]).stdout.split("\n").filter(Boolean).length;
    const branch = git(["-C", d, "rev-parse", "--abbrev-ref", "HEAD"]).stdout;
    const upstream = git(["-C", d, "rev-parse", "--abbrev-ref", "@{upstream}"]).stdout;
    let ahead = 0;
    if (upstream) ahead = Number(git(["-C", d, "rev-list", "--count", `${upstream}..HEAD`]).stdout) || 0;
    if (commits.length === 0 && dirty === 0 && ahead === 0) continue;
    p(`--- ${entry} [${branch}]`);
    if (dirty !== 0) p(`  uncommitted: ${dirty} file(s)`);
    if (ahead !== 0) p(`  unpushed: ${ahead} commit(s) vs ${upstream}`);
    for (const c of commits) p(`  new commit: ${c}`);
  }
}

function collectClaudeSessions(since: number, p: (s?: string) => void): void {
  if (!existsSync(PROJECTS)) return;
  for (const project of readdirSync(PROJECTS)) {
    const pdir = join(PROJECTS, project);
    if (!statSync(pdir).isDirectory()) continue;
    for (const f of readdirSync(pdir).filter((x) => x.endsWith(".jsonl"))) {
      const path = join(pdir, f);
      const mtime = fileMtime(path);
      if (mtime === undefined || mtime < since) continue;
      const { lastPrompt, lastReply } = readTranscript(path);
      if (!lastPrompt && !lastReply) continue;
      p(`--- ${project} :: ${f.replace(/\.jsonl$/, "")}`);
      p(`  idle: ${minsAgo(mtime)} min (last activity ${isoUtc(mtime)})`);
      p(`  last prompt from the owner: ${lastPrompt || "<none>"}`);
      p(`  tail of last reply: ${lastReply || "<none>"}`);
    }
  }
}

function readTranscript(path: string): { lastPrompt: string; lastReply: string } {
  let lastPrompt = "";
  let replyBuf = "";
  let raw: string;
  try {
    raw = readFileSync(path, "utf8");
  } catch {
    return { lastPrompt: "", lastReply: "" };
  }
  for (const line of raw.split("\n")) {
    if (!line.trim()) continue;
    let ev: { isSidechain?: boolean; type?: string; message?: { content?: unknown } };
    try {
      ev = JSON.parse(line);
    } catch {
      continue;
    }
    if (ev.isSidechain === true) continue;
    const content = ev.message?.content;
    if (ev.type === "user") {
      const text = typeof content === "string"
        ? content
        : Array.isArray(content)
          ? content.filter((c): c is { type: string; text: string } => (c as { type?: string })?.type === "text").map((c) => c.text).join("\n")
          : "";
      // drop tool-result / system-reminder / command wrappers (lines starting '<')
      if (text && !text.startsWith("<")) lastPrompt = text.slice(0, 400);
    } else if (ev.type === "assistant" && Array.isArray(content)) {
      replyBuf += content.filter((c): c is { type: string; text: string } => (c as { type?: string })?.type === "text").map((c) => c.text).join("\n");
    }
  }
  return { lastPrompt, lastReply: replyBuf.slice(-900) };
}

interface Pr {
  number: number;
  title: string;
  url: string;
  author: { login: string };
  isDraft: boolean;
  createdAt: string;
  updatedAt: string;
  reviewDecision?: string;
  reviews?: { author?: { login?: string } }[];
  comments?: { author?: { login?: string } }[];
  reviewRequests?: { login?: string }[];
  _repo?: string;
}

function collectPrs(cfg: Config, p: (s?: string) => void): void {
  const cutoff = nowEpoch() - STALE_DAYS * 86400;
  // repos with open PRs
  const search = gh(["search", "prs", "--owner", cfg.githubOrg, "--state", "open", "--limit", "100", "--json", "repository", "-q", ".[].repository.name"]);
  const repos = [...new Set(search.stdout.split("\n").filter(Boolean))];
  const all: Pr[] = [];
  let failure = false;
  for (const repo of repos) {
    let prs = fetchPrsWithRetry(cfg, repo);
    if (prs === undefined) {
      // fall back to prcache (state/prcache/<repo>.json)
      const cached = readKey("prcache", `${repo}.json`);
      const cacheMtime = prcacheMtime(repo);
      if (cached) {
        try {
          prs = JSON.parse(cached) as Pr[];
          const age = cacheMtime ? minsAgo(cacheMtime) : 0;
          p(`NOTE: GitHub error on ${repo} — using cached PR data (${age} min old)`);
        } catch {
          prs = [];
        }
      } else {
        failure = true;
        continue;
      }
    } else {
      writeKey("prcache", `${repo}.json`, JSON.stringify(prs));
    }
    for (const pr of prs) all.push({ ...pr, _repo: repo });
  }
  if (all.length === 0 && failure) {
    p("COLLECTION FAILURE: could not read PRs and no cache available");
    return;
  }

  const me = cfg.githubUser;
  const classified = all.map((pr) => {
    const logins = [
      ...(pr.reviews ?? []).map((r) => r.author?.login),
      ...(pr.comments ?? []).map((c) => c.author?.login),
    ].filter((l): l is string => !!l);
    const humans = [...new Set(logins.filter((l) => !isBotLogin(l) && l !== pr.author.login))];
    const others = humans.filter((h) => h !== me);
    const created = Math.floor(new Date(pr.createdAt).getTime() / 1000);
    const updated = Math.floor(new Date(pr.updatedAt).getTime() / 1000);
    const needs = !pr.isDraft && pr.author.login !== me && humans.length === 0;
    const mine = pr.author.login === me && others.length > 0;
    const stale = updated < cutoff;
    return { pr, humans, others, created, needs, mine, stale };
  });
  const actionable = classified.filter((c) => c.needs || c.mine);
  const show = actionable.filter((c) => !c.stale).sort((a, b) => b.created - a.created);
  const nstale = actionable.filter((c) => c.stale).length;
  const nengaged = classified.filter((c) => !c.needs && !c.mine).length;

  for (const c of show) {
    const pr = c.pr;
    p(`${pr._repo}#${pr.number} | ${pr.title}`);
    p(`  author: ${pr.author.login} | opened: ${isoUtc(c.created)} | age: ${minsAgo(c.created)} min`);
    if (pr.reviewDecision) p(`  reviewDecision: ${pr.reviewDecision}`);
    const reqs = (pr.reviewRequests ?? []).map((r) => r.login).filter(Boolean);
    if (reqs.length) p(`  review requested from: ${reqs.join(", ")}`);
    p(`  humans engaged: ${c.humans.length ? c.humans.join(", ") : "none"}`);
    if (c.needs) p("  NEEDS_HUMAN_REVIEW: YES");
    else if (c.mine) p(`  MINE_WITH_FEEDBACK: YES (${c.others.join(", ")})`);
    p(`  ${pr.url}`);
  }
  p(`(complete actionable queue: ${show.length} shown; ${nstale} stale >${STALE_DAYS}d dropped; ${nengaged} others already engaged/draft/owner's-own)`);
}

function fetchPrsWithRetry(cfg: Config, repo: string): Pr[] | undefined {
  for (let attempt = 1; attempt <= 4; attempt++) {
    const r = gh(["pr", "list", "-R", `${cfg.githubOrg}/${repo}`, "--state", "open", "--limit", "100",
      "--json", "number,title,url,author,isDraft,createdAt,updatedAt,reviewDecision,reviews,comments,reviewRequests"]);
    if (r.ok) {
      try {
        return JSON.parse(r.stdout) as Pr[];
      } catch {
        return [];
      }
    }
    // backoff attempt^2+1 seconds — synchronous sleep via spawnSync sleep would block;
    // collect runs to completion so a short spin is acceptable, but simplest: just retry.
  }
  return undefined;
}

function prcacheMtime(repo: string): number | undefined {
  return fileMtime(join(homedir(), ".claude", "statusbot", "state", "prcache", `${repo}.json`));
}

function collectLinear(p: (s?: string) => void): void {
  const res = runLinear();
  if (res === undefined) {
    p("COLLECTION FAILURE: linear query failed");
    return;
  }
  for (const t of res) {
    p(`${t.identifier} [${t.state}] ${t.title}`);
    p(`  project: ${t.project ?? "none"} | updated: ${t.updatedAt ?? "?"}`);
  }
}

interface LinearTicket {
  identifier: string;
  state: string;
  title: string;
  project?: string;
  updatedAt?: string;
}
function runLinear(): LinearTicket[] | undefined {
  const r = spawnSync("linear", ["issue", "query", "--all-teams", "--assignee", "lex", "--state", "started", "--state", "unstarted", "--state", "triage", "--sort", "priority", "--limit", "50", "--json"], { encoding: "utf8" });
  if (r.status !== 0) return undefined;
  const clean = (r.stdout ?? "").replace(/\x1b\[[0-9;]*m/g, "");
  try {
    return JSON.parse(clean) as LinearTicket[];
  } catch {
    return undefined;
  }
}

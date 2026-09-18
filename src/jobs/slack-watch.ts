// slack-watch job — port of slack-watch.sh. Polls watched + auto-discovered
// feature* channels and the bot's DMs; classifies new messages; replies, flags a
// code issue (investigate + brief the owner), answers an allowlisted code question
// (ask), or runs an on-demand PR review (review). Posts short summaries with detail
// in-thread, and reconsiders against whole-channel activity before posting.
import { rmSync, existsSync } from "node:fs";
import { join } from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { DIR, loadConfig, isAllowed, type Config } from "../lib/config.ts";
import { makeLogger } from "../lib/log.ts";
import { acquireLock, readFile, writeFile } from "../lib/state.ts";
import { nowEpoch, localHour } from "../lib/time.ts";
import { ensureBareClone, headSha, addWorktree, removeWorktree } from "../lib/github.ts";
import { runClaude } from "../lib/claude.ts";
import { Slack, type SlackResponse } from "../lib/slack.ts";
import { loadPrompt } from "../lib/prompts.ts";

const log = makeLogger("slack-watch.log");
const REPOS = join(DIR, "repos");
const WORKTREES = join(DIR, "wt");
const here = dirname(import.meta);
const reviewEntry = join(here, "..", "bin", "review.ts");

const START_HOUR = 9;
const END_HOUR = 18;
const MAX_REPLIES = 5;
const MAX_INVESTIGATE = 2;
const HIST_LIMIT = 50;
const CLASSIFY_MODEL = process.env.SLACK_WATCH_MODEL ?? "sonnet";
const INVESTIGATE_MODEL = process.env.SLACK_INVESTIGATE_MODEL ?? "opus";
const BUDGET_USD = 2;
const RECONSIDER_LOOKBACK = 7200;
const RECONSIDER_MAX_THREADS = 6;

function dirname(meta: ImportMeta): string {
  return join(fileURLToPath(meta.url), "..");
}

export interface WatchArgs {
  dryRun: boolean;
  only?: string; // channel id
  respectHours: boolean;
}

interface Decision {
  ts: string;
  disposition: "ignore" | "reply" | "flag" | "ask" | "review";
  reply?: string;
  repo?: string | null;
  why?: string;
  num?: number;
}

let repliesSent = 0;
let investigated = 0;

export async function runSlackWatch(args: WatchArgs): Promise<void> {
  const cfg = loadConfig();
  const lock = acquireLock("slack-watch-lock.d", 30);
  if (!lock) {
    log("previous pass still going, skipping");
    return;
  }
  try {
    // Working-hours gate: scheduled pass, or a daemon --once that asked to respect it.
    const gated = !args.dryRun && (!args.only || args.respectHours);
    if (gated && (localHour() < START_HOUR || localHour() >= END_HOUR)) return;

    const slack = new Slack(cfg.botToken);
    const conversations = await gatherConversations(cfg, slack, args);
    for (const conv of conversations) {
      await processConversation(cfg, slack, args, conv.id, conv.label, conv.isDm);
    }
    log(`pass done: ${repliesSent} repl(y/ies), ${investigated} investigation(s)`);
  } finally {
    lock.release();
  }
}

interface Conv {
  id: string;
  label: string;
  isDm: boolean;
}

async function gatherConversations(cfg: Config, slack: Slack, args: WatchArgs): Promise<Conv[]> {
  if (args.only) return [{ id: args.only, label: args.only, isDm: false }];

  const out: Conv[] = cfg.watch.map((w) => ({ id: w.id, label: w.name, isDm: false }));
  const knownIds = new Set(out.map((c) => c.id));

  // auto-discover + self-join feature* public channels
  const list = await slack.listConversations("public_channel", 200);
  if (list.ok) {
    for (const ch of (list.channels as { id: string; name: string; is_member?: boolean }[]) ?? []) {
      if (!ch.name?.startsWith("feature")) continue;
      if (!ch.is_member) {
        const j = await slack.join(ch.id);
        if (j.ok) log(`joined ${ch.id}`);
        else log(`join failed for ${ch.id}: ${j.error}`);
      }
      if (!knownIds.has(ch.id)) {
        out.push({ id: ch.id, label: ch.name, isDm: false });
        knownIds.add(ch.id);
      }
    }
  } else {
    log(`conversations.list(public) error: ${list.error} — using explicit watch list only`);
  }

  // DMs
  const ims = await slack.listConversations("im", 200);
  if (ims.ok) {
    for (const im of (ims.channels as { id: string; user: string }[]) ?? []) {
      if (im.user === "USLACKBOT" || im.user === cfg.botUserId) continue;
      out.push({ id: im.id, label: `DM:${await slack.userName(im.user)}`, isDm: true });
    }
  } else {
    log(`conversations.list(im) error: ${ims.error}`);
  }
  return out;
}

async function processConversation(cfg: Config, slack: Slack, args: WatchArgs, conv: string, label: string, isDm: boolean): Promise<void> {
  if (conv === cfg.notifyChannel) return; // never act in the owner's private brief channel

  const seenName = `slack-seen/${conv}`;
  const seen = readFile(seenName);
  if (seen === undefined) {
    if (!args.dryRun) writeFile(seenName, String(nowEpoch()));
    log(`${label} (${conv}): first sighting, seeded cursor at ${nowEpoch()}`);
    return;
  }

  const hist = await slack.history(conv, seen, HIST_LIMIT);
  if (!hist.ok) {
    if (hist.error === "not_in_channel") log(`${label} (${conv}): bot not a member — invite the bot to watch it`);
    else log(`${label} (${conv}): history error: ${hist.error}`);
    return;
  }
  const messages = (hist.messages as SlackMsg[]) ?? [];
  const batch = messages
    .filter((m) => m.subtype == null && m.bot_id == null && m.user !== cfg.botUserId && (m.text ?? "") !== "")
    .map((m) => ({ ts: m.ts, user: m.user, text: m.text }))
    .sort((a, b) => a.ts.localeCompare(b.ts));

  const newest = messages.map((m) => m.ts).sort().at(-1);
  if (batch.length === 0) {
    if (newest && !args.dryRun) writeFile(seenName, newest);
    return;
  }

  // enrich with display names
  const enriched: EnrichedMsg[] = [];
  for (const m of batch) {
    enriched.push({ ...m, name: await slack.userName(m.user) });
  }

  log(`${label} (${conv}): ${enriched.length} new message(s), classifying`);
  const ctx = isDm ? "Conversation: direct message (1:1 with the bot)" : `Conversation: ${label}`;
  const repoList = cfg.repos.map((r) => `- ${r.name} — ${r.for}`).join("\n");
  const res = await runClaude({
    prompt: `${ctx}\nBot user id: ${cfg.botUserId}\n\nRepos available to flag/investigate (use an exact name, or null):\n${repoList}\n\nMessages (JSON):\n${JSON.stringify(enriched)}`,
    systemPrompt: loadPrompt("slack-watch-prompt.md"),
    model: CLASSIFY_MODEL,
    allowedTools: "",
    logAppend: log,
  });
  const decisions = parseJsonArray<Decision>(res.output);
  if (!decisions) {
    log(`${label}: classifier returned no usable JSON — leaving cursor, will retry`);
    return;
  }

  for (const d of decisions) {
    const msg = enriched.find((e) => e.ts === d.ts);
    if (!msg) continue;
    await act(cfg, slack, args, conv, label, d, msg);
  }
  if (newest && !args.dryRun) writeFile(seenName, newest);
}

async function act(cfg: Config, slack: Slack, args: WatchArgs, conv: string, label: string, d: Decision, msg: EnrichedMsg): Promise<void> {
  const text = (msg.text ?? "").slice(0, 4000);
  const reporter = msg.name;
  const suid = msg.user;
  switch (d.disposition) {
    case "reply":
      if (d.reply) await sendReply(slack, args, conv, msg.ts, d.reply);
      return;
    case "flag":
      await handleFlag(cfg, slack, args, conv, label, msg.ts, text, reporter, d);
      return;
    case "ask": {
      if (!isAllowed(suid)) {
        log(`${label}: ignoring 'ask' from non-allowlisted ${reporter} (${suid})`);
        return;
      }
      const repo = d.repo || "";
      if (!repo) {
        log(`${label}: 'ask' from ${reporter} but no repo pinned — skipping`);
        return;
      }
      if (investigated >= MAX_INVESTIGATE) {
        log(`${label}: 'ask' from ${reporter} but investigate cap reached — skipping`);
        return;
      }
      investigated++;
      log(`${label}: answering question from ${reporter} against ${repo}`);
      const link = await slack.getPermalink(conv, msg.ts);
      const answer = await investigate(cfg, repo, text, reporter, link, "question");
      if (answer) {
        const toPost = await reconsider(cfg, slack, conv, msg.ts, answer);
        if (toPost) await postAnswer(slack, args, conv, msg.ts, toPost);
      } else {
        await sendReply(slack, args, conv, msg.ts, "Sorry — I couldn't work that out from the code just now.");
      }
      return;
    }
    case "review": {
      if (!isAllowed(suid)) {
        log(`${label}: ignoring 'review' from non-allowlisted ${reporter} (${suid})`);
        return;
      }
      const repo = d.repo || "";
      const num = d.num;
      if (!cfg.repos.some((r) => r.name === repo)) {
        log(`${label}: 'review' from ${reporter} — unknown repo '${repo}', skipping`);
        await sendReply(slack, args, conv, msg.ts, `I don't recognise that repo — I can review PRs in: ${cfg.repos.map((r) => r.name).join(", ")}.`);
        return;
      }
      if (!num || !Number.isInteger(num)) {
        log(`${label}: 'review' from ${reporter} — bad PR number '${num}', skipping`);
        await sendReply(slack, args, conv, msg.ts, `I couldn't find a PR number in that — try e.g. \`review ${repo}#1234\`.`);
        return;
      }
      log(`${label}: on-demand review of ${repo}#${num} requested by ${reporter}`);
      await sendReply(slack, args, conv, msg.ts, `On it — reviewing \`${repo}#${num}\`. I'll post the verdict back here, and the full review to the PR.`);
      if (!args.dryRun) {
        const child = spawn("tsx", [reviewEntry, "--pr", `${repo}#${num}`, "--reply-thread", `${conv}:${msg.ts}`], {
          cwd: join(here, "..", ".."), stdio: "ignore", detached: true,
        });
        child.unref();
      }
      return;
    }
    default:
      return; // ignore
  }
}

async function handleFlag(cfg: Config, slack: Slack, args: WatchArgs, conv: string, label: string, ts: string, text: string, reporter: string, d: Decision): Promise<void> {
  const repo = d.repo || "";
  const why = d.why || "";
  const link = await slack.getPermalink(conv, ts);
  const brief = (t: string) => `🔎 *Issue raised in ${label}* by *${reporter}*`;
  if (repo && repo !== "null" && investigated < MAX_INVESTIGATE) {
    investigated++;
    log(`${label}: investigating flagged issue in ${repo} (by ${reporter})`);
    const findings = await investigate(cfg, repo, text, reporter, link, "issue");
    if (findings) {
      const toPost = await reconsider(cfg, slack, conv, ts, findings);
      if (toPost) await postAnswer(slack, args, conv, ts, toPost);
      await notifyOwner(cfg, slack, args, `🔎 *Issue raised in ${label}* by *${reporter}* (FYI, no action needed)\n> ${text.slice(0, 500)}\n${link ? `<${link}|open in Slack> · ` : ""}repo: \`${repo}\`\n\n${findings}`);
    } else {
      await notifyOwner(cfg, slack, args, `🔎 *Issue raised in ${label}* by *${reporter}* <@${cfg.notifyUserId}>\n> ${text.slice(0, 500)}\n${link ? `<${link}|open in Slack> · ` : ""}repo: \`${repo}\`\n\n(investigation failed — see slack-watch.log)`);
    }
  } else {
    await notifyOwner(cfg, slack, args, `⚠️ *Possible issue in ${label}* by *${reporter}* <@${cfg.notifyUserId}>\n> ${text.slice(0, 500)}\n${link ? `<${link}|open in Slack> · ` : ""}${why ? `_${why}_ · ` : ""}repo: ${repo || "unclear"}`);
  }
}

// --- read-only investigate: checkout the repo's default branch, hand to a sub-agent ---
async function investigate(cfg: Config, repo: string, issue: string, reporter: string, link: string | undefined, mode: "issue" | "question"): Promise<string> {
  const bare = join(REPOS, `${repo}.git`);
  if (!ensureBareClone(cfg.githubOrg, repo, bare)) {
    log(`clone ${repo} failed`);
    return "";
  }
  const sha = headSha(bare);
  const wt = join(WORKTREES, `watch-${repo}-${nowEpoch()}-${Math.floor(Math.random() * 1e6)}`);
  if (!addWorktree(bare, wt, sha)) {
    log(`${repo}: could not check out ${sha} for investigation`);
    return "";
  }
  const intro = mode === "question"
    ? `Someone asked this question in Slack. Answer it against this repo (${cfg.githubOrg}/${repo}), grounded in the code.`
    : `Someone raised this in Slack. Investigate it against this repo (${cfg.githubOrg}/${repo}).`;
  const res = await runClaude({
    prompt: `${intro}\n\n--- FROM: ${reporter} ---\n${issue}\n--- END ---\n\nSlack link: ${link ?? "(none)"}`,
    systemPrompt: loadPrompt("slack-investigate-prompt.md"),
    model: INVESTIGATE_MODEL,
    allowedTools: "Bash,Read,Grep,Glob",
    disallowedTools: "Edit,Write,NotebookEdit",
    strictEmptyMcp: true,
    budgetUsd: BUDGET_USD,
    cwd: wt,
    logAppend: log,
  });
  removeWorktree(bare, wt);
  if (!res.ok) {
    log(`${repo}: investigation failed (rc=${res.code})`);
    return "";
  }
  return res.output;
}

// --- reconsider against recent whole-channel activity before posting ---
async function reconsider(cfg: Config, slack: Slack, conv: string, trig: string, candidate: string): Promise<string> {
  const since = Number(trig.split(".")[0]) - RECONSIDER_LOOKBACK;
  const hist = await slack.history(conv, String(since), HIST_LIMIT);
  if (!hist.ok) return candidate;
  const msgs = (hist.messages as SlackMsg[]) ?? [];
  const clean = (arr: SlackMsg[]) => arr
    .filter((m) => m.subtype == null && m.bot_id == null && m.user !== cfg.botUserId && (m.text ?? "") !== "")
    .map((m) => ({ ts: m.ts, user: m.user, text: m.text }));
  let context = clean(msgs);
  const roots = [...msgs].filter((m) => (m.reply_count ?? 0) > 0).sort((a, b) => b.ts.localeCompare(a.ts)).slice(0, RECONSIDER_MAX_THREADS);
  for (const root of roots) {
    const rep = await slack.replies(conv, root.ts, 50);
    if (rep.ok) context = context.concat(clean((rep.messages as SlackMsg[]) ?? []));
  }
  // dedup by ts, oldest first
  const seen = new Set<string>();
  context = context.filter((m) => (seen.has(m.ts) ? false : (seen.add(m.ts), true))).sort((a, b) => a.ts.localeCompare(b.ts));
  if (context.length === 0) return candidate;

  log(`reconsider: judging against ${context.length} recent channel message(s)`);
  const res = await runClaude({
    prompt: `We are about to post a reply in a Slack thread. Below is our draft, then ALL\nrecent human activity in the same channel (top-level messages and thread replies,\noldest first) — including other threads. Decide if posting still helps.\n\n--- OUR DRAFT REPLY ---\n${candidate}\n--- RECENT CHANNEL ACTIVITY (JSON) ---\n${JSON.stringify(context)}\n--- END ---`,
    systemPrompt: loadPrompt("slack-reconsider-prompt.md"),
    model: CLASSIFY_MODEL,
    allowedTools: "",
    logAppend: log,
  });
  const m = res.output.match(/\{[\s\S]*\}/);
  if (!m) return candidate;
  let action = "post", revised = "";
  try {
    const v = JSON.parse(m[0]) as { action?: string; text?: string };
    action = v.action ?? "post";
    revised = v.text ?? "";
  } catch {
    return candidate;
  }
  if (action === "skip") {
    log("reconsider: skipping — already covered in recent channel activity");
    return "";
  }
  if (action === "revise" && revised) {
    log("reconsider: posting revised addition");
    return revised;
  }
  return candidate;
}

// --- posting: summary top-line + threaded detail (split on ---DETAIL---) ---
async function postAnswer(slack: Slack, args: WatchArgs, conv: string, ts: string, text: string): Promise<void> {
  if (!text.split("\n").includes("---DETAIL---")) {
    await sendReply(slack, args, conv, ts, text);
    return;
  }
  const idx = text.split("\n").indexOf("---DETAIL---");
  const lines = text.split("\n");
  const summary = lines.slice(0, idx).join("\n").trim();
  const detail = lines.slice(idx + 1).join("\n").trim();
  const posted = await sendReply(slack, args, conv, ts, summary);
  if (posted && detail) {
    if (args.dryRun) {
      process.stdout.write(`  WOULD POST DETAIL in ${conv}:\n    ${detail}\n`);
    } else {
      const r = await slack.postMessage(conv, detail, { threadTs: ts });
      if (!r.ok) log(`detail post failed in ${conv}: ${r.error}`);
    }
  }
}

async function sendReply(slack: Slack, args: WatchArgs, conv: string, ts: string, text: string): Promise<boolean> {
  if (repliesSent >= MAX_REPLIES) {
    log(`reply cap ${MAX_REPLIES} hit, holding rest for next pass`);
    return false;
  }
  if (args.dryRun) {
    process.stdout.write(`  WOULD REPLY in ${conv}:\n    ${text}\n`);
    return true;
  }
  const r = await slack.postMessage(conv, text, { threadTs: ts });
  if (r.ok) {
    repliesSent++;
    log(`replied in ${conv} (thread ${ts})`);
    return true;
  }
  log(`reply failed in ${conv}: ${r.error}`);
  return false;
}

async function notifyOwner(cfg: Config, slack: Slack, args: WatchArgs, text: string): Promise<void> {
  if (args.dryRun) {
    process.stdout.write(`  WOULD NOTIFY OWNER:\n${text}\n`);
    return;
  }
  const r = await slack.postMessage(cfg.notifyChannel, text);
  if (!r.ok) log(`notify failed: ${r.error}`);
}

function parseJsonArray<T>(out: string): T[] | undefined {
  const m = out.match(/\[[\s\S]*\]/);
  if (!m) return undefined;
  try {
    return JSON.parse(m[0]) as T[];
  } catch {
    return undefined;
  }
}

interface SlackMsg {
  ts: string;
  user: string;
  text?: string;
  subtype?: string;
  bot_id?: string;
  reply_count?: number;
}
type EnrichedMsg = { ts: string; user: string; text?: string; name: string };

// digest — port of run.sh. Collect state → claude -p writes a short digest → post
// to the owner's notify channel. Morning brief (fuller, restates the day) the first
// run each day; normal status otherwise. Working-hours gated. State-advance ordering
// is load-bearing: last-run/last-morning after a good claude run; last-digest.md only
// after a confirmed Slack post; a dry-run advances nothing.
import { loadConfig } from "../lib/config.ts";
import { makeLogger } from "../lib/log.ts";
import { acquireLock, readFile, writeFile, removeFile } from "../lib/state.ts";
import { nowEpoch, localHour, localDate, isoWeekday, epochDaysAgoMidnight } from "../lib/time.ts";
import { runClaude } from "../lib/claude.ts";
import { Slack } from "../lib/slack.ts";
import { loadPrompt } from "../lib/prompts.ts";
import { collect } from "./collect.ts";

const log = makeLogger("run.log");
const MODEL = "sonnet";
const START_HOUR = 9;
const END_HOUR = 18;

export interface DigestArgs {
  dryRun: boolean;
  sinceOverride?: number;
  forceMorning: boolean;
}

export async function runDigest(args: DigestArgs): Promise<void> {
  const cfg = loadConfig();
  const lock = acquireLock("lock.d", 20);
  if (!lock) {
    log("previous run still going, skipping");
    return;
  }
  try {
    const now = nowEpoch();
    if (!args.dryRun && (localHour() < START_HOUR || localHour() >= END_HOUR)) return;

    const today = localDate();
    const morning = args.forceMorning || readFile("last-morning")?.trim() !== today;
    const mode: "normal" | "morning" = morning ? "morning" : "normal";

    let since: number;
    if (args.sinceOverride !== undefined) since = args.sinceOverride;
    else if (morning) since = epochDaysAgoMidnight(isoWeekday() === 1 ? 3 : 1);
    else since = Number(readFile("last-run")) || now - 1800;

    let dump = collect(since, mode);
    if (!dump.trim()) {
      log("collect produced nothing — aborting");
      return;
    }
    let prev: string;
    if (morning) {
      dump = `=== MODE: MORNING BRIEF ===\n${dump}`;
      prev = "(none — this is the morning brief, restate the day in full)";
    } else {
      prev = readFile("last-digest.md") ?? "(none — first run)";
    }

    const res = await runClaude({
      prompt: `${dump}\n\n=== PREVIOUS DIGEST (what you already told the owner last run) ===\n${prev}`,
      systemPrompt: loadPrompt("digest-prompt.md"),
      model: MODEL,
      allowedTools: "",
      logAppend: log,
    });

    if (!res.ok) {
      // one-time failure post, then suppress until it recovers
      if (readFile("last-error") !== "claude-failed" && !args.dryRun) {
        const slack = new Slack(cfg.botToken);
        await slack.postMessage(cfg.notifyChannel, "⚠️ status bot could not run claude -p");
        writeFile("last-error", "claude-failed");
      }
      log(`claude failed (rc=${res.code})`);
      return;
    }
    if (!args.dryRun) removeFile("last-error");

    let digest = res.output;
    // NO_UPDATE: normal → skip; morning → fixed fallback so the brief always posts.
    if (digest.slice(0, 9) === "NO_UPDATE") {
      if (!morning) {
        log("NO_UPDATE — nothing to post");
        if (!args.dryRun) {
          writeFile("last-run", String(now));
          writeFile("last-morning", today);
        }
        return;
      }
      digest = "Nothing moved since the last working day — no new commits, PRs, or sessions to report.";
    }

    if (args.dryRun) {
      process.stdout.write(digest + "\n");
      return;
    }

    // advance run markers after a good claude run (before the Slack post)
    writeFile("last-run", String(now));
    writeFile("last-morning", today);

    const header = morning
      ? `🌅 *Morning brief* · ${fmtDate("%A %d %b")}  <@${cfg.notifyUserId}>`
      : `🕐 *Status* · ${fmtDate("%a %H:%M")}  <@${cfg.notifyUserId}>`;
    const slack = new Slack(cfg.botToken);
    const r = await slack.postMessage(cfg.notifyChannel, `${header}\n${digest}`);
    if (r.ok) {
      writeFile("last-digest.md", digest); // only after a confirmed post
      log(`posted ${digest.length} byte digest`);
    } else {
      log(`slack error: ${r.error}`);
    }
  } finally {
    lock.release();
  }
}

// Minimal strftime for the two header formats run.sh used.
function fmtDate(fmt: string): string {
  const d = new Date();
  const days = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];
  const daysShort = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
  const months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  const pad = (n: number) => String(n).padStart(2, "0");
  return fmt
    .replace("%A", days[d.getDay()]!)
    .replace("%a", daysShort[d.getDay()]!)
    .replace("%d", pad(d.getDate()))
    .replace("%b", months[d.getMonth()]!)
    .replace("%H", pad(d.getHours()))
    .replace("%M", pad(d.getMinutes()));
}

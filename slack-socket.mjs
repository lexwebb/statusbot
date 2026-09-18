#!/usr/bin/env node
// slack-socket.mjs — the reactive front-half of slack-watch.sh.
//
// The 5-min launchd poll (slack-watch.sh) still runs and remains the backstop
// for everything: channel watching, flag/investigate, and any event this daemon
// misses. This daemon exists for ONE thing the poll is too slow for: replying
// fast when someone directly addresses the bot (an @-mention or a DM). On such
// an event it shells out to `slack-watch.sh --once <channel> --respect-hours`,
// which runs the exact same classify → reply → reconsider path a poll would —
// no logic is duplicated here. All the guards (working hours, no-backlog cursor
// seeding, whole-channel reconsider, caps) live in the bash and are reused.
//
// Requires a Slack app-level token (xapp-…, scope connections:write) in
// config.json as `appToken`, with Socket Mode enabled and the bot subscribed to
// the `app_mention` and `message.im` events.
//
// Run by launchd agent com.<user>.statusbot.slacksocket (KeepAlive, RunAtLoad).

import { readFileSync } from "node:fs";
import { spawn } from "node:child_process";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { SocketModeClient } from "@slack/socket-mode";

const DIR = dirname(fileURLToPath(import.meta.url));
const CONFIG = join(DIR, "config.json");
const WATCH = join(DIR, "slack-watch.sh");

const ts = () => new Date().toISOString();
const log = (...a) => console.log(`[${ts()}]`, ...a);

let cfg;
try {
  cfg = JSON.parse(readFileSync(CONFIG, "utf8"));
} catch (e) {
  console.error(`cannot read ${CONFIG}: ${e.message}`);
  process.exit(1);
}
const appToken = cfg.appToken;
const botUserId = cfg.botUserId;
if (!appToken || !appToken.startsWith("xapp-")) {
  console.error("config.json needs an app-level token in `appToken` (xapp-…, scope connections:write)");
  process.exit(1);
}

// Per-channel debounce: a burst of edits/mentions in one channel collapses into a
// single --once run, and a run already in flight for that channel isn't stacked.
// The bash cursor means one run picks up everything new since last time anyway.
const DEBOUNCE_MS = 3000;
const pending = new Map();   // channel -> timer
const running = new Set();   // channels with a live --once child

function trigger(channel) {
  if (!channel) return;
  clearTimeout(pending.get(channel));
  pending.set(channel, setTimeout(() => {
    pending.delete(channel);
    if (running.has(channel)) return;   // a run is already covering this channel
    running.add(channel);
    log(`triggering slack-watch --once ${channel}`);
    const child = spawn("bash", [WATCH, "--once", channel, "--respect-hours"], {
      cwd: DIR,
      stdio: "ignore",   // the bash logs to state/slack-watch.log itself
    });
    child.on("exit", (code) => {
      running.delete(channel);
      if (code) log(`slack-watch --once ${channel} exited ${code}`);
    });
    child.on("error", (err) => {
      running.delete(channel);
      log(`failed to spawn slack-watch for ${channel}: ${err.message}`);
    });
  }, DEBOUNCE_MS));
}

const socket = new SocketModeClient({ appToken });

// app_mention: the bot was @-mentioned in a channel it's in.
// message (im): a DM to the bot. Both are "someone is addressing the bot" — the
// fast path. We ignore the bot's own messages (loop guard; the bash also does).
socket.on("app_mention", async ({ event, ack }) => {
  await ack?.();
  if (event?.user === botUserId) return;
  trigger(event?.channel);
});

socket.on("message", async ({ event, ack }) => {
  await ack?.();
  if (!event || event.subtype) return;              // edits/joins/etc.
  if (event.user === botUserId || event.bot_id) return;
  if (event.channel_type === "im") trigger(event.channel);
  // Non-DM channel messages are left to the 5-min poll — this daemon only
  // fast-tracks direct address, deliberately, to avoid making the bot chattier.
});

socket.on("disconnect", () => log("socket disconnected"));
socket.on("connected", () => log("socket connected"));

log("starting Socket Mode daemon");
await socket.start();

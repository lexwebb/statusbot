// The reactive front-half of slack-watch: a Socket Mode WebSocket that, on a live
// @-mention or DM, shells out to the slack-watch job for that one conversation so
// the reply is seconds-fast instead of waiting up to 5 min for the poll. Port of
// slack-socket.mjs. All classify/reply/reconsider logic stays in slack-watch — this
// is just a faster trigger. The 5-min poll remains the backstop.
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { SocketModeClient } from "@slack/socket-mode";
import { loadConfig } from "../lib/config.ts";
import { makeLogger } from "../lib/log.ts";

const log = makeLogger("slack-socket.log");
const here = dirname(fileURLToPath(import.meta.url));
const watchEntry = join(here, "..", "bin", "slack-watch.ts");

export async function runSocket(): Promise<void> {
  const cfg = loadConfig();
  const appToken = cfg.appToken;
  if (!appToken || !appToken.startsWith("xapp-")) {
    console.error("config.json needs an app-level token in `appToken` (xapp-…, scope connections:write)");
    process.exit(1);
  }
  const botUserId = cfg.botUserId;

  // Per-channel debounce: a burst in one channel collapses to one --once run, and a
  // run already in flight for that channel isn't stacked. The bash cursor means one
  // run picks up everything new since last time anyway.
  const DEBOUNCE_MS = 3000;
  const pending = new Map<string, NodeJS.Timeout>();
  const running = new Set<string>();

  function trigger(channel: string | undefined): void {
    if (!channel) return;
    clearTimeout(pending.get(channel));
    pending.set(
      channel,
      setTimeout(() => {
        pending.delete(channel);
        if (running.has(channel)) return;
        running.add(channel);
        log(`triggering slack-watch --once ${channel}`);
        const child = spawn("tsx", [watchEntry, "--once", channel, "--respect-hours"], {
          cwd: join(here, "..", ".."),
          stdio: "ignore",
        });
        child.on("exit", (code) => {
          running.delete(channel);
          if (code) log(`slack-watch --once ${channel} exited ${code}`);
        });
        child.on("error", (err) => {
          running.delete(channel);
          log(`failed to spawn slack-watch for ${channel}: ${err.message}`);
        });
      }, DEBOUNCE_MS),
    );
  }

  const socket = new SocketModeClient({ appToken });

  socket.on("app_mention", async ({ event, ack }: { event: { user?: string; channel?: string }; ack?: () => Promise<void> }) => {
    await ack?.();
    if (event?.user === botUserId) return;
    trigger(event?.channel);
  });

  socket.on("message", async ({ event, ack }: { event: { subtype?: string; user?: string; bot_id?: string; channel?: string; channel_type?: string }; ack?: () => Promise<void> }) => {
    await ack?.();
    if (!event || event.subtype) return;
    if (event.user === botUserId || event.bot_id) return;
    if (event.channel_type === "im") trigger(event.channel);
    // Non-DM channel messages stay with the 5-min poll — the daemon only fast-tracks
    // direct address, deliberately, so it can't make the bot chattier.
  });

  socket.on("disconnect", () => log("socket disconnected"));
  socket.on("connected", () => log("socket connected"));

  log("starting Socket Mode daemon");
  await socket.start();
}

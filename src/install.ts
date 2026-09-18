// Installer — port of install.sh. Validates config + tokens + watch membership,
// then registers OS schedulers that fire the tsx entrypoints: digest/review/
// slackwatch on intervals, socket as a KeepAlive daemon (only when appToken is set).
// Flags: --no-schedule (validate only), --uninstall.
import { writeFileSync, mkdirSync, rmSync, existsSync } from "node:fs";
import { spawnSync } from "node:child_process";
import { homedir, platform } from "node:os";
import { join } from "node:path";
import { userInfo } from "node:os";
import { DIR, loadConfig } from "./lib/config.ts";

const ok = (m: string) => console.log(`  ✓ ${m}`);
const warn = (m: string) => console.log(`  ⚠ ${m}`);
const die = (m: string): never => {
  console.error(`  ✗ ${m}`);
  process.exit(1);
};

const mode = process.argv[2] === "--uninstall" ? "uninstall" : process.argv[2] === "--no-schedule" ? "validate" : "install";
const user = userInfo().username;
const LABEL = "statusbot";
const isMac = platform() === "darwin";

// Each job: name, entrypoint (relative to DIR), and schedule kind.
type Kind = { type: "interval"; seconds: number } | { type: "daemon" };
interface Job {
  name: string;
  entry: string;
  kind: Kind;
}
const JOBS: Job[] = [
  { name: "digest", entry: "src/bin/digest.ts", kind: { type: "interval", seconds: 1800 } },
  { name: "review", entry: "src/bin/review.ts", kind: { type: "interval", seconds: 300 } },
  { name: "slackwatch", entry: "src/bin/slack-watch.ts", kind: { type: "interval", seconds: 300 } },
  { name: "slacksocket", entry: "src/bin/socket.ts", kind: { type: "daemon" } },
];

const laDir = join(homedir(), "Library", "LaunchAgents");
const sdDir = join(homedir(), ".config", "systemd", "user");
const tsx = join(DIR, "node_modules", ".bin", "tsx");

function labelFor(name: string): string {
  return `com.${user}.${LABEL}.${name}`;
}

if (mode === "uninstall") {
  console.log("Removing statusbot schedulers…");
  for (const job of JOBS) {
    if (isMac) {
      const plist = join(laDir, `${labelFor(job.name)}.plist`);
      spawnSync("launchctl", ["unload", plist]);
      rmSync(plist, { force: true });
      ok(`removed ${labelFor(job.name)}`);
    } else if (hasSystemd()) {
      spawnSync("systemctl", ["--user", "disable", "--now", `${LABEL}-${job.name}.timer`]);
      spawnSync("systemctl", ["--user", "disable", "--now", `${LABEL}-${job.name}.service`]);
      rmSync(join(sdDir, `${LABEL}-${job.name}.service`), { force: true });
      rmSync(join(sdDir, `${LABEL}-${job.name}.timer`), { force: true });
      ok(`removed ${LABEL}-${job.name}`);
    }
  }
  if (!isMac && hasSystemd()) spawnSync("systemctl", ["--user", "daemon-reload"]);
  process.exit(0);
}

// ---- validate ----
const cfg = loadConfig();
ok("config.json valid");
for (const tool of ["node", "git", "gh", "claude"]) {
  if (spawnSync(tool, ["--version"]).status !== 0 && spawnSync("which", [tool]).status !== 0) die(`missing required tool: ${tool}`);
}
ok("required tools present");

// bot token
const auth = await slackGet("auth.test", cfg.botToken);
if (!auth.ok) die(`Slack auth.test failed: ${auth.error}`);
ok(`bot token valid — @${auth.user} in ${auth.team}`);
if (auth.user_id !== cfg.botUserId) warn(`config botUserId (${cfg.botUserId}) != token's user (${auth.user_id})`);

// app token (only if the daemon is wanted)
let wantDaemon = false;
if (cfg.appToken?.startsWith("xapp-")) {
  const conn = await slackPost("apps.connections.open", cfg.appToken);
  if (conn.ok) {
    wantDaemon = true;
    ok("app token valid — Socket Mode daemon will be installed");
  } else {
    warn(`appToken set but apps.connections.open failed: ${conn.error} — skipping the daemon; poll-only`);
  }
} else if (cfg.appToken && !cfg.appToken.startsWith("xapp-REPLACE")) {
  warn("appToken is set but isn't an xapp- token — ignoring; poll-only");
}

// watch-channel membership
for (const w of cfg.watch) {
  const h = await slackGet(`conversations.history?channel=${w.id}&limit=1`, cfg.botToken);
  if (h.ok) ok(`watch #${w.name} readable`);
  else warn(`watch #${w.name}: ${h.error} — /invite the bot to it`);
}

// npm deps (tsx + @slack/socket-mode) — always, since jobs run via tsx
if (spawnSync("node", ["--version"]).status !== 0) die("node not found");
console.log("Installing Node deps…");
if (spawnSync("npm", ["install", "--omit=dev"], { cwd: DIR, stdio: "ignore" }).status === 0) ok("npm deps installed");
else die("npm install failed");
// dev deps too (tsx runs the .ts entrypoints)
spawnSync("npm", ["install"], { cwd: DIR, stdio: "ignore" });

writePathEnv();

if (mode === "validate") {
  console.log("Validation done (--no-schedule).");
  process.exit(0);
}

// ---- schedule ----
mkdirSync(join(DIR, "state"), { recursive: true });
if (isMac) {
  console.log("Installing launchd agents…");
  for (const job of JOBS) {
    if (job.kind.type === "daemon" && !wantDaemon) {
      rmSync(join(laDir, `${labelFor(job.name)}.plist`), { force: true });
      continue;
    }
    const plist = join(laDir, `${labelFor(job.name)}.plist`);
    spawnSync("launchctl", ["unload", plist]);
    writeFileSync(plist, plistFor(job));
    if (spawnSync("launchctl", ["load", plist]).status === 0) ok(`loaded ${labelFor(job.name)}`);
  }
} else if (hasSystemd()) {
  console.log("Installing systemd user units…");
  for (const job of JOBS) {
    if (job.kind.type === "daemon" && !wantDaemon) {
      spawnSync("systemctl", ["--user", "disable", "--now", `${LABEL}-${job.name}.service`]);
      continue;
    }
    writeSystemd(job);
  }
  spawnSync("systemctl", ["--user", "daemon-reload"]);
  for (const job of JOBS) {
    if (job.kind.type === "daemon" && !wantDaemon) continue;
    const unit = job.kind.type === "daemon" ? `${LABEL}-${job.name}.service` : `${LABEL}-${job.name}.timer`;
    if (spawnSync("systemctl", ["--user", "enable", "--now", unit]).status === 0) ok(`enabled ${unit}`);
  }
  warn(`for units to run while logged out: 'sudo loginctl enable-linger ${user}'`);
} else {
  console.log("No launchd or systemd — installing crontab entries…");
  installCron(wantDaemon);
}
console.log(`\nDone. Smoke-test with e.g.: cd ${DIR} && npm run digest -- --dry-run`);

// ---- helpers ----
function plistFor(job: Job): string {
  const body =
    job.kind.type === "daemon"
      ? `  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict><key>ThrottleInterval</key><integer>10</integer>\n  <key>RunAtLoad</key><true/>`
      : `  <key>StartInterval</key><integer>${job.kind.seconds}</integer>\n  <key>RunAtLoad</key><false/>`;
  const lbl = labelFor(job.name);
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>${lbl}</string>
  <key>ProgramArguments</key><array><string>${tsx}</string><string>${join(DIR, job.entry)}</string></array>
${body}
  <key>StandardOutPath</key><string>${join(DIR, "state", lbl + ".out")}</string>
  <key>StandardErrorPath</key><string>${join(DIR, "state", lbl + ".err")}</string>
  <key>EnvironmentVariables</key><dict><key>PATH</key><string>${pathValue()}</string></dict>
  <key>ProcessType</key><string>Background</string>
</dict></plist>
`;
}

function writeSystemd(job: Job): void {
  mkdirSync(sdDir, { recursive: true });
  const exec = `${tsx} ${join(DIR, job.entry)}`;
  if (job.kind.type === "daemon") {
    writeFileSync(join(sdDir, `${LABEL}-${job.name}.service`), `[Unit]\nDescription=statusbot ${job.name} (daemon)\n[Service]\nType=simple\nExecStart=${exec}\nRestart=always\nRestartSec=10\n[Install]\nWantedBy=default.target\n`);
    rmSync(join(sdDir, `${LABEL}-${job.name}.timer`), { force: true });
  } else {
    writeFileSync(join(sdDir, `${LABEL}-${job.name}.service`), `[Unit]\nDescription=statusbot ${job.name}\n[Service]\nType=oneshot\nExecStart=${exec}\n`);
    const sec = job.kind.seconds;
    writeFileSync(join(sdDir, `${LABEL}-${job.name}.timer`), `[Unit]\nDescription=statusbot ${job.name} timer\n[Timer]\nOnUnitActiveSec=${sec}\nOnBootSec=${sec}\nPersistent=false\n[Install]\nWantedBy=timers.target\n`);
  }
}

function installCron(wantDaemon: boolean): void {
  const current = spawnSync("crontab", ["-l"], { encoding: "utf8" }).stdout ?? "";
  const kept = current.split("\n").filter((l) => l && !l.includes("# statusbot")).join("\n");
  const lines: string[] = [];
  for (const job of JOBS) {
    if (job.kind.type === "daemon") {
      warn("cron can't run the Socket Mode daemon — poll-only on this host");
      continue;
    }
    const min = job.kind.seconds >= 1800 ? "*/30" : "*/5";
    lines.push(`${min} * * * * ${tsx} ${join(DIR, job.entry)}  # statusbot ${job.name}`);
  }
  const next = (kept ? kept + "\n" : "") + lines.join("\n") + "\n";
  const r = spawnSync("crontab", ["-"], { input: next });
  if (r.status === 0) ok("crontab updated");
  void wantDaemon;
}

function pathValue(): string {
  // The dir holding the running node binary (e.g. ~/.nvm/versions/node/vX/bin) —
  // the tsx shim is `#!/usr/bin/env node`, so this MUST be on PATH under launchd's
  // bare environment. Derive it from execPath rather than guessing the nvm layout.
  const nodeBin = join(process.execPath, "..");
  return `${nodeBin}:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin`;
}
function writePathEnv(): void {
  // Kept for parity/debugging; the plist sets PATH directly via EnvironmentVariables.
  writeFileSync(join(DIR, "path.env"), `export PATH="${pathValue()}:$PATH"\n`);
  ok("path.env written");
}
function hasSystemd(): boolean {
  return spawnSync("which", ["systemctl"]).status === 0;
}

interface SlackAuth {
  ok: boolean;
  error?: string;
  user?: string;
  team?: string;
  user_id?: string;
}
async function slackGet(method: string, token: string): Promise<SlackAuth> {
  const res = await fetch(`https://slack.com/api/${method}`, { headers: { Authorization: `Bearer ${token}` } });
  return (await res.json()) as SlackAuth;
}
async function slackPost(method: string, token: string): Promise<SlackAuth> {
  const res = await fetch(`https://slack.com/api/${method}`, { method: "POST", headers: { Authorization: `Bearer ${token}` } });
  return (await res.json()) as SlackAuth;
}

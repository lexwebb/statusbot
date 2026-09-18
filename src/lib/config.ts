// Typed load of config.json — the single source of instance config. Replaces the
// scattered `jq -r '.foo // empty'` reads across every shell script. Read once,
// validated, shared. The file itself is unchanged (gitignored; symlinked from
// ~/.config/claude-slack/config.json).
import { readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

export const DIR = join(homedir(), ".claude", "statusbot");
export const STATE_DIR = join(DIR, "state");
const CONFIG_PATH = join(DIR, "config.json");

export interface ChannelRoute {
  id: string;
  for: string;
}
export interface RepoEntry {
  name: string;
  for: string;
}
export interface WatchEntry {
  id: string;
  name: string;
}

export interface Config {
  botToken: string;
  appToken?: string; // xapp-… — only for the Socket Mode daemon
  githubOrg: string;
  githubUser: string;
  ownerName: string;
  botUserId: string;
  notifyChannel: string;
  notifyUserId: string;
  defaultChannel?: string;
  botLogins: string[];
  default: string; // PR-review routing: default channel id
  fallback: string; // PR-review routing: fallback channel id
  channels: Record<string, ChannelRoute>;
  users: Record<string, string>; // github login → slack user id
  watch: WatchEntry[];
  repos: RepoEntry[];
}

let cached: Config | undefined;

export function loadConfig(): Config {
  if (cached) return cached;
  let raw: unknown;
  try {
    raw = JSON.parse(readFileSync(CONFIG_PATH, "utf8"));
  } catch (e) {
    throw new Error(`cannot read ${CONFIG_PATH}: ${(e as Error).message}`);
  }
  const c = raw as Partial<Config>;
  // Match the shell's required-key checks (install.sh:79) plus sensible defaults.
  for (const k of ["botToken", "githubOrg", "githubUser", "botUserId", "notifyChannel"] as const) {
    if (!c[k]) throw new Error(`config.json missing required key: ${k}`);
  }
  cached = {
    ownerName: "the owner",
    botLogins: [],
    channels: {},
    users: {},
    watch: [],
    repos: [],
    default: "",
    fallback: "",
    notifyUserId: "",
    ...c,
  } as Config;
  return cached;
}

/** Allowlist check: is this Slack user id a value in config.users? (ask/review authz.) */
export function isAllowed(slackUserId: string): boolean {
  if (!slackUserId) return false;
  return Object.values(loadConfig().users).includes(slackUserId);
}

/** Bot-login matcher, case-insensitive, optional [bot] suffix — mirrors the BOTS regex. */
export function isBotLogin(login: string): boolean {
  const bots = loadConfig().botLogins.map((b) => b.toLowerCase());
  const l = login.toLowerCase().replace(/\[bot\]$/, "");
  return bots.includes(l);
}

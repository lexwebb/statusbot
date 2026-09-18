// Slack Web API over fetch (Node 22 built-in) — replaces the curl+jq calls in every
// script. Bot-token client. Method surface is only what the jobs use.
import { readFile, writeFile } from "./state.ts";

const API = "https://slack.com/api";

export interface SlackResponse {
  ok: boolean;
  error?: string;
  [k: string]: unknown;
}

export class Slack {
  constructor(private token: string) {}

  private async get(method: string, params: Record<string, string>): Promise<SlackResponse> {
    const qs = new URLSearchParams(params).toString();
    const res = await fetch(`${API}/${method}?${qs}`, {
      headers: { Authorization: `Bearer ${this.token}` },
    });
    return (await res.json()) as SlackResponse;
  }

  private async post(method: string, body: Record<string, unknown>): Promise<SlackResponse> {
    const res = await fetch(`${API}/${method}`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${this.token}`,
        "Content-Type": "application/json; charset=utf-8",
      },
      body: JSON.stringify(body),
    });
    return (await res.json()) as SlackResponse;
  }

  /** Post a message; returns the ts on success. thread_ts/broadcast optional. */
  async postMessage(
    channel: string,
    text: string,
    opts: { threadTs?: string; broadcast?: boolean } = {},
  ): Promise<{ ok: boolean; ts?: string; error?: string }> {
    const body: Record<string, unknown> = {
      channel,
      text,
      unfurl_links: false,
      unfurl_media: false,
    };
    if (opts.threadTs) {
      body.thread_ts = opts.threadTs;
      if (opts.broadcast) body.reply_broadcast = true;
    }
    const r = await this.post("chat.postMessage", body);
    return { ok: r.ok, ts: r.ts as string | undefined, error: r.error };
  }

  async getPermalink(channel: string, ts: string): Promise<string | undefined> {
    const r = await this.get("chat.getPermalink", { channel, message_ts: ts });
    return r.ok ? (r.permalink as string) : undefined;
  }

  async history(channel: string, oldest: string, limit: number): Promise<SlackResponse> {
    return this.get("conversations.history", {
      channel,
      oldest,
      inclusive: "false",
      limit: String(limit),
    });
  }

  async replies(channel: string, ts: string, limit: number): Promise<SlackResponse> {
    return this.get("conversations.replies", { channel, ts, limit: String(limit) });
  }

  async listConversations(types: string, limit: number): Promise<SlackResponse> {
    return this.get("conversations.list", { types, exclude_archived: "true", limit: String(limit) });
  }

  async join(channel: string): Promise<SlackResponse> {
    return this.post("conversations.join", { channel });
  }

  async userName(userId: string): Promise<string> {
    const cache = loadUserCache();
    if (cache[userId]) return cache[userId];
    const r = await this.get("users.info", { user: userId });
    const p = (r.user as Record<string, Record<string, string>> | undefined)?.profile;
    const name =
      p?.display_name ||
      p?.real_name ||
      ((r.user as Record<string, string>)?.name ?? userId);
    cache[userId] = name;
    saveUserCache(cache);
    return name;
  }
}

// users.info cache (state/slack-users.json) — same file the shell used.
type UserCache = Record<string, string>;
function loadUserCache(): UserCache {
  const raw = readFile("slack-users.json");
  if (!raw) return {};
  try {
    return JSON.parse(raw) as UserCache;
  } catch {
    return {};
  }
}
function saveUserCache(c: UserCache): void {
  writeFile("slack-users.json", JSON.stringify(c));
}

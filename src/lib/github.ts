// gh / git wrappers (subprocess) + the /notifications conditional-GET change-gate.
// gh and git still shell out — TS can't replace them — but their JSON output is
// parsed natively instead of piped through jq.
import { spawnSync } from "node:child_process";
import { existsSync } from "node:fs";

export interface ExecResult {
  ok: boolean;
  stdout: string;
  stderr: string;
  code: number | null;
}

function run(cmd: string, args: string[], opts: { cwd?: string } = {}): ExecResult {
  const r = spawnSync(cmd, args, { cwd: opts.cwd, encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  return {
    ok: r.status === 0,
    stdout: (r.stdout ?? "").trim(),
    stderr: (r.stderr ?? "").trim(),
    code: r.status,
  };
}

export const gh = (args: string[], opts?: { cwd?: string }) => run("gh", args, opts);
export const git = (args: string[], opts?: { cwd?: string }) => run("git", args, opts);

/** `gh api` returning parsed JSON, or undefined on failure. */
export function ghJson<T>(args: string[]): T | undefined {
  const r = gh(["api", ...args]);
  if (!r.ok) return undefined;
  try {
    return JSON.parse(r.stdout) as T;
  } catch {
    return undefined;
  }
}

// ---- notifications change-gate (review.sh's cheap idle-skip) ----
export interface NotifCheck {
  status: 304 | 200 | "error";
  lastModified?: string; // the feed's Last-Modified, to persist as the next cursor
}

/**
 * Conditional GET /notifications with If-Modified-Since. 304 = nothing changed
 * (free, no rate quota). 200 = activity since the cursor. Uses `gh api --include`
 * so we can read the status line and Last-Modified header. An error is distinct
 * from 304 so callers fall through to a full scan rather than skipping.
 */
export function checkNotifications(since?: string): NotifCheck {
  const args = ["api", "/notifications?all=false", "--include"];
  if (since) args.push("-H", `If-Modified-Since: ${since}`);
  const r = gh(args);
  const body = r.stdout + "\n" + r.stderr;
  if (!r.ok && /304 Not Modified/i.test(body)) return { status: 304 };
  if (r.ok || /HTTP\/[\d.]+ 200/i.test(body)) {
    const m = body.match(/^last-modified:\s*(.+?)\s*$/im);
    return { status: 200, lastModified: m?.[1] };
  }
  return { status: "error" };
}

// ---- git worktree helpers for read-only investigate/review checkouts ----
export function ensureBareClone(org: string, repo: string, barePath: string): boolean {
  if (!existsSync(barePath)) {
    if (!gh(["repo", "clone", `${org}/${repo}`, barePath, "--", "--bare", "-q"]).ok) return false;
  }
  git(["-C", barePath, "fetch", "-q", "--prune", "origin", "+refs/heads/*:refs/heads/*"]);
  return true;
}

export function headSha(barePath: string): string {
  return git(["-C", barePath, "rev-parse", "HEAD"]).stdout;
}

export function addWorktree(barePath: string, wt: string, sha: string): boolean {
  git(["-C", barePath, "worktree", "prune"]);
  return git(["-C", barePath, "worktree", "add", "--detach", "-q", wt, sha]).ok;
}

export function removeWorktree(barePath: string, wt: string): void {
  git(["-C", barePath, "worktree", "remove", "--force", wt]);
}

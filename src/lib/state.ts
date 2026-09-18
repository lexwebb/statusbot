// The state/ directory: cursors, per-PR reviewed SHAs, Slack thread anchors, the
// reviews ledger, per-conversation seen cursors, the mkdir-mutex lock, and the
// notifications cursor. Layout is UNCHANGED from the shell version so the TS suite
// reads existing on-disk state on cutover (an already-reviewed PR stays reviewed).
import {
  readFileSync,
  writeFileSync,
  appendFileSync,
  mkdirSync,
  rmdirSync,
  readdirSync,
  existsSync,
  statSync,
  unlinkSync,
} from "node:fs";
import { join } from "node:path";
import { STATE_DIR } from "./config.ts";

function ensureDir(p: string): string {
  mkdirSync(p, { recursive: true });
  return p;
}

// ---- simple scalar files (last-run, last-poll, last-morning, last-digest.md, …) ----
export function readFile(name: string): string | undefined {
  const p = join(STATE_DIR, name);
  return existsSync(p) ? readFileSync(p, "utf8") : undefined;
}
export function writeFile(name: string, content: string): void {
  ensureDir(STATE_DIR);
  writeFileSync(join(STATE_DIR, name), content);
}
export function removeFile(name: string): void {
  const p = join(STATE_DIR, name);
  if (existsSync(p)) unlinkSync(p);
}

// ---- per-key dirs: reviewed/<slug> (head SHA), threads/<slug> ("<ch> <ts> <verb>") ----
function keyPath(dir: string, key: string): string {
  return join(ensureDir(join(STATE_DIR, dir)), key);
}
export function readKey(dir: string, key: string): string | undefined {
  const p = keyPath(dir, key);
  return existsSync(p) ? readFileSync(p, "utf8") : undefined;
}
export function writeKey(dir: string, key: string, value: string): void {
  writeFileSync(keyPath(dir, key), value);
}
export function removeKey(dir: string, key: string): void {
  const p = keyPath(dir, key);
  if (existsSync(p)) unlinkSync(p);
}
export function listKeys(dir: string): string[] {
  const p = join(STATE_DIR, dir);
  return existsSync(p) ? readdirSync(p).filter((f) => statSync(join(p, f)).isFile()) : [];
}

// ---- the reviews ledger (append-only; tab-separated `<epoch>\t<line>`) ----
const LEDGER = "reviews.log";
export function appendLedger(line: string): void {
  ensureDir(STATE_DIR);
  appendFileSync(join(STATE_DIR, LEDGER), line.endsWith("\n") ? line : line + "\n");
}
/** Ledger lines (field 2) whose epoch (field 1) >= since. Mirrors collect.sh's awk. */
export function ledgerSince(since: number): string[] {
  const raw = readFile(LEDGER);
  if (!raw) return [];
  const out: string[] = [];
  for (const row of raw.split("\n")) {
    if (!row) continue;
    const tab = row.indexOf("\t");
    if (tab < 0) continue;
    const epoch = Number(row.slice(0, tab));
    if (Number.isFinite(epoch) && epoch >= since) out.push(row.slice(tab + 1));
  }
  return out;
}

// ---- mkdir-mutex lock (portable; no flock). Returns true if acquired. ----
export interface Lock {
  release(): void;
}
export function acquireLock(name: string, staleMinutes: number): Lock | undefined {
  ensureDir(STATE_DIR);
  const lockDir = join(STATE_DIR, name);
  try {
    mkdirSync(lockDir); // atomic: fails if it exists
  } catch {
    // Held. Clear it only if stale.
    const ageMin = existsSync(lockDir)
      ? (Date.now() - statSync(lockDir).mtimeMs) / 60000
      : Infinity;
    if (ageMin > staleMinutes) {
      try {
        rmdirSync(lockDir);
        mkdirSync(lockDir);
      } catch {
        return undefined;
      }
    } else {
      return undefined;
    }
  }
  return {
    release() {
      try {
        rmdirSync(lockDir);
      } catch {
        /* already gone */
      }
    },
  };
}

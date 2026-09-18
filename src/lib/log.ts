// Per-job append logger. Format matches the shell: `[<ISO-UTC>] <msg>` to
// state/<name>.log. Each job makes one logger.
import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";
import { STATE_DIR } from "./config.ts";

export type Logger = (msg: string) => void;

export function makeLogger(logFile: string): Logger {
  mkdirSync(STATE_DIR, { recursive: true });
  const path = join(STATE_DIR, logFile);
  return (msg: string) => {
    const ts = new Date().toISOString().replace(/\.\d{3}Z$/, "Z");
    appendFileSync(path, `[${ts}] ${msg}\n`);
  };
}

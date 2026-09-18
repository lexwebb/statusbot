// Native replacements for lib.sh's date/stat shims. The bash version branched on
// GNU vs BSD `date`/`stat`; JS Date and fs.statSync are the same everywhere.
import { statSync } from "node:fs";

/** Epoch seconds → ISO-8601 UTC, e.g. 2026-09-18T16:33:06Z. Matches iso_utc(). */
export function isoUtc(epochSeconds: number): string {
  return new Date(epochSeconds * 1000).toISOString().replace(/\.\d{3}Z$/, "Z");
}

/** Current epoch in whole seconds (bash `date +%s`). */
export function nowEpoch(): number {
  return Math.floor(Date.now() / 1000);
}

/**
 * Epoch of LOCAL midnight N days ago. Matches epoch_days_ago_midnight():
 * GNU `date -d "N days ago 00:00:00" +%s`. Uses local time deliberately — the
 * morning brief's "since Friday" reckons in the owner's local day.
 */
export function epochDaysAgoMidnight(n: number): number {
  const d = new Date();
  d.setDate(d.getDate() - n);
  d.setHours(0, 0, 0, 0);
  return Math.floor(d.getTime() / 1000);
}

/** File mtime in epoch seconds, or undefined if missing. Matches file_mtime(). */
export function fileMtime(path: string): number | undefined {
  try {
    return Math.floor(statSync(path).mtimeMs / 1000);
  } catch {
    return undefined;
  }
}

/** Whole minutes between an epoch and now (bash mins_ago). */
export function minsAgo(epochSeconds: number): number {
  return Math.floor((nowEpoch() - epochSeconds) / 60);
}

/** Local hour 0-23 (bash `date +%H` with leading zero stripped). */
export function localHour(): number {
  return new Date().getHours();
}

/** ISO date in local tz, YYYY-MM-DD (bash `date +%Y-%m-%d`). */
export function localDate(): string {
  const d = new Date();
  const p = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
}

/** ISO weekday 1-7, Mon=1 (bash `date +%u`). */
export function isoWeekday(): number {
  return new Date().getDay() === 0 ? 7 : new Date().getDay();
}

/** RFC-1123 / HTTP date for If-Modified-Since, e.g. "Fri, 18 Sep 2026 16:33:06 GMT". */
export function httpDate(epochSeconds: number): string {
  return new Date(epochSeconds * 1000).toUTCString();
}

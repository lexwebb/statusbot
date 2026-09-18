import { runSlackWatch, type WatchArgs } from "../jobs/slack-watch.ts";

const args: WatchArgs = { dryRun: false, respectHours: false };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  switch (argv[i]) {
    case "--dry-run": args.dryRun = true; break;
    case "--once": args.only = argv[++i]; break;
    case "--respect-hours": args.respectHours = true; break;
    default: console.error(`unknown arg: ${argv[i]}`); process.exit(2);
  }
}
await runSlackWatch(args);

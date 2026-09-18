import { runDigest, type DigestArgs } from "../jobs/digest.ts";

const args: DigestArgs = { dryRun: false, forceMorning: false };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  switch (argv[i]) {
    case "--dry-run": args.dryRun = true; break;
    case "--since": args.sinceOverride = Number(argv[++i]); break;
    case "--morning": args.forceMorning = true; break;
    default: console.error(`unknown arg: ${argv[i]}`); process.exit(2);
  }
}
await runDigest(args);

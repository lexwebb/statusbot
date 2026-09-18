import { runReview, type ReviewArgs } from "../jobs/review.ts";

const args: ReviewArgs = { dryRun: false, maxPerRun: 4 };
const argv = process.argv.slice(2);
for (let i = 0; i < argv.length; i++) {
  switch (argv[i]) {
    case "--dry-run": args.dryRun = true; break;
    case "--pr": args.only = argv[++i]; break;
    case "--max": args.maxPerRun = Number(argv[++i]); break;
    case "--reply-thread": args.replyThread = argv[++i]; break;
    default: console.error(`unknown arg: ${argv[i]}`); process.exit(2);
  }
}
await runReview(args);

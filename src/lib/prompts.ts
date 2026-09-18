// Load a prompt template from prompts/ and substitute {{OWNER}} / {{GITHUB_USER}}.
// Replaces the perl one-liner prompt_file() used by every shell script.
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { DIR, loadConfig } from "./config.ts";

const PROMPTS_DIR = join(DIR, "prompts");

export function loadPrompt(name: string): string {
  const cfg = loadConfig();
  const raw = readFileSync(join(PROMPTS_DIR, name), "utf8");
  return raw
    .replaceAll("{{OWNER}}", cfg.ownerName)
    .replaceAll("{{GITHUB_USER}}", cfg.githubUser);
}

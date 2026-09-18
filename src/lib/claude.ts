// Run `claude -p` as a subprocess. Wraps the invocation every job shared in bash:
// a system prompt file, a model, an allowed-tools set, optional sandbox + budget,
// and a cwd (jobs cd into a checkout or into DIR so no project CLAUDE.md leaks in).
import { spawn } from "node:child_process";

export interface ClaudeOptions {
  prompt: string; // the user prompt (-p)
  systemPrompt?: string; // --append-system-prompt (already substituted)
  model: string; // --model
  allowedTools: string; // --allowed-tools value ('' = none)
  disallowedTools?: string; // --disallowed-tools
  cwd?: string; // working directory for the sub-agent
  budgetUsd?: number; // --max-budget-usd
  strictEmptyMcp?: boolean; // --strict-mcp-config --mcp-config '{"mcpServers":{}}'
  logAppend?: (line: string) => void; // stderr sink
}

export interface ClaudeResult {
  ok: boolean;
  output: string; // trimmed stdout
  code: number | null;
}

export function runClaude(opts: ClaudeOptions): Promise<ClaudeResult> {
  const args = ["-p", opts.prompt, "--model", opts.model, "--allowed-tools", opts.allowedTools];
  if (opts.systemPrompt) args.push("--append-system-prompt", opts.systemPrompt);
  if (opts.disallowedTools) args.push("--disallowed-tools", opts.disallowedTools);
  if (opts.strictEmptyMcp) args.push("--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}');
  if (opts.budgetUsd !== undefined) args.push("--max-budget-usd", String(opts.budgetUsd));
  args.push("--no-session-persistence");

  return new Promise((resolve) => {
    const child = spawn("claude", args, { cwd: opts.cwd });
    let out = "";
    let err = "";
    child.stdout.on("data", (d) => (out += d));
    child.stderr.on("data", (d) => (err += d));
    child.on("error", (e) => {
      opts.logAppend?.(`claude spawn error: ${e.message}`);
      resolve({ ok: false, output: "", code: null });
    });
    child.on("close", (code) => {
      if (err.trim()) opts.logAppend?.(err.trim());
      const output = out.trim();
      resolve({ ok: code === 0 && output.length > 0, output, code });
    });
  });
}

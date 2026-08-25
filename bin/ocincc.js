#!/usr/bin/env node
/**
 * ocincc — one-command setup for running OpenCode Zen free models inside Claude Code.
 * Installs a local LiteLLM proxy + `zen-claude` launcher.
 */
const { execSync, spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");
const readline = require("readline");

const DIR = path.join(os.homedir(), ".config", "zen-claude");
const LAUNCHER_SRC = path.join(__dirname, "zen-claude.sh");
const LAUNCHER_DST = path.join(DIR, "zen-claude");
const ENV_FILE = path.join(DIR, ".env");

function log(msg) { console.log(`\x1b[2m[ocincc]\x1b[0m ${msg}`); }
function fail(msg) { console.error(`\x1b[31m[ocincc]\x1b[0m ${msg}`); process.exit(1); }

function sh(cmd, opts = {}) {
  return spawnSync(cmd, { shell: true, stdio: opts.inherit ? "inherit" : "pipe", ...opts });
}

function ask(question) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  return new Promise((res) => rl.question(question, (a) => { rl.close(); res(a.trim()); }));
}

async function main() {
  if (process.platform === "win32") fail("Windows is not supported yet. Use WSL.");
  if (!["darwin", "linux"].includes(process.platform)) fail(`unsupported platform: ${process.platform}`);

  const args = process.argv.slice(2);
  let keyArg = null;
  const kIdx = args.indexOf("--key");
  if (kIdx !== -1 && args[kIdx + 1]) keyArg = args[kIdx + 1];

  // deps
  for (const dep of ["python3", "curl", "claude"]) {
    if (sh(`command -v ${dep}`).status !== 0)
      fail(`missing dependency: ${dep} — install it first${dep === "claude" ? " (https://claude.com/claude-code)" : ""}`);
  }

  // api key
  fs.mkdirSync(DIR, { recursive: true });
  let key = keyArg || process.env.ZEN_API_KEY;
  if (!key && fs.existsSync(ENV_FILE)) {
    key = (fs.readFileSync(ENV_FILE, "utf8").match(/ZEN_API_KEY=(\S+)/) || [])[1];
  }
  if (!key) {
    log("OpenCode Zen API key required (free: https://opencode.ai/auth — no credit card needed)");
    key = await ask("Paste your API key: ");
  }
  if (!key || !key.startsWith("sk-")) fail("invalid API key");
  fs.writeFileSync(ENV_FILE, `ZEN_API_KEY=${key}\n`, { mode: 0o600 });

  // launcher
  fs.copyFileSync(LAUNCHER_SRC, LAUNCHER_DST);
  fs.chmodSync(LAUNCHER_DST, 0o755);

  // symlink into PATH
  const binLink = "/usr/local/bin/zen-claude";
  try {
    fs.rmSync(binLink, { force: true });
    fs.symlinkSync(LAUNCHER_DST, binLink);
    log(`launcher linked at ${binLink}`);
  } catch {
    const alt = path.join(os.homedir(), ".local", "bin");
    fs.mkdirSync(alt, { recursive: true });
    fs.rmSync(path.join(alt, "zen-claude"), { force: true });
    fs.symlinkSync(LAUNCHER_DST, path.join(alt, "zen-claude"));
    log(`launcher linked at ${path.join(alt, "zen-claude")} (make sure it is on your PATH)`);
  }

  // venv + litellm (skip if present)
  const litellmBin = path.join(DIR, "venv", "bin", "litellm");
  if (!fs.existsSync(litellmBin)) {
    log("installing litellm proxy (one-time, may take a few minutes)...");
    let r = sh(`python3 -m venv "${path.join(DIR, "venv")}"`, { inherit: true });
    if (r.status !== 0) fail("failed to create python venv");
    r = sh(`"${path.join(DIR, "venv", "bin", "pip")}" install -q 'litellm[proxy]'`, { inherit: true });
    if (r.status !== 0) fail("failed to install litellm");
  }

  console.log(`
\x1b[32mSetup complete.\x1b[0m

Usage:
  zen-claude                 interactive model picker, then starts Claude Code
  zen-claude --model <id>    skip the picker
  zen-claude --stop-proxy    stop the background proxy
  zen-claude --logs          tail proxy logs

Your normal \`claude\` command is untouched.
Free models rotate; the list refreshes automatically each launch.
`);

  // offer immediate start
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const ans = await new Promise((res) => rl.question("Start zen-claude now? [Y/n] ", (a) => { rl.close(); res(a.trim().toLowerCase()); }));
  if (ans !== "n") {
    const child = spawnSync(LAUNCHER_DST, [], { stdio: "inherit" });
    process.exit(child.status ?? 0);
  }
}

main().catch((e) => fail(e.message));

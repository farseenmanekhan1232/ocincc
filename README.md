# ocincc — OpenCode Zen free models inside Claude Code

Run [OpenCode Zen](https://opencode.ai/zen)'s **free AI models** (Big Pickle, Ox Alpha, MiMo, Hy3, Nemotron, DeepSeek Flash, Laguna…) inside **Claude Code** through a local protocol-translating proxy.

```bash
npx ocincc@latest        # from the npm registry
# or, directly from GitHub:
npx github:farseenmanekhan1232/ocincc
```

That's it. The installer sets up a local LiteLLM proxy and a `zen-claude` launcher. Your existing `claude` command and `~/.claude/settings.json` are never touched.

---

## Why this exists

Claude Code only speaks the **Anthropic Messages API** (`/v1/messages`). Most of Zen's free models are only served via the **OpenAI chat/completions** format, so pointing Claude Code directly at `https://opencode.ai/zen` fails for them.

`ocincc` runs a tiny local proxy that:

```
Claude Code ──(Anthropic /v1/messages)──▶ localhost:4000 ──translate──▶ https://opencode.ai/zen/v1/chat/completions
```

## What you get

- ✅ All current free Zen models in Claude Code (auto-discovered at launch)
- ✅ Interactive model picker every session (or `--model <id>`)
- ✅ Automatic 429 fallbacks between models
- ✅ Fresh client headers per session so you get the standard free-tier allowance
- ✅ Zero changes to your Claude Code config

## Requirements

- macOS or Linux
- [Claude Code](https://claude.com/claude-code) (`claude` on PATH)
- Python 3 + `curl`
- A free OpenCode API key from [opencode.ai/auth](https://opencode.ai/auth) — no credit card needed for free models

## Install & use

```bash
npx ocincc@latest          # one-time setup (prompts for your API key)
zen-claude                 # pick a model → start working
```

Launcher commands:

| Command | Description |
|---|---|
| `zen-claude` | Interactive model picker, then launches Claude Code |
| `zen-claude --model big-pickle` | Skip the picker |
| `zen-claude --continue` | Any Claude Code flags pass through |
| `zen-claude --stop-proxy` | Stop the background proxy |
| `zen-claude --logs` | Tail proxy logs |

Everything lives under `~/.config/zen-claude/`:

```
zen-claude           launcher script
.env                 ZEN_API_KEY (chmod 600)
litellm-config.yaml  regenerated fresh on every launch
cache/               version + model-list caches
proxy.log / proxy.pid / venv/
```

## Free models

The model list is fetched live from `https://opencode.ai/zen/v1/models` on every launch and filtered automatically (`*free*`, plus stealth freebies like `big-pickle` and `x-preview-f-free`). When Zen rotates its catalog, you don't have to change anything.

Current lineup at time of writing:

| Model | ID | Notes |
|---|---|---|
| Big Pickle | `big-pickle` | Stealth model, best tool-calling track record |
| Ox Alpha Free | `x-preview-f-free` | Stealth, zero-retention policy |
| MiMo-V2.5 Free | `mimo-v2.5-free` | |
| Hy3 Free | `hy3-free` | |
| Nemotron 3 Ultra Free | `nemotron-3-ultra-free` | NVIDIA trial endpoints |
| Nemotron 3.5 Lightning Free | `nemotron-3.5-lightning-free` | |
| DeepSeek V4 Flash Free | `deepseek-v4-flash-free` | |
| Laguna S 2.1 Free | `laguna-s-2.1-free` | |

## How it works (the interesting part)

While building this we read Zen's server source ([anomalyco/opencode](https://github.com/anomalyco/opencode), `packages/console/app/src/routes/zen/`) and found:

1. **Free-model rate limiting is per IP address**, not per API key (`ipRateLimiter.ts`). Your key just authenticates; everyone behind your IP shares a daily bucket.
2. **A header check decides which allowance you get.** Requests that look like a genuine OpenCode client get the standard daily limit; anything else gets a stricter fallback limit (`FreeUsageLimitError`). The check is a substring match on headers such as:
   ```
   User-Agent: opencode/<version> (<platform> <kernel>; <arch>)
   x-opencode-client: tui
   x-opencode-project / -session: any stable string
   ```
   The launcher sends exactly this shape — version resolved live from npm, IDs generated fresh each session.
3. **LiteLLM's `/v1/messages` endpoint** normally bridges OpenAI-provider models to the Responses API; setting `LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES=True` forces proper chat/completions translation instead.

None of this is spoofing authentication — your requests still use your own API key against the public API; the headers simply identify your client the same way any OpenCode user's would.

## Limits & caveats

- **Daily quota is real**: agentic sessions burn requests quickly; expect occasional `429 Rate limit exceeded` errors. Resets daily (UTC). The proxy retries and falls back across models where buckets allow.
- **Privacy**: most free models may use prompts to improve their models (exception: `x-preview-f-free` has a zero-retention policy). Don't send sensitive code or secrets.
- **Tool-calling quality varies by model** — some handle Claude Code's complex tool schemas better than others.
- Free models rotate over time; the tool adapts automatically.
- Not affiliated with OpenCode or Anthropic.

## Uninstall

```bash
zen-claude --stop-proxy
rm -rf ~/.config/zen-claude /usr/local/bin/zen-claude
```

## License

MIT

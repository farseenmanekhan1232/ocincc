#!/usr/bin/env bash
set -euo pipefail

DIR="${HOME}/.config/zen-claude"
VENV="$DIR/venv"
CONFIG="$DIR/litellm-config.yaml"
LOG="$DIR/proxy.log"
PIDFILE="$DIR/proxy.pid"
CACHE="$DIR/cache"
ENV_FILE="$DIR/.env"
PORT="${ZEN_PROXY_PORT:-4000}"
UPSTREAM="https://opencode.ai/zen/v1"
MASTER_KEY="sk-zen-local"
DEFAULT_VERSION="1.18.23"

mkdir -p "$CACHE"

log() { printf '\033[2m[zen]\033[0m %s\n' "$*"; }
die() { printf '\033[31m[zen]\033[0m %s\n' "$*" >&2; exit 1; }

# ---------- commands ----------
case "${1:-}" in
  --stop-proxy)
    if [ -f "$PIDFILE" ] && kill "$(cat "$PIDFILE")" 2>/dev/null; then
      rm -f "$PIDFILE"; log "proxy stopped"
    else
      log "proxy not running"
    fi
    exit 0 ;;
  --logs) tail -n 100 -f "$LOG" ;;
esac

# ---------- api key ----------
if [ -f "$ENV_FILE" ]; then set -a; source "$ENV_FILE"; set +a; fi
: "${ZEN_API_KEY:?set ZEN_API_KEY in $ENV_FILE}"

# ---------- bootstrap litellm ----------
if [ ! -x "$VENV/bin/litellm" ]; then
  log "installing litellm (first run, one-time)..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install -q 'litellm[proxy]'
fi

# ---------- dynamic version (cached 24h) ----------
VER_CACHE="$CACHE/version.txt"
if [ ! -f "$VER_CACHE" ] || [ -n "$(find "$VER_CACHE" -mtime +1 2>/dev/null)" ]; then
  npm view opencode-ai version >"$VER_CACHE.tmp" 2>/dev/null && mv "$VER_CACHE.tmp" "$VER_CACHE" || echo "$DEFAULT_VERSION" > "$VER_CACHE"
fi
OC_VER="$(cat "$VER_CACHE" 2>/dev/null || echo "$DEFAULT_VERSION")"

KERNEL="$(uname -r)"
PLATFORM="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
[ "$ARCH" = "x86_64" ] && ARCH="x64"
[ "$ARCH" = "aarch64" ] && ARCH="arm64"
UA="opencode/${OC_VER} (${PLATFORM} ${KERNEL}; ${ARCH})"

# ---------- fresh ids per session ----------
rand_hex() { openssl rand -hex "$1" 2>/dev/null || head -c "$(( $1 * 2 ))" /dev/urandom | od -An -tx1 | tr -d ' \n'; }
PROJ_ID="$(rand_hex 12)"
SES_ID="$(rand_hex 16)"

# ---------- live free-model list (cached 1h) ----------
MODELS_CACHE="$CACHE/models.txt"
if [ ! -f "$MODELS_CACHE" ] || [ -n "$(find "$MODELS_CACHE" -mmin +60 2>/dev/null)" ]; then
  curl -sf "$UPSTREAM/models" -H "Authorization: Bearer $ZEN_API_KEY" \
    | python3 -c '
import json, sys
ids = [m["id"] for m in json.load(sys.stdin).get("data", [])]
extra = {"big-pickle", "x-preview-f-free"}
excluded = {"muse-spark-1.2-contributor-free"}   # responses-only backend
free = sorted(i for i in ids if ("free" in i or i in extra) and i not in excluded)
print("\n".join(free))
' >"$MODELS_CACHE.tmp" 2>/dev/null && mv "$MODELS_CACHE.tmp" "$MODELS_CACHE" \
    || die "could not fetch model list (cached copy unavailable)"
fi
MODELS=()
while IFS= read -r line; do
  [ -n "$line" ] && MODELS+=("$line")
done < "$MODELS_CACHE"
[ ${#MODELS[@]} -gt 0 ] || die "no free models found"
log "free models available: ${MODELS[*]}"

# ---------- live context-window sizes (cached 24h) ----------
CTX_CACHE="$CACHE/context.txt"
if [ ! -f "$CTX_CACHE" ] || [ -n "$(find "$CTX_CACHE" -mtime +1 2>/dev/null)" ]; then
  curl -sf -m 30 https://models.dev/api.json \
    | python3 -c '
import json, sys
d = json.load(sys.stdin)
oc = d.get("opencode", {}).get("models", {})
for mid, info in oc.items():
    ctx = (info.get("limit") or {}).get("context")
    if ctx:
        print(f"{mid}\t{ctx}")
' >"$CTX_CACHE.tmp" 2>/dev/null && mv "$CTX_CACHE.tmp" "$CTX_CACHE" || true
fi

# ---------- generate config ----------
python3 - "$CONFIG" "$UA" "$PROJ_ID" "$SES_ID" "$PORT" <<'PYEOF'
import os, sys

config_path, ua, proj_id, ses_id, port = sys.argv[1:6]
models = [l for l in open(os.path.expanduser("~/.config/zen-claude/cache/models.txt")).read().splitlines() if l]

headers = {
    "User-Agent": ua,
    "x-opencode-client": "tui",
    "x-opencode-project": proj_id,
    "x-opencode-session": f"ses_{ses_id}",
}

def model_entry(name):
    return f"""  - model_name: {name}
    litellm_params:
      model: openai/{name}
      api_base: https://opencode.ai/zen/v1
      api_key: os.environ/ZEN_API_KEY
      drop_params: true
      extra_headers:
        User-Agent: "{headers['User-Agent']}"
        x-opencode-client: tui
        x-opencode-project: "{headers['x-opencode-project']}"
        x-opencode-session: "{headers['x-opencode-session']}"
"""

body = "model_list:\n" + "\n".join(model_entry(m) for m in models)
fallbacks = [m for m in models if m not in ("big-pickle",)][:4]
body += f"""
litellm_settings:
  num_retries: 2
  request_timeout: 300
  default_fallbacks: {fallbacks}
"""
open(config_path, "w").write(body)
PYEOF

# ---------- restart proxy with fresh config ----------
if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null && sleep 0.5; rm -f "$PIDFILE"; fi
lsof -ti :"$PORT" 2>/dev/null | xargs kill 2>/dev/null && sleep 0.5 || true

log "starting proxy on :$PORT ..."
nohup env ZEN_API_KEY="$ZEN_API_KEY" \
  LITELLM_MASTER_KEY="$MASTER_KEY" \
  LITELLM_USE_CHAT_COMPLETIONS_URL_FOR_ANTHROPIC_MESSAGES="True" \
  "$VENV/bin/litellm" --config "$CONFIG" --port "$PORT" >"$LOG" 2>&1 &
echo $! > "$PIDFILE"

for i in $(seq 1 30); do
  curl -sf "http://127.0.0.1:$PORT/health/liveliness" >/dev/null 2>&1 && break
  [ $i -eq 30 ] && die "proxy failed to start — see $LOG"
  sleep 1
done
log "proxy ready"

# ---------- model selection ----------
MODEL=""
ARGS=()
prev=""
for a in "$@"; do
  if [ "$prev" = "--model" ]; then MODEL="$a"; elif [ "$a" != "--model" ]; then ARGS+=("$a"); fi
  prev="$a"
done

if [ -z "$MODEL" ]; then
  echo
  echo "Select a model:"
  i=1
  for m in "${MODELS[@]}"; do printf '  %2d) %s\n' "$i" "$m"; i=$((i+1)); done
  printf '  %2d) %s\n' "$(( ${#MODELS[@]} + 1 ))" "(type any other model id)"
  printf '\nChoice [%s]: ' "${MODELS[0]}"
  read -r CHOICE
  if [[ "$CHOICE" =~ ^[0-9]+$ ]]; then
    [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le ${#MODELS[@]} ] && MODEL="${MODELS[$((CHOICE-1))]}" || MODEL="${MODELS[0]}"
  elif [ -n "$CHOICE" ]; then
    MODEL="$CHOICE"
  else
    MODEL="${MODELS[0]}"
  fi
fi

log "model: $MODEL"

# ---------- context window ----------
export CLAUDE_CODE_MAX_CONTEXT_TOKENS
if [ -f "$CTX_CACHE" ]; then
  CTX="$(awk -F'\t' -v m="$MODEL" '$1 == m {print $2}' "$CTX_CACHE")"
  if [ -n "$CTX" ]; then
    export CLAUDE_CODE_MAX_CONTEXT_TOKENS="$CTX"
    log "context window: $CTX tokens"
  fi
fi

# ---------- launch ----------
export ANTHROPIC_BASE_URL="http://127.0.0.1:$PORT"
export ANTHROPIC_AUTH_TOKEN="$MASTER_KEY"
export ANTHROPIC_MODEL="$MODEL"
exec claude ${ARGS[@]+"${ARGS[@]}"}

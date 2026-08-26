#!/usr/bin/env bash
# Serve a local GGUF via llama-server as an OpenAI-compatible /v1 API.
# Verified on a 64GB Apple-Silicon Mac mini (unsloth llama.cpp build 10360).
# Usage: scripts/serve-local.sh   (env overrides: MODEL PORT CTX NP ALIAS)
set -euo pipefail
LLAMA_BIN="$HOME/.unsloth/llama.cpp/build/bin"
[ -x "$LLAMA_BIN/llama-server" ] || LLAMA_BIN="$HOME/.unsloth/llama.cpp"

MODEL="${MODEL:-$HOME/.cache/huggingface/hub/models--unsloth--Qwen3.6-35B-A3B-MTP-GGUF/snapshots/5bc3e238d916f48a861bac2f8a1990a0e9b7e98d/Qwen3.6-35B-A3B-UD-Q4_K_XL.gguf}"
HOST="${HOST:-127.0.0.1}"
PORT="${PORT:-8000}"
CTX="${CTX:-16384}"      # window; on 64GB keep <=32k to leave headroom
NP="${NP:-2}"            # parallel slots
ALIAS="${ALIAS:-qwen3.6-35b-a3b}"

# The comment below is a real gotcha (DYLD_LIBRARY_PATH is flagged CRITICAL by
# Hermes' security scanner). Running from build/bin resolves libggml-*.dylib via
# @rpath; only uncomment the export if the loader can't find them.
# export DYLD_LIBRARY_PATH="$LLAMA_BIN"

cd "$LLAMA_BIN" || exit 1
echo "Serving $MODEL on $HOST:$PORT (ctx=$CTX, slots=$NP, alias=$ALIAS)"
exec ./llama-server -m "$MODEL" --host "$HOST" --port "$PORT" \
  -c "$CTX" -np "$NP" --alias "$ALIAS"

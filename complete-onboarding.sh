#!/usr/bin/env bash
# Re-run OpenRAG onboarding from the terminal (setup.sh already does this;
# use this standalone script if you changed models in .env afterwards).
#
# Why it exists: onboarding state is stored server-side and gates the UI,
# so provider/model values in .env alone never finish onboarding — the
# POST below has to happen once. It reads CHAT_MODEL / EMBED_MODEL /
# OLLAMA_ENDPOINT from this repo's .env (same defaults as setup.sh).
#
# Remember: after editing models, recreate the stack first so the
# backend picks up the new env:
#   cd openrag && docker compose up -d --force-recreate && cd ..
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }
CHAT_MODEL="${CHAT_MODEL:-gemma3:12b}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
OLLAMA_ENDPOINT="${OLLAMA_ENDPOINT:-http://host.docker.internal:11434}"
BASE_URL="http://localhost:${FRONTEND_PORT}"

echo "Completing onboarding at $BASE_URL:"
echo "  llm:       ollama / $CHAT_MODEL"
echo "  embedding: ollama / $EMBED_MODEL"
curl -sf -X POST "$BASE_URL/api/onboarding" \
  -H 'Content-Type: application/json' \
  -d "{\"llm_provider\":\"ollama\",\"llm_model\":\"$CHAT_MODEL\",\"embedding_provider\":\"ollama\",\"embedding_model\":\"$EMBED_MODEL\",\"ollama_endpoint\":\"$OLLAMA_ENDPOINT\"}"
echo
curl -s -X POST "$BASE_URL/api/onboarding/state" -H 'Content-Type: application/json' -d '{"current_step":4}' >/dev/null 2>&1 || true
echo "Provider health:"
curl -s "$BASE_URL/api/provider/health" || true
echo
echo "Done. Refresh $BASE_URL — the wizard should be gone."

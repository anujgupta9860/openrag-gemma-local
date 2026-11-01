#!/usr/bin/env bash
# Smoke test for the local Ollama + OpenRAG stack.
# Checks each layer separately so a failure says WHICH layer broke:
#   1. Ollama answers and has both models pulled
#   2. OpenRAG UI is up
#   3. OpenRAG provider health (backend -> Ollama wiring)
#   4. Retrieval endpoint responds (empty results are fine before ingest)
set -uo pipefail
cd "$(dirname "$0")"
[ -f .env ] && { set -a; . ./.env; set +a; }
CHAT_MODEL="${CHAT_MODEL:-llama3.1:8b}"
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text:latest}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
BASE_URL="http://localhost:${FRONTEND_PORT}"
FAIL=0

check() { # $1=label $2=0/1
  if [ "$2" -eq 0 ]; then echo "  PASS  $1"; else echo "  FAIL  $1"; FAIL=1; fi
}

echo "Layer 1: Ollama"
TAGS="$(curl -s http://127.0.0.1:11434/api/tags)"
[ -n "$TAGS" ]; check "ollama responding on :11434" $?
echo "$TAGS" | grep -q "${CHAT_MODEL%%:*}" ; check "chat model pulled ($CHAT_MODEL)" $?
echo "$TAGS" | grep -q "${EMBED_MODEL%%:*}" ; check "embedding model pulled ($EMBED_MODEL)" $?

echo "Layer 2: OpenRAG UI"
curl -sf -o /dev/null "$BASE_URL"; check "UI up at $BASE_URL" $?

echo "Layer 3: Provider health (backend -> Ollama)"
HEALTH="$(curl -s "$BASE_URL/api/provider/health")"
echo "  $HEALTH"
echo "$HEALTH" | grep -qi "ollama"; check "provider is ollama" $?

echo "Layer 4: Retrieval endpoint"
CODE="$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE_URL/api/search" -H 'Content-Type: application/json' -d '{"query":"smoke test"}')"
[ "$CODE" = "200" ] || [ "$CODE" = "422" ]; check "POST /api/search responded (http $CODE; 200 = ok, 422 = route exists, payload drifted)" $?

if [ "$FAIL" -eq 0 ]; then
  echo "All layers green. Open $BASE_URL and chat."
else
  echo "Some layers failed — the FAIL lines above name the broken layer."
  exit 1
fi

#!/usr/bin/env bash
# Stop the local stack.
#   ./stop.sh          stop OpenRAG containers + the ollama serve we started
#   ./stop.sh --wipe   also delete docker volumes (OpenSearch data, uploads)
#                      and the cloned ./openrag directory. Models stay in
#                      Ollama's own storage (~/.ollama) — remove those with
#                      `ollama rm <model>`.
set -euo pipefail
cd "$(dirname "$0")"

if [ -d openrag ]; then
  if [ "${1:-}" = "--wipe" ]; then
    ( cd openrag && docker compose down -v ) || true
    rm -rf openrag
    echo "Wiped containers, volumes and ./openrag."
  else
    ( cd openrag && docker compose down ) || true
  fi
fi
if [ -f ollama.pid ]; then
  kill "$(cat ollama.pid)" 2>/dev/null || true
  rm -f ollama.pid
  echo "Stopped the ollama serve started by setup.sh (if it was still running)."
fi
echo "Stopped."

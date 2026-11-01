#!/usr/bin/env bash
# End-to-end local setup: Ollama + OpenRAG, fully local models.
#
# One command takes a Mac (Apple Silicon recommended) from nothing to a
# working OpenRAG chat UI at http://localhost:3000, fully local:
#
#   ./setup.sh
#
# What it does, in order:
#   1. Checks prerequisites (git, Docker running) and installs Ollama if
#      it is missing (Homebrew if available, else the official installer).
#   2. Starts Ollama (bound to 0.0.0.0 so the OpenRAG backend container can
#      reach it via host.docker.internal) and pulls the chat + embedding
#      models (default: llama3.1:8b + nomic-embed-text:latest). The chat model
#      must be one Ollama flags as tool-capable: OpenRAG's onboarding
#      validates tool calling and rejects models without it (Ollama
#      0.40.13 does not flag gemma3 as tools-capable — verified).
#   3. Clones OpenRAG at a pinned tag into ./openrag (git-ignored) and
#      writes its .env for the Ollama provider. Also installs the
#      vendored current-generation flow templates
#      (openrag-flows-current/) over the checkout's flows/ — see the
#      step-3 comment for why the pinned tag's own flows cannot be used
#      with the backend image this compose pulls.
#   4. Applies the single-node OpenSearch fix (compose override) that a
#      local 1-node cluster needs, generates the required Langflow
#      superuser password, and starts the stack with docker compose.
#   5. Completes OpenRAG onboarding server-side (no UI wizard, no API
#      keys anywhere) and verifies provider health.
#   6. Runs a smoke test and prints the chat URL.
#
# Idempotent: re-running is safe and resumes where it left off.
# Knobs live in .env (see .env.example): CHAT_MODEL, EMBED_MODEL,
# OPENRAG_TAG, FRONTEND_PORT.
set -euo pipefail
cd "$(dirname "$0")"

# ---------------------------------------------------------------- config
[ -f .env ] && { set -a; . ./.env; set +a; }
OPENRAG_TAG="${OPENRAG_TAG:-v0.3.0}"
CHAT_MODEL="${CHAT_MODEL:-llama3.1:8b}"
# The :latest tag is load-bearing, not cosmetic: Langflow registers Ollama
# models under their full name:tag (nomic-embed-text:latest), and OpenRAG's
# flow patcher matches the configured embedding model name exactly. With a
# bare "nomic-embed-text" the patcher logs "Model nomic-embed-text not found
# for provider Ollama", leaves every Langflow flow on its OpenAI default,
# and document ingestion fails demanding an OpenAI API key.
EMBED_MODEL="${EMBED_MODEL:-nomic-embed-text:latest}"
FRONTEND_PORT="${FRONTEND_PORT:-3000}"
BASE_URL="http://localhost:${FRONTEND_PORT}"
OLLAMA_HOST_PORT="11434"
OLLAMA_LOCAL="http://127.0.0.1:${OLLAMA_HOST_PORT}"
# From inside the backend container, the host's Ollama is here:
OLLAMA_ENDPOINT="${OLLAMA_ENDPOINT:-http://host.docker.internal:${OLLAMA_HOST_PORT}}"
UPSTREAM_DIR="openrag"

step() { printf '\n=== %s ===\n' "$*"; }
ok()   { printf '  ok: %s\n' "$*"; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

get_env() { grep -E "^$1=" "$2" 2>/dev/null | head -1 | cut -d= -f2-; }
set_env() { # $1=file $2=key $3=value
  if grep -qE "^$2=" "$1" 2>/dev/null; then
    sed -i.bak "s|^$2=.*|$2=$3|" "$1" && rm -f "$1.bak"
  else
    echo "$2=$3" >> "$1"
  fi
}

# ---------------------------------------------------------------- 1. prereqs
step "1/6 Prerequisites"
command -v git >/dev/null 2>&1 || die "git not found. Install Xcode Command Line Tools: xcode-select --install"
docker info >/dev/null 2>&1 || die "Docker is not running. Start Docker Desktop, wait for it to settle, re-run."
ok "git and Docker are ready"

if ! command -v ollama >/dev/null 2>&1; then
  echo "  Ollama not found — installing..."
  if command -v brew >/dev/null 2>&1; then
    brew install ollama
  else
    curl -fsSL https://ollama.com/install.sh | sh
  fi
  command -v ollama >/dev/null 2>&1 || die "Ollama install did not produce an ollama binary. Install from https://ollama.com/download and re-run."
fi
ok "ollama: $(ollama --version 2>/dev/null | head -1)"

# ---------------------------------------------------------------- 2. ollama + models
step "2/6 Ollama server + models (chat: $CHAT_MODEL, embed: $EMBED_MODEL)"
if ! curl -sf -o /dev/null "$OLLAMA_LOCAL/api/tags"; then
  echo "  Starting ollama serve (OLLAMA_HOST=0.0.0.0:${OLLAMA_HOST_PORT})..."
  OLLAMA_HOST="0.0.0.0:${OLLAMA_HOST_PORT}" nohup ollama serve > ollama.log 2>&1 &
  echo $! > ollama.pid
  for i in $(seq 1 30); do
    curl -sf -o /dev/null "$OLLAMA_LOCAL/api/tags" && break
    sleep 2
  done
fi
curl -sf -o /dev/null "$OLLAMA_LOCAL/api/tags" || die "Ollama is not responding at $OLLAMA_LOCAL. Check ollama.log."
ok "Ollama is up at $OLLAMA_LOCAL"

echo "  Pulling $CHAT_MODEL (one-time download)..."
ollama pull "$CHAT_MODEL"
echo "  Pulling $EMBED_MODEL..."
ollama pull "$EMBED_MODEL"
ok "models ready"

# OpenRAG onboarding validates that the chat model supports tool
# calling, and rejects it otherwise ("<model> does not support tools").
# Ollama reports capabilities per model — fail HERE with a clear
# message instead of dying opaquely at the onboarding POST in step 5.
SHOW="$(curl -s "$OLLAMA_LOCAL/api/show" -d "{\"name\":\"$CHAT_MODEL\"}")"
if ! printf '%s' "$SHOW" | grep -q '"tools"'; then
  die "Chat model '$CHAT_MODEL' is not flagged tool-capable by Ollama, and OpenRAG onboarding will reject it. Pick a tools-capable model (e.g. llama3.1:8b, qwen2.5:7b, qwen3:8b): set CHAT_MODEL in .env and re-run."
fi
ok "chat model is tool-capable (OpenRAG onboarding requirement)"

# ---------------------------------------------------------------- 3. openrag clone + env
step "3/6 OpenRAG ($OPENRAG_TAG) + configuration"
if [ ! -d "$UPSTREAM_DIR/.git" ]; then
  git clone https://github.com/langflow-ai/openrag.git "$UPSTREAM_DIR"
fi
git -C "$UPSTREAM_DIR" fetch --tags --quiet || true
git -C "$UPSTREAM_DIR" checkout --quiet "$OPENRAG_TAG"
[ -f "$UPSTREAM_DIR/.env" ] || cp "$UPSTREAM_DIR/.env.example" "$UPSTREAM_DIR/.env" 2>/dev/null || touch "$UPSTREAM_DIR/.env"

UENV="$UPSTREAM_DIR/.env"
set_env "$UENV" LLM_PROVIDER ollama
set_env "$UENV" LLM_MODEL "$CHAT_MODEL"
set_env "$UENV" EMBEDDING_PROVIDER ollama
set_env "$UENV" EMBEDDING_MODEL "$EMBED_MODEL"
set_env "$UENV" OLLAMA_ENDPOINT "$OLLAMA_ENDPOINT"
[ -n "$(get_env FRONTEND_PORT "$UENV")" ] || set_env "$UENV" FRONTEND_PORT "$FRONTEND_PORT"

# OpenSearch admin password is required by upstream's compose and must
# meet complexity rules. Generate once, keep in the (git-ignored) .env.
if [ -z "$(get_env OPENSEARCH_PASSWORD "$UENV")" ]; then
  set_env "$UENV" OPENSEARCH_PASSWORD "$(openssl rand -base64 12)Aa1!"
  echo "  Generated OPENSEARCH_PASSWORD into $UENV (local only)."
fi

# Langflow superuser is REQUIRED: with empty values Langflow exits, the
# backend dies waiting for it, and the UI hangs on "Starting OpenRAG...".
# Generate once and save the credentials next to this script (git-ignored).
[ -n "$(get_env LANGFLOW_SUPERUSER "$UENV")" ] || set_env "$UENV" LANGFLOW_SUPERUSER langflow
if [ -z "$(get_env LANGFLOW_SUPERUSER_PASSWORD "$UENV")" ]; then
  LF_PW="$(openssl rand -base64 12)Aa1!"
  set_env "$UENV" LANGFLOW_SUPERUSER_PASSWORD "$LF_PW"
  printf 'Langflow superuser (auto-generated by setup.sh)\nusername: langflow\npassword: %s\n' "$LF_PW" > langflow-credentials.txt
  chmod 600 langflow-credentials.txt
  echo "  Generated Langflow superuser password -> langflow-credentials.txt (git-ignored)."
fi

# Single-node OpenSearch: current backend images gate startup on a
# node-count check that defaults to a 3-node cluster
# (OPENSEARCH_EXPECTED_DATA_NODE_COUNT / _CLUSTER_MANAGER_COUNT /
# _COORDINATING_NODE_COUNT, all default 3). On a single-node local
# cluster the check never passes and the UI hangs on "Starting
# OpenRAG...". Upstream's compose never passes these through from .env,
# so inject them via a compose override: set the counts a single node
# actually has, and disable the gate outright (upstream settings.py:
# "set to false on small/single-node clusters").
if ! grep -q "OPENSEARCH_NODE_COUNT_CHECK_ENABLED" "$UPSTREAM_DIR/docker-compose.override.yml" 2>/dev/null; then
  cat > "$UPSTREAM_DIR/docker-compose.override.yml" <<'EOF'
services:
  openrag-backend:
    environment:
      OPENSEARCH_EXPECTED_DATA_NODE_COUNT: "1"
      OPENSEARCH_EXPECTED_CLUSTER_MANAGER_COUNT: "1"
      OPENSEARCH_EXPECTED_COORDINATING_NODE_COUNT: "0"
      OPENSEARCH_NODE_COUNT_CHECK_ENABLED: "false"
EOF
  echo "  Wrote docker-compose.override.yml (single-node OpenSearch fix)."
fi

# Langflow ships with custom components blocked, but OpenRAG's ingest
# flow is built from custom components ("Create Data" /
# AdvancedDynamicFormBuilder), so every document ingest fails with
# "Flow build blocked: custom components are not allowed" until
# Langflow is told to allow them. Upstream's compose doesn't set this;
# add it via the same override (separate guard so checkouts that
# already have the OpenSearch block still pick this up).
if ! grep -q "LANGFLOW_ALLOW_CUSTOM_COMPONENTS" "$UPSTREAM_DIR/docker-compose.override.yml" 2>/dev/null; then
  cat >> "$UPSTREAM_DIR/docker-compose.override.yml" <<'EOF'
  langflow:
    environment:
      LANGFLOW_ALLOW_CUSTOM_COMPONENTS: "true"
EOF
  echo "  Added Langflow custom-components fix to docker-compose.override.yml."
fi
# Flow templates: the pinned checkout's flows/ are an older generation
# than the backend image this compose pulls (${OPENRAG_VERSION:-latest}).
# The current backend converts documents itself (its own Docling phase)
# and hands the flow a docling task id to fetch results by; the v0.3.0
# ingestion flow instead waits for a file upload into Langflow that this
# backend never performs (it calls the flow with file_paths=[]), so
# DoclingRemote returns an empty DataFrame and ingestion dies three
# hops later with "Column 'doc' not found in DataFrame. Available
# columns: []" — verified end-to-end on the Mac mini install,
# 2026-11-01. The repo therefore vendors the flow templates matching
# the backend image (openrag-flows-current/, from upstream main
# @ f00c103, 2026-10-30; same flow IDs, current components) and
# installs them over the checkout's flows/ before the stack starts.
# Step 4b handles installs whose Langflow already stored the old ones.
if [ -d openrag-flows-current ]; then
  cp openrag-flows-current/*.json "$UPSTREAM_DIR/flows/"
  echo "  Installed current-generation flow templates over the $OPENRAG_TAG checkout's flows/."
fi
ok "OpenRAG configured for Ollama / $CHAT_MODEL"

# ---------------------------------------------------------------- 4. start stack
step "4/6 Starting the OpenRAG stack (first start can take a few minutes)"
( cd "$UPSTREAM_DIR" && docker compose up -d )
echo "  Waiting for $BASE_URL ..."
for i in $(seq 1 72); do
  if curl -sf -o /dev/null "$BASE_URL"; then break; fi
  sleep 5
done
curl -sf -o /dev/null "$BASE_URL" || die "UI did not come up at $BASE_URL. Inspect: cd $UPSTREAM_DIR && docker compose logs -f openrag-backend"
ok "UI responding at $BASE_URL"

# ---------------------------------------------------------------- 4b. refresh stored flows (upgrade path)
# Langflow stores imported flows in its own database and does not
# re-read changed files for flow IDs it already has, so an install that
# previously imported the old-generation flows would keep running them
# even with the vendored templates in flows/. Detect stored flows whose
# node structure differs from the vendored templates (a generation
# check — model patching changes template values, never node types),
# delete just those via the Langflow API, and restart Langflow so it
# imports the vendored files. No-op on first installs and on installs
# already current; best effort throughout (never fail setup over it).
step "4b/6 Checking Langflow for stale stored flows"
if [ -f langflow-credentials.txt ] && command -v python3 >/dev/null 2>&1; then
  LF_PW="$(grep -i '^password:' langflow-credentials.txt | head -1 | sed 's/^[^:]*: *//')"
  REFRESH_PY="$(mktemp)"
  cat > "$REFRESH_PY" <<'PYEOF'
import glob, json, os, urllib.parse, urllib.request

base = "http://localhost:7860"
pw = os.environ.get("LF_PW", "")
if not pw:
    print("FLOW_REFRESH_DELETED=0")
    raise SystemExit(0)
try:
    data = urllib.parse.urlencode({"username": "langflow", "password": pw}).encode()
    tok = json.load(urllib.request.urlopen(base + "/api/v1/login", data=data, timeout=10))["access_token"]
except Exception:
    print("FLOW_REFRESH_DELETED=0")
    raise SystemExit(0)
hdr = {"Authorization": "Bearer " + tok}

def node_signature(flow):
    import hashlib

    sig = []
    for n in (flow.get("data") or {}).get("nodes") or []:
        tpl = ((n.get("data") or {}).get("node") or {}).get("template") or {}
        code = (tpl.get("code") or {}).get("value") or ""
        code_hash = hashlib.sha1(code.encode()).hexdigest()[:12] if code else ""
        # Template field values are part of the signature too: a vendored
        # change may be a plain value flip (e.g. the Agent node Stream
        # toggle) with no code or structure change. Values are compared
        # against the vendored template, so backend-side patching that
        # only fills runtime globals (names, not values) does not churn.
        values = {
            k: v.get("value")
            for k, v in tpl.items()
            if isinstance(v, dict) and "value" in v
        }
        values_hash = hashlib.sha1(
            json.dumps(values, sort_keys=True, default=str).encode()
        ).hexdigest()[:12]
        sig.append((n.get("id", ""), (n.get("data") or {}).get("type", ""), code_hash, values_hash))
    return sorted(sig)

deleted = 0
for path in sorted(glob.glob("openrag-flows-current/*.json")):
    try:
        vendored = json.load(open(path))
    except Exception:
        continue
    fid = vendored.get("id")
    if not fid:
        continue
    try:
        req = urllib.request.Request(base + "/api/v1/flows/" + fid, headers=hdr)
        stored = json.load(urllib.request.urlopen(req, timeout=10))
    except Exception:
        continue  # not stored yet — Langflow imports the file as-is
    if node_signature(stored) != node_signature(vendored):
        try:
            req = urllib.request.Request(base + "/api/v1/flows/" + fid, headers=hdr, method="DELETE")
            urllib.request.urlopen(req, timeout=10)
            deleted += 1
            print("  deleted stale stored flow: " + str(vendored.get("name")))
        except Exception:
            pass
print("FLOW_REFRESH_DELETED=" + str(deleted))
PYEOF
  REFRESH_OUT="$(LF_PW="$LF_PW" python3 "$REFRESH_PY" 2>/dev/null || true)"
  rm -f "$REFRESH_PY"
  printf '%s\n' "$REFRESH_OUT" | grep -v '^FLOW_REFRESH_DELETED=' || true
  if printf '%s' "$REFRESH_OUT" | grep -qE '^FLOW_REFRESH_DELETED=[1-9]'; then
    echo "  Restarting Langflow so it imports the vendored flow templates..."
    ( cd "$UPSTREAM_DIR" && docker compose restart langflow )
    for i in $(seq 1 36); do
      if curl -sf -o /dev/null "http://localhost:7860"; then break; fi
      sleep 5
    done
    curl -sf -o /dev/null "http://localhost:7860" || echo "  WARNING: Langflow is slow to return; onboarding below retries and may still succeed."
  else
    echo "  Stored flows are current (or none stored yet)."
  fi
else
  echo "  Skipped (no Langflow credentials file or no python3)."
fi

# ---------------------------------------------------------------- 5. onboarding (no wizard)
step "5/6 Completing onboarding server-side"
PAYLOAD="{\"llm_provider\":\"ollama\",\"llm_model\":\"$CHAT_MODEL\",\"embedding_provider\":\"ollama\",\"embedding_model\":\"$EMBED_MODEL\",\"ollama_endpoint\":\"$OLLAMA_ENDPOINT\"}"
ONBOARDED=""
for i in $(seq 1 24); do
  if curl -sf -X POST "$BASE_URL/api/onboarding" -H 'Content-Type: application/json' -d "$PAYLOAD" >/dev/null 2>&1; then
    ONBOARDED=1; break
  fi
  sleep 5
done
if [ -z "$ONBOARDED" ]; then
  echo "  Onboarding POST failed. Same request, without -f, to see why:"
  echo "    curl -s -X POST $BASE_URL/api/onboarding -H 'Content-Type: application/json' -d '$PAYLOAD'"
  echo "  Server response:"
  curl -s -X POST "$BASE_URL/api/onboarding" -H 'Content-Type: application/json' -d "$PAYLOAD" || true
  echo
  die "Onboarding did not complete — see the server response above."
fi
# The UI wizard reads a step counter that can lag the stored settings;
# nudge it to the final step (best effort, harmless if the route differs).
curl -s -X POST "$BASE_URL/api/onboarding/state" -H 'Content-Type: application/json' -d '{"current_step":4}' >/dev/null 2>&1 || true
echo "  Provider health:"
curl -s "$BASE_URL/api/provider/health" || true
echo
ok "onboarding complete (llm: ollama/$CHAT_MODEL, embedding: ollama/$EMBED_MODEL)"

# ---------------------------------------------------------------- 6. smoke test
step "6/6 Smoke test"
./smoke-test.sh || die "Smoke test failed — see output above."
cat <<EOF

============================================================
  Done. Your local stack is up:

    Chat UI:      $BASE_URL        <- open this and chat
    Langflow:     http://localhost:7860
    Backend docs: http://localhost:8000/docs

  Chat model:       ollama / $CHAT_MODEL
  Embedding model:  ollama / $EMBED_MODEL  (768-dim)

  Notes:
  - Chat works right now, with no documents. To ground answers in your
    own files you need document ingestion, which needs docling-serve —
    a separate host process, NOT part of the docker stack:
        cd $UPSTREAM_DIR && uv run openrag    # TUI -> Start All Services
    Then upload documents in the UI.
  - Changing EMBED_MODEL later means re-ingesting every document.
  - Stop everything with ./stop.sh   (add --wipe to also drop volumes)
============================================================
EOF

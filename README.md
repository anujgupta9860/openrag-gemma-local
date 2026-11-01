# OpenRAG, fully local (Ollama)

One setup script takes a Mac from nothing to a working
[OpenRAG](https://github.com/langflow-ai/openrag) chat UI at
**http://localhost:3000**, powered entirely by local models served by
[Ollama](https://ollama.com):

- **Chat:** `llama3.1:8b` by default — open weights, runs on your machine
- **Embeddings:** `nomic-embed-text` (768-dim)
- **No API keys, no cloud, no accounts.** Nothing leaves the machine.

One hard requirement shapes the chat-model choice: OpenRAG's onboarding
**validates tool calling**, and Ollama only flags some models as
tool-capable. Google's Gemma 3 — the original pick here — is *not* one
of them (verified on Ollama 0.40.13: onboarding fails with
"gemma3:12b does not support tools"), so it can't be the chat model
until Ollama flags it. Any tools-capable Ollama model works
(llama3.1, qwen2.5, qwen3, …); `setup.sh` checks the capability up
front and fails with a clear message instead of dying at onboarding.

## Quickstart

Prerequisite: [Docker Desktop](https://www.docker.com/products/docker-desktop/)
installed and running. Apple Silicon recommended.

```bash
git clone https://github.com/anujgupta9860/openrag-gemma-local.git
cd openrag-gemma-local
./setup.sh
```

Then open **http://localhost:3000** and chat. First run downloads the
models and container images, so it takes a while; later runs are fast.
`setup.sh` is idempotent — re-run it any time to resume or repair.

## What setup.sh does

1. **Prereqs** — checks git + Docker; installs Ollama if missing
   (Homebrew, else the official installer).
2. **Ollama** — starts `ollama serve` bound to `0.0.0.0:11434` (so the
   backend *container* can reach it via `host.docker.internal`) and pulls
   the chat + embedding models.
3. **OpenRAG** — clones upstream at a pinned tag (`v0.3.0`) into
   `./openrag/` (git-ignored; this repo is a wrapper, nothing is vendored)
   and writes its `.env` for the Ollama provider.
4. **The two local-run fixes** (both learned the hard way):
   - *Single-node OpenSearch:* the backend refuses to serve until the
     cluster matches its expected node counts, which default to a
     3-node cluster (data / cluster-manager / coordinating); a laptop
     has 1 node. Fixed via a `docker-compose.override.yml` setting the
     expected counts to 1/1/0 and `OPENSEARCH_NODE_COUNT_CHECK_ENABLED=false`
     — upstream's documented off-switch for single-node clusters
     (upstream's compose never passes these variables through from `.env`).
     Without this the UI hangs forever on "Starting OpenRAG…".
   - *Langflow superuser:* with empty credentials Langflow exits, the
     backend dies waiting for it, and the UI hangs forever on
     "Starting OpenRAG…". `setup.sh` generates a random password into the
     upstream `.env` and saves it to `langflow-credentials.txt`
     (git-ignored, mode 600).
   - Also generates a complexity-compliant `OPENSEARCH_PASSWORD`.
5. **Stack up** — `docker compose up -d`, waits for the UI.
6. **Onboarding without the wizard** — onboarding state is stored
   server-side and gates the UI, so `.env` values alone never finish it.
   `setup.sh` completes it directly:
   `POST /api/onboarding` with the Ollama provider/models/endpoint, then
   verifies `GET /api/provider/health`. (Re-runnable any time via
   `./complete-onboarding.sh`.)
7. **Smoke test** — `./smoke-test.sh` checks each layer separately
   (Ollama → UI → provider health → retrieval endpoint) so a failure
   names the broken layer.

## Chatting, and adding your documents

- **Chat works immediately**, ungrounded. Ask it anything Gemma can answer.
- **To chat over your own documents** you need ingestion, which needs
  **docling-serve** — architecturally part of OpenRAG, but a *separate
  host process*, not a container:

  ```bash
  cd openrag && uv run openrag   # TUI -> "Start All Services"
  ```

  Verify with `uv run python scripts/docling_ctl.py status`
  (want: running at 127.0.0.1:5001), then upload documents in the UI.

## Changing models

Edit `.env` (see `.env.example`), then:

```bash
ollama pull <new-model>
cd openrag && docker compose up -d --force-recreate && cd ..
./complete-onboarding.sh
```

- Chat model: any Ollama model **flagged tool-capable** — `llama3.1:8b`
  (default, proven), `qwen2.5:7b`, `qwen3:8b`, `llama3.1:70b` (needs the
  RAM). ⚠️ `gemma3:*` does **not** qualify today — Ollama doesn't flag
  it for tools, and OpenRAG onboarding rejects it.
- ⚠️ **Embedding model:** vectors are model-specific. Changing
  `EMBED_MODEL` after ingesting means **re-ingesting every document**.

## Stopping

```bash
./stop.sh          # containers down + the ollama serve started by setup
./stop.sh --wipe   # also delete volumes (index, uploads) and ./openrag
```

Ollama's model files live in `~/.ollama` and survive a wipe;
remove them with `ollama rm <model>`.

## Troubleshooting

| Symptom | Cause / fix |
|---|---|
| UI stuck on "Starting OpenRAG…" | Backend waiting on Langflow or OpenSearch. Check `cd openrag && docker compose logs -f openrag-backend`. The Langflow-password and node-count fixes above cover the known causes — make sure you started via `setup.sh`, not plain `docker compose up`. |
| Provider health says Ollama unreachable | Ollama must listen beyond localhost for the container to reach it. `setup.sh` starts it with `OLLAMA_HOST=0.0.0.0:11434`; if you started Ollama yourself (app/menu bar), it may only bind 127.0.0.1 — quit it and re-run `setup.sh`. |
| Wizard reappears in the UI | Onboarding is server-side state. Run `./complete-onboarding.sh`. |
| Chat answers with raw tool-call JSON (`{"name": "search_documents", "arguments": {...}}`) instead of answering | Ollama tool calls are flattened into plain text when the model response is **streamed** through the backend's LiteLLM gateway (both the native `ollama/` and `ollama_chat/` routes; non-streamed calls return proper `tool_calls` at every hop). The vendored agent/nudges flows therefore build their chat model with `disable_streaming: True` (see `openrag-flows-current/PROVENANCE.md`). Re-run `./setup.sh` — step 4b detects the component-code change and refreshes the stored flows. |
| Ingestion fails with "Column 'doc' not found in DataFrame. Available columns: []" | Flow/backend generation mismatch: the pinned v0.3.0 checkout's ingestion flow expects a file upload into Langflow, but the current backend image converts documents itself and hands the flow a docling task id instead — the flow's DoclingRemote gets no file and returns an empty DataFrame. Fixed in setup: the repo vendors the current-generation flow templates (`openrag-flows-current/`, see its PROVENANCE.md) and installs them over the checkout's `flows/`; step 4b also deletes stale copies already stored in Langflow's database. Re-run `./setup.sh` to apply. |
| Ingestion fails with "OpenAI API key is required" even though the provider is Ollama | A Langflow flow still has its embedding components on their OpenAI default because OpenRAG's flow patcher could not find the configured embedding model in Langflow's registry. Langflow registers Ollama models with their tag (`nomic-embed-text:latest`); the patcher matches names exactly. Keep `EMBED_MODEL=nomic-embed-text:latest` (the default) and re-run `./complete-onboarding.sh`, then confirm the flows flipped: the backend log should stop repeating "Model nomic-embed-text not found for provider Ollama". |
| Onboarding POST fails (setup step 5/6 or `complete-onboarding.sh`) | The scripts call the endpoint with `curl -sf`, which hides the reason. Re-run the same POST without `-f` to see the server's actual error: `curl -s -X POST http://localhost:3000/api/onboarding -H 'Content-Type: application/json' -d '{"llm_provider":"ollama","llm_model":"llama3.1:8b","embedding_provider":"ollama","embedding_model":"nomic-embed-text","ollama_endpoint":"http://host.docker.internal:11434"}'` (`complete-onboarding.sh` now does this automatically on failure.) |
| Chat answers are slow | You're on CPU or a big model. Drop to a smaller tools-capable model, e.g. `llama3.2:3b` (see Changing models). On Apple Silicon, make sure nothing else is holding the GPU. |
| Onboarding fails with "does not support tools" | The chat model isn't flagged tool-capable by Ollama (true of `gemma3:*` today). Switch `CHAT_MODEL` to a tools-capable model (default `llama3.1:8b`) and re-run `./setup.sh`. |
| Ingest/upload fails | docling-serve isn't running — see "adding your documents" above. It is a separate process by design. |
| Port 3000 taken | Set `FRONTEND_PORT` in `.env` and re-run `setup.sh`. |

## Layout

```
setup.sh               the whole thing, end to end
complete-onboarding.sh re-complete onboarding after a model change
smoke-test.sh          layer-by-layer health checks
stop.sh                stop / wipe
.env.example           the knobs (all optional — defaults work)
openrag/               upstream clone created by setup.sh (git-ignored)
```

## Notes

- OpenRAG is pinned to `v0.3.0` (`OPENRAG_TAG` in `.env`). Its API routes
  have moved between early versions; if you bump the tag, re-check
  `smoke-test.sh` expectations against http://localhost:8000/docs.
- Sibling project: [rag-pocs](https://github.com/anujgupta9860/rag-pocs) —
  the OpenRAG vs RAGFlow evaluation harness (shared corpus + gold queries)
  this setup was distilled from.

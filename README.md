# OpenRAG + Gemma, fully local (Ollama)

One setup script takes a Mac from nothing to a working
[OpenRAG](https://github.com/langflow-ai/openrag) chat UI at
**http://localhost:3000**, powered entirely by local models served by
[Ollama](https://ollama.com):

- **Chat:** Google's **Gemma 3** (`gemma3:12b` by default) — open weights, runs on your machine
- **Embeddings:** `nomic-embed-text` (768-dim)
- **No API keys, no cloud, no accounts.** Nothing leaves the machine.

Gemini is *not* involved: it's Google's closed, API-only family. Gemma is
the open-weights sibling, and it's the one Ollama can serve.

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
     cluster has 3 data nodes by default; a laptop has 1. Fixed via a
     `docker-compose.override.yml` setting
     `OPENSEARCH_EXPECTED_DATA_NODE_COUNT=1` (upstream's compose never
     passes the variable through from `.env`).
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

- Chat model: `gemma3:4b` (faster, weaker), `gemma3:12b` (default),
  `gemma3:27b` (needs the RAM), or any Ollama model, e.g. `llama3.1:8b`.
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
| Chat answers are slow | You're on CPU or a big model. Drop to `gemma3:4b` (see Changing models). On Apple Silicon, make sure nothing else is holding the GPU. |
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

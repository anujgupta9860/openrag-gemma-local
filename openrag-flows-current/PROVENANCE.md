# Vendored flow templates — provenance

These four Langflow flow definitions are copied **verbatim** from the
OpenRAG upstream repository (`github.com/langflow-ai/openrag`), `main`
branch at commit `f00c103` ("fix: backend bug fixes (#2550)",
2026-10-30) — the generation the `langflowai/openrag-*:latest` Docker
images are built from.

Why vendored: `setup.sh` clones OpenRAG at the pinned tag `v0.3.0` for
its compose/TUI, but the compose pulls backend/frontend/langflow
images at `:latest`. The v0.3.0 flow templates are an older generation
than that backend:

- The current backend converts documents itself (its own Docling
  phase) and hands the ingestion flow a **docling task id** (global
  variable `DOCLING_TASK_ID`) to fetch results by.
- The v0.3.0 ingestion flow instead expects a **file upload into
  Langflow** that this backend never performs (it invokes the flow
  with `file_paths=[]`), so its DoclingRemote node returns an empty
  DataFrame and ingestion fails with
  `Column 'doc' not found in DataFrame. Available columns: []`.

Verified end-to-end on the Mac mini install, 2026-11-01. `setup.sh`
copies these files over the checkout's `flows/` before starting the
stack, and (step 4b) deletes any previously imported stale copies from
Langflow's database so the new templates actually take effect.

Flow IDs are unchanged from upstream (ingestion
`5488df7c-b93f-4f87-a446-b67028bc0813`, agent
`1098eea1-6649-4e1d-aed1-b77249fb8dd0`), so existing backend
configuration (`LANGFLOW_INGEST_FLOW_ID` etc.) keeps pointing at the
right flows. Refresh this folder from upstream `main` if the backend
image generation moves again.

## Local deviations (two, both about streaming + Ollama tool calls)

1. In `openrag_agent.json` and `openrag_nudges.json`, the
   `OpenAICompatibleLLM` component's `build_model()` passes
   `disable_streaming: True` to `ChatOpenAI` (search the component code
   for "openrag-gemma-local").
2. In `openrag_agent.json`, the **Agent node's Stream toggle is off**
   (upstream ships it on).

Reason: Ollama tool calls do not survive **streaming** through the
backend's LiteLLM gateway — on both the native `ollama/` and
`ollama_chat/` routes a streamed tool call is flattened into content
text, so the agent prints raw tool-call JSON
(`{"name": "search_documents", "arguments": {...}}`) instead of
calling the tool. The identical calls non-streamed return proper
`tool_calls` at every hop (Ollama `/api/chat`, Ollama
`/v1/chat/completions`, LiteLLM `ollama/`). And with the Agent
streaming on, the run machinery forces `stream: true` into the model
request anyway (visible in the backend log as "LLM chat stream —
stream: True"), which then breaks LangChain's non-streaming result
handling outright ("Unexpected response type ... got AsyncStream").
Verified layer by layer 2026-11-01 on the Mac mini install. The cost
is that chat answers arrive whole rather than token-by-token;
correctness first for a local stack. Because these deviations change
component *code* and a template *value*, `setup.sh` step 4b's
staleness check hashes both, so they propagate to existing installs
on re-run. (Note: the stored flows are locked against direct API
edits — HTTP 423 — which is why propagation goes through
delete + re-import.)

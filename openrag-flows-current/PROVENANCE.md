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

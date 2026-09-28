# RAG example · Python

A single-file, guided walkthrough of every method on Cerebe's `client.rag`: embed documents, search (three ways), inspect the collection, and clean up — all against a real Cerebe API.

## 30-second quickstart

```bash
# 1. clone the repo and enter this directory
git clone https://github.com/cerebe-ai/cerebe.git
cd cerebe/examples/rag/python

# 2. set your API key
cp .env.example .env
# open .env and paste your key (get one at https://cerebe.ai/dashboard/keys)
# the key must have RAG scopes: rag:read, rag:write, rag:delete

# 3. install dependencies
make install

# 4. run the demo
make demo
```

## Prerequisites

- Python **3.11**, **3.12**, or **3.13**.
- [`uv`](https://docs.astral.sh/uv/) installed (`curl -LsSf https://astral.sh/uv/install.sh | sh`).
- A Cerebe API key with RAG scopes. Grab one at [cerebe.ai/dashboard/keys](https://cerebe.ai/dashboard/keys).

No other platform-side setup is required.

## What this example teaches

- How to authenticate the SDK from an environment variable.
- How to ingest a batch of markdown files with `embed_batch`.
- How `search`, `hybrid_search`, and `find_similar` differ (score breakdown included).
- How to inspect and clean up a collection with `stats`, `list_documents`, and `delete_document`.
- How to write live-API smoke tests that self-clean.

## What's in this directory

| File | Purpose |
|------|---------|
| `demo.py` | Guided CLI walkthrough — seven steps, each with timing and status |
| `test_rag.py` | Five live smoke tests (`pytest`) |
| `sample_docs/` | Five markdown files used as the demo corpus |
| `pyproject.toml` | PEP 621 manifest pinning `cerebe>=0.5.0` |
| `Makefile` | `install` / `demo` / `test` / `clean` |
| `.env.example` | Template for `CEREBE_API_KEY`, `CEREBE_BASE_URL` |

## Expected output

Running `make demo` against a working key prints a sequence of `rich` panels. Abridged:

```
╭────────────── step 1 - config ──────────────╮
│ Cerebe RAG Example                          │
│ base URL : https://api.cerebe.ai            │
│ API key  : ck_live_...xyz                   │
│ sample_docs : .../sample_docs               │
╰─────────────────────────────────────────────╯
╭──────── step 2 - preflight (833ms) ─────────╮
│ OK - API reachable                          │
│ collection at start: {...}                  │
╰─────────────────────────────────────────────╯
╭─────── step 3 - ingest (3623ms) ────────────╮
│             Ingested documents              │
│ ┏━━━━━━━━━━━━━━━━━━━━━━━┳━━━━━━━━┳━━━━━━━┓  │
│ ┃ source                ┃ chunks ┃ bytes ┃  │
│ ┡━━━━━━━━━━━━━━━━━━━━━━━╇━━━━━━━━╇━━━━━━━┩  │
│ │ .../authentication.md │      2 │  1840 │  │
│ │ .../knowledge-…       │      3 │  1935 │  │
│ │ .../memory-fabric.md  │      4 │  2151 │  │
│ │ .../observability.md  │      3 │  2154 │  │
│ │ .../rag.md            │      3 │  2245 │  │
│ └───────────────────────┴────────┴───────┘  │
╰─────────────────────────────────────────────╯

... (step 4a/b/c: search, hybrid_search, find_similar — each with top-3 table)
... (step 5: collection summary)
... (step 6: cleanup — deleted: 5, failures: 0)

╭──────── step 7 - summary ────────╮
│ every step OK, exit code 0       │
╰──────────────────────────────────╯
```

Exit code `0` on success, `1` if any step fails. Pass `--verbose` for full tracebacks when debugging.

## Commands

| Command | What it does |
|---------|--------------|
| `make install` | Creates `.venv/` and installs deps via `uv sync --extra dev` |
| `make demo` | Runs the guided walkthrough end-to-end |
| `make test` | Runs live smoke tests (skips cleanly if `CEREBE_API_KEY` isn't set) |
| `make clean` | Removes `.venv/` and pytest caches |

## Troubleshooting

**`Authentication failed (HTTP 401)`** — your key is wrong, missing, or revoked. Check `.env`; rotate at [cerebe.ai/dashboard/keys](https://cerebe.ai/dashboard/keys).

**`Permission denied (HTTP 403)`** — your key is valid but lacks a required scope. The demo needs `rag:read`, `rag:write`, and `rag:delete`. Grant them in the dashboard under the key's settings.

**`Could not reach the Cerebe API`** — network or DNS issue. Confirm with `curl https://api.cerebe.ai/api/v1/rag/stats -H "X-API-Key: $CEREBE_API_KEY"`.

**`Rate limit hit (HTTP 429)`** — slow down or use a different key. If it happens in CI, use a dedicated CI key.

**`CEREBE_API_KEY is not set`** — you haven't created `.env` yet. `cp .env.example .env` and paste your key.

**Import error for `cerebe`** — you skipped `make install`. Run it first.

## Cleanup

The demo and the tests clean up after themselves (they delete every document they create, using a unique session prefix so parallel runs can't clobber each other). If something crashes mid-run and leaves orphan sources, they're prefixed `rag-demo-<hex>/…` or `test-rag-<hex>/…` — you can see and delete them from the dashboard or with `client.rag.list_documents()` / `client.rag.delete_document()`.

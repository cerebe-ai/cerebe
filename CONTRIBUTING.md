# Contributing to Cerebe

Thanks for your interest in Cerebe. This repository is the public front door for the
Cerebe family — the build lifecycle (Cerebe Blueprint, Cerebe Factory) and the
cognitive infrastructure it rests on (Cerebe Memory, Cerebe Knowledge, Cerebe Models,
Cerebe Meta-Learning). What lives *here* is the public-facing surface: examples, the
front-door docs, `install.sh`, and the compiled `cerebe` + `cyclone` binaries published
to [Releases](https://github.com/momentiq-ai/cerebe/releases). (The CLIs are free to use
but not open source; the SDKs are MIT — see the README.)

## Where things live

- **Factory CLIs** (`cerebe`, `cyclone`) — compiled binaries on
  [Releases](https://github.com/momentiq-ai/cerebe/releases). Install with
  [`install.sh`](./install.sh). The source is proprietary; report CLI issues here.
- **Cognitive API + SDKs** (`cerebe` on PyPI, `@cerebe/sdk` on npm) — the runnable
  cognitive surface. Report SDK/API issues here via the issue templates.
- **Examples** ([`examples/`](./examples/)) — clone-and-run walkthroughs. New examples
  are welcome; see [`examples/README.md`](./examples/README.md) for conventions.
- **Blueprint** — the public scaffold is
  [`df-cerebe-template`](https://github.com/momentiq-ai/df-cerebe-template).
  `@momentiq/sage-cli` is retired.

## How to contribute

1. **Open an issue first** for anything beyond a typo or a docs fix — it saves you
   building something we can't take.
2. **Fork and branch.** Branch names: `<your-handle>/<short-slug>`.
3. **Keep PRs focused.** One logical change per PR. Fill out the PR template.
4. **Sign your work.** By contributing (to the examples or docs here) you grant Momentiq
   AI a perpetual, worldwide, royalty-free license to use, modify, and distribute your
   contribution as part of Cerebe.
5. **Be excellent to each other.** Assume good faith; keep discussion technical.

## Development

Each example is self-contained with its own README, dependency manifest, and live-API
smoke tests. There is no repo-wide build step today. To run an example:

```bash
cd examples/rag/python
cp .env.example .env   # paste your CEREBE_API_KEY
make install
make demo
```

Changes to `install.sh` come with its offline tests: `sh tests/install/run.sh` runs the real
script against a stubbed `curl` and a fixture release, with no network access.

## Reporting security issues

**Do not open a public issue for a security vulnerability.** See [SECURITY.md](./SECURITY.md).

## Questions

- Docs: [cerebe.ai/docs](https://cerebe.ai/docs)
- Account / billing: support@cerebe.ai

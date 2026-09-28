<p align="center">
  <img src="https://cerebe.ai/cerebe-logo.svg" alt="Cerebe" width="80" height="80" />
</p>

<h1 align="center">Cerebe</h1>

<p align="center">
  <strong>The AI-native software factory.</strong><br/>
  Build behind a quorum of AI critics and ship behind deterministic gates — one command to start.
</p>

<p align="center">
  <a href="https://cerebe.ai"><img src="https://img.shields.io/badge/site-cerebe.ai-black" alt="cerebe.ai" /></a>
  <a href="https://cerebe.ai/docs"><img src="https://img.shields.io/badge/docs-cerebe.ai-green" alt="Docs" /></a>
  <a href="https://github.com/cerebe-ai/cerebe/releases"><img src="https://img.shields.io/github/v/release/cerebe-ai/cerebe?label=cerebe%20CLI&color=black" alt="cerebe CLI release" /></a>
  <a href="./LICENSE"><img src="https://img.shields.io/badge/CLI-free%20to%20use-brightgreen" alt="Free to use" /></a>
</p>

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/cerebe-ai/cerebe/main/install.sh | sh
```

Run it **from the repo you want to adopt**. It puts the compiled `cerebe` and `cyclone`
binaries on your PATH (latest stable release, checksum-verified) and — when you run it
inside a git repo on your computer — wires that repo up. That's it. No npm, no pip, no Docker.
Needs only `curl` and `git`; macOS and Linux run the binaries, Windows uses the archives below.

- **Pin a version:** `CEREBE_VERSION=8.17.1 curl -fsSL … | sh`
- **Binaries only** (CI, or don't touch the repo): set `CI=1` or `CEREBE_SKIP_REPO=1`.
- **Windows:** download the `cerebe_*_windows_*.zip` and `cyclone_*_windows_*.zip` archives
  from [Releases](https://github.com/cerebe-ai/cerebe/releases) and put them on your PATH.

Already have the binaries and cloned a repo that's **already** set up for Cerebe? Skip the
curl and just run `cerebe init` in it to wire your local hooks to the committed contract.

Latest stable: **[v8.17.1](https://github.com/cerebe-ai/cerebe/releases/latest)** ·
[all releases](https://github.com/cerebe-ai/cerebe/releases).

Verify it:

```bash
cerebe --version
cerebe doctor      # checks binaries, repo config, and any local critics
```

---

## What that one line does

Running the installer inside a git repo writes a clean, committable contract and arms your
git hooks — nothing hidden, nothing that phones home:

| It writes | Role |
|---|---|
| `cerebe.yaml` | How this repo behaves — doctrine, denied commands, hooks, optional local fleet |
| `AGENTS.md` + `CLAUDE.md` | What every coding agent reads (seeded only if missing) |
| `cerebe/config.json` | Local CLI runtime — **0 critics, quorum 0** on day one |
| git hooks | Post-commit review + pre-push gate (both no-op until you enable a critic) |

**Day one is lights-out.** With an empty fleet, `cerebe review` and `cerebe gate-push`
**skip** — You opt in to reviewwhen you're ready. Detected AI CLIs 
on your machine are printed as a suggestion.

---

## Turn on local review

```bash
cerebe model add cursor     # or: claude, codex, gemini, kimi
cerebe doctor
```

Local review uses your **existing AI harness subscriptions** (such as Claude Code, 
Grok Build, Codex, Cursor, OpenCode) — no API keys. Once a critic is
enabled, the hooks come alive:

- **post-commit** runs the critic quorum **in the background**, so commits stay instant;
- **pre-push `gate-push`** blocks a push only on unresolved findings at or above your
  configured `blockingSeverities` (e.g. `high` / `blocker`). Everything lower is advisory —
  the gate always terminates, never an endless wall of nits. An emergency
  `AGENT_REVIEW_BYPASS="reason" git push` is allowed and durably audited.

```bash
cerebe review                       # run the quorum on HEAD now
cerebe review --incremental         # re-review only the delta since the last round
cerebe watch                        # live factory-floor TUI for this branch (--json for agents)
cerebe gate-push                    # the pre-push gate
cerebe status                       # terse verdict for a commit
cerebe findings --range main..HEAD  # audit findings across a range
```

Installed alongside, **`cyclone`** is the project-lifecycle CLI:

```bash
cyclone validate     # cycle-doc + planning validation
cyclone doc          # scaffold / write / list registered doc types
cyclone objectives   # derive and check verifiable objectives
cyclone decisions    # author + check the decision ledger
cyclone prove        # closeout proof for a cycle
cyclone publish      # publish review evidence
```

Agents reach the same surface without scraping help text:

```bash
cerebe mcp                # local MCP server over stdio
cerebe onboard --dry-run  # preview an agent-context scaffold for this repo
cerebe skills list        # bundled Factory skills
cerebe schemas list       # published JSON Schemas (config, evidence, artifacts)
```

---

## Hosted PR review — Cerebe Platform

The CLI above runs entirely on your machine and is free to use. **Cerebe Platform** is the
separate, hosted control plane: install the GitHub App and it reviews every pull request
with a managed critic fleet, posting the `cerebe` check with signed, per-commit evidence and
a dashboard — no runner or API keys required. It's a paid, managed service, and you do
**not** need it to use the CLI. See **[cerebe.ai](https://cerebe.ai)**.


---

> Free to use under the [Cerebe Software License](./LICENSE) — free for any use, including
> commercial. Not open source. **Cerebe Platform** is a managed commercial service.

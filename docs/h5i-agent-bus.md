# h5i-Compatible Agent Bus

Sugary has a small append-only agent bus for orchestration experiments.

The bus is not a reviewer, not a publisher, and not trusted evidence. It records review requests, review results, refutation requests, and publish decisions so we can test whether persistent coordination helps code review quality later.

## Backends

- `local-jsonl`: writes messages to a local JSONL log.
- `auto`: uses `h5i` if the executable is installed, otherwise falls back to `local-jsonl`.
- `h5i`: mirrors `REVIEW_REQUEST` messages through `h5i msg review` when available, while still writing the local JSONL log as the source of truth.

If h5i is not installed, Sugary does not fail the experiment. The report records:

- requested backend
- effective backend
- h5i availability
- local message path
- h5i mirror events, if any

## Install h5i

Official install path:

```sh
curl -fsSL https://raw.githubusercontent.com/Koukyosyumei/h5i/main/install.sh | sh
```

For a user-local install without `sudo`:

```sh
mkdir -p ~/.local/bin
curl -fsSL https://raw.githubusercontent.com/Koukyosyumei/h5i/main/install.sh -o /tmp/h5i-install.sh
H5I_INSTALL_DIR="$HOME/.local/bin" sh /tmp/h5i-install.sh
h5i --version
```

Initialize the repo sidecar:

```sh
h5i init
```

Plain `git push` does not push h5i refs. Use `h5i push` only when the project intentionally wants to share `refs/h5i/*` with collaborators.

For a local clone that should fetch shared h5i refs when they exist:

```sh
h5i share setup-remote
```

This writes fetch refspecs to local `.git/config`; it does not create a tracked repository change.

## Martian-Only Gate

Run:

```sh
./sugary orchestrator martian gate --limit 3 --replay-mode cache-first --agent-bus auto
```

Optional overrides:

```sh
./sugary orchestrator martian gate \
  --limit 5 \
  --offset 0 \
  --team teams/public-pcrs-static-codex-low-team.toml \
  --replay-mode cache-first \
  --agent-bus local-jsonl
```

Artifacts are written under:

```text
.sugary/research/orchestrator-gates/<run-id>/
```

Important files:

- `agent-messages.jsonl`
- `agent-bus-summary.json`
- `orchestrator-scorecard.json`
- `orchestrator-report.md`
- `agent-bus-leakage-report.json`

## Leakage Rules

Agent-bus messages use blind case labels such as `blind-martian-case-1`.

They must not include:

- benchmark oracle comments
- expected claims
- known non-issues
- original benchmark case IDs
- hidden scoring hints

The Martian orchestration gate writes a separate agent-bus leakage report.

## Interpretation

The first h5i-shaped run is transport-only. It does not prove h5i improves review quality, because reviewer prompts and tools are unchanged.

Live h5i mirroring requires a sender identity. Sugary passes `--from sugary-orchestrator` when mirroring `REVIEW_REQUEST` messages.

Sugary keeps concise repo-facing agent guidance in:

```text
AGENTS.md
CLAUDE.md
.claude/h5i.md
```

Those files explain how agents should use h5i without making public benchmark runs depend on h5i state.

Keep h5i only if later experiments show measurable value from persistent coordination or cross-agent memory:

- higher F1 or usefulness-adjusted F1
- no material SNR regression
- unique true positives from specialist agents
- fewer duplicate or stale comments
- useful auditability at acceptable operational cost

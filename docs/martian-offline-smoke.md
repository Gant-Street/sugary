# Martian Offline Smoke

Sugary can run an unofficial local smoke adapter for Martian Code Review Bench offline data.

## Setup

Point Sugary at a local checkout or extracted dataset:

```sh
export MARTIAN_BENCH_DIR=/path/to/code-review-benchmark
```

Or place it at:

```text
.sugary/research/benchmarks/martian-offline
```

No network fetch is attempted in `--local-only` mode.

## Commands

```sh
./sugary bench fetch martian-offline --local-only
./sugary bench list --suite martian-offline --limit 3
./sugary bench inspect --suite martian-offline --limit 3
./sugary bench run --suite martian-offline --method baseline-diff-only --limit 3 --local-only
./sugary experiment run experiments/public-martian-smoke-v0.toml --replay-mode cache-first
```

## Output

Each run writes normal Sugary artifacts plus:

```text
.sugary/research/public-smoke/<run-id>/public-smoke-report.md
```

The report is explicitly unofficial. It is useful for transfer checks and failure clustering only.

## Leakage Boundary

Reviewer inputs exclude:

- expected review comments
- gold labels
- original Martian case IDs
- source metadata that reveals answers
- oracle fields

The scorer and report writer can read the normalized oracle data after reviewer execution.

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

For live reviewer experiments, fetch a tiny local PR diff cache after cloning the benchmark repo:

```sh
elixir scripts/benchmarks/fetch_martian_diffs.exs --limit 3
```

The script reads `offline/results/benchmark_data.json`, fetches the corresponding public GitHub `.diff` files, and writes them into the ignored `.sugary` benchmark cache. The scorer still keeps golden comments out of reviewer inputs.

## Commands

```sh
./sugary bench fetch martian-offline --local-only
./sugary bench list --suite martian-offline --limit 3
./sugary bench inspect --suite martian-offline --limit 3
./sugary bench run --suite martian-offline --method baseline-diff-only --limit 3 --local-only
./sugary experiment run experiments/public-martian-smoke-v0.toml --replay-mode cache-first
./sugary experiment run experiments/public-martian-codex-transfer-v0.toml --replay-mode cache-first
```

To export an existing Sugary run into Martian's local official offline artifact layout, use:

```sh
./sugary martian parity export \
  --source-run .sugary/research/runs/<run-id> \
  --method pcrs-codex-repo-low-strict \
  --tool sugary-pcrs-repo-budget-max2 \
  --policy team-ev-max-2 \
  --limit 50
```

See [Martian Offline Parity](martian-official-parity.md) for the local official pipeline handoff.

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

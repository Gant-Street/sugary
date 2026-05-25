# CR-Bench Smoke

Sugary can run an unofficial local smoke adapter for CR-Bench-style data.

The v0 adapter is intentionally permissive: it can normalize JSON, JSONL, or text-like case files into Sugary `BenchmarkCase` records so that public benchmark examples can enter the same local research loop as fixtures and external reviewers.

## Setup

Point Sugary at local CR-Bench data:

```sh
export CR_BENCH_DIR=/path/to/cr-bench-data
```

Or place it at:

```text
.sugary/research/benchmarks/cr-bench
```

If data is unavailable, the adapter fails with a setup message instead of silently passing.

## Commands

```sh
./sugary bench fetch cr-bench --local-only
./sugary bench list --suite cr-bench --limit 3
./sugary bench run --suite cr-bench --method baseline-diff-only --limit 3 --local-only
./sugary experiment run experiments/public-cr-bench-smoke-v0.toml --replay-mode cache-first
```

## Scoring

Sugary maps available CR-Bench-style fields into local scorecards where possible. Missing fields are preserved as source metadata or treated as smoke-only context.

This is not an official CR-Bench implementation and should not be used for public claims.

## Research Use

Use CR-Bench smoke failures to answer:

- which local fixture categories are missing
- which reviewers overfit to fixture-shaped paths
- whether proof-carrying comments transfer
- whether external reviewer normalizers need richer structure

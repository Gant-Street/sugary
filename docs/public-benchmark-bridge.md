# Public Benchmark Bridge

Sugary public benchmark support is a local research bridge, not an official scoring path.

The bridge lets Sugary locate public benchmark data, normalize cases into the same `BenchmarkCase` protocol used by local fixtures, run reviewers through the existing proof/ranking/scoring harness, and write clearly labeled smoke reports.

Every report must be read as:

```text
Unofficial local smoke run. Not an official benchmark score.
```

## Commands

```sh
./sugary bench public list
./sugary bench fetch martian-offline --local-only
./sugary bench fetch cr-bench --local-only
elixir scripts/benchmarks/fetch_martian_diffs.exs --limit 3
./sugary bench list --suite martian-offline --limit 3
./sugary bench inspect --suite cr-bench --limit 3
./sugary bench run --suite martian-offline --method baseline-diff-only --limit 3 --local-only
./sugary experiment run experiments/public-martian-smoke-v0.toml --replay-mode cache-first
./sugary experiment run experiments/public-martian-codex-transfer-v0.toml --replay-mode cache-first
./sugary experiment run experiments/public-cr-bench-smoke-v0.toml --replay-mode cache-first
./sugary bench compare --run .sugary/research/runs/<local-run> --run .sugary/research/public-smoke/<public-run>
```

## Adapters

Implemented in v0:

| Benchmark | Adapter | Status |
| --- | --- | --- |
| Martian Offline | local smoke | implemented |
| CR-Bench | local smoke | implemented |
| c-CRAB | none | planned |

Adapters do not submit leaderboard runs and do not claim parity with upstream evaluation scripts.

## Normalization

Public cases are converted to `BenchmarkCase` records with:

- source benchmark name
- source path
- source commit SHA, when available
- original case id
- repo/project name
- PR metadata, when available
- license/usage note
- normalization timestamp
- adapter version

Oracle fields and gold comments are scorer-only. Reviewer input bundles are blinded so they do not include expected comments, gold labels, original public case IDs, or benchmark answer metadata.

For Martian Offline, Sugary prefers `offline/results/benchmark_data.json` from the benchmark repository and maps each PR to its golden comments. The benchmark repository does not store PR diffs directly in that file, so live reviewer smoke runs should first populate a local ignored diff cache:

```sh
elixir scripts/benchmarks/fetch_martian_diffs.exs --limit 3
```

The cache is written under:

```text
.sugary/research/benchmarks/martian-offline/offline/results/sugary_pr_diffs/
```

This keeps network fetching out of normal scoring and makes replayed smoke runs reproducible. If a diff is missing, the adapter still creates a case, but that case is not useful for judging reviewer quality.

## Artifacts

Public smoke runs copy selected run artifacts into:

```text
.sugary/research/public-smoke/<run-id>/
```

The directory includes:

- `benchmark-metadata.json`
- `normalized-cases/`
- `input-bundles/`
- `reviewer-results/`
- `final-reviews/`
- `scores.json`
- `failures.jsonl`
- `leakage-report.json`
- `public-smoke-report.md`

The normal experiment run still writes to `.sugary/research/runs/<run-id>/`.

## Replay

Public smoke experiments inherit command reviewer replay modes:

```sh
--replay-mode live
--replay-mode cache-first
--replay-mode replay-only
--replay-mode refresh
```

Reports show live versus replayed external reviewer results, cache hits, cost, and latency. Replay is for reproducibility and cost control, not official scoring.

## Interpretation

The bridge answers research questions:

- Did the locally promoted candidate transfer at all?
- Did public cases expose new failure clusters?
- Did external reviewers add unique signal?
- Did normalization create noise?
- Is the smoke subset too small to interpret?

It does not answer:

- whether Sugary has an official Martian score
- whether Sugary beats public leaderboards
- whether PCRS is validated generally
- whether public benchmark holdouts have been preserved

Failures from public smoke should feed the next local fixture and reviewer-design loop.

## First Transfer Smoke

`experiments/public-martian-codex-transfer-v0.toml` is the first small public-transfer experiment. It deliberately limits Martian Offline to three cases and compares:

- `baseline-diff-only`
- `hard-specialist-plus-pcrs`
- `codex-gpt-5.5-low`
- `codex-gpt-5.5-xhigh`

The intended readout is not benchmark rank. The intended readout is whether local hard-fixture winners transfer to real PRs, whether stronger reasoning actually improves signal, and which missing-context or noise clusters should drive the next PCRS iteration.

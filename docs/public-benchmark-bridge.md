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
./sugary bench list --suite martian-offline --limit 3
./sugary bench inspect --suite cr-bench --limit 3
./sugary bench run --suite martian-offline --method baseline-diff-only --limit 3 --local-only
./sugary experiment run experiments/public-martian-smoke-v0.toml --replay-mode cache-first
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

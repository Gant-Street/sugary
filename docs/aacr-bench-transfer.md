# AACR-Bench Transfer Smoke

Sugary supports an unofficial local bridge for [AACR-Bench](https://github.com/alibaba/aacr-bench).

AACR-Bench is useful for transfer checks because it is repository-level, multi-language, and separate from the Martian slice used by the current PCRS v3 no-key source checkpoint. In Sugary, it is not an official benchmark runner and it does not use the AACR evaluator.

## Setup

Place the AACR-Bench repo at one of:

```text
.sugary/research/benchmarks/aacr-bench
benchmarks/aacr-bench
vendor/aacr-bench
```

or set:

```sh
export AACR_BENCH_DIR=/path/to/aacr-bench
```

Then check:

```sh
./sugary bench fetch aacr-bench --local-only
./sugary bench inspect --suite aacr-bench --limit 3
```

## Normalization

The adapter reads:

```text
dataset/positive_samples.json
dataset/negative_samples.json
```

Positive comments become scorer-only expected claims. Negative comments with the same PR URL become known non-issue traps. Reviewer inputs are blinded and do not include gold comments, known non-issues, or original PR URLs.

PR diffs are fetched from public GitHub `.diff` URLs and cached under:

```text
.sugary/research/benchmarks/aacr-bench/dataset/diff-cache/
```

No API key is required. If a diff cannot be fetched, the case is still normalized, but it is weak evidence for diff-based reviewers.

## Transfer Gate

Run the locked no-key PCRS v3 static transfer gate:

```sh
./sugary pcrs transfer gate --suite aacr-bench --limit 50 --locked-commit e66b567
```

This writes:

```text
.sugary/research/transfer-gates/<run-id>/
  transfer-scorecard.json
  generalization-report.md
  run-dir.txt
```

The gate records source metrics from the current Martian-local PCRS v3 checkpoint, then runs the locked `public-static-proof-gate` unchanged on AACR.

It explicitly skips the model-backed ensemble publisher on AACR unless equivalent candidate source artifacts exist for that suite. That is intentional: replaying Martian candidate pools on AACR would be leakage-shaped and scientifically useless.

## Current Result

First 50 AACR cases:

| Method | Expected Claims | Hits | Noise | Precision | Recall | F1 | Comments |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `baseline-diff-only` | 467 | 0 | 0 | 0.000 | 0.000 | 0.000 | 0 |
| `public-static-proof-gate` | 467 | 0 | 0 | 0.000 | 0.000 | 0.000 | 0 |

Interpretation:

- This is a clean negative transfer result for the current deterministic static-proof patterns.
- It does not invalidate PCRS; it says the Martian-specific static pattern source does not generalize by itself.
- The next useful variable is candidate generation on AACR-like real PRs: repo-aware retrieval, a model-backed candidate generator, or a small set of benchmark-agnostic proof tools.
- Do not add AACR-specific patterns to make this result look better. That would corrupt the transfer gate.

## Sparse Repo Context

The first portable model-backed AACR run had no materialized workspaces, so Sugary now has a sparse context builder:

```sh
./sugary repo sparse-context --suite aacr-bench --limit 50 --id pcrs-v5-aacr-sparse-context-first50
```

It writes changed files, base files when available, local import/test/config neighbors, and cheap identifier context into:

```text
.sugary/research/workspaces/<case-id>/{base,head}
```

Reviewer-visible sparse workspaces do not include reference comments, expected claims, known non-issues, scorer labels, benchmark case IDs, or original PR URLs.

PCRS v5 then reran the unchanged portable reviewer against those sparse workspaces:

```sh
mix run -e 'IO.puts(Sugary.PortableTransferGate.run!(%{"id" => "pcrs-v5-aacr-sparse-transfer-first50", "suites" => "martian-offline,aacr-bench", "limit" => 50, "replay-mode" => "cache-first", "martian-run" => ".sugary/research/runs/20260531T153346Z-pcrs-v4-portable-transfer-first50-martian-offline"}))'
```

Sparse-context result on first 50 AACR cases:

| Method | Workspace Inputs | Expected Claims | Pool Hits | Pool Claims | Published Hits | Noise | Precision | Recall | F1 | Comments |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pcrs-v4-portable-codex-repo-low` with sparse context | 50 / 50 | 467 | 8 | 44 | 8 | 39 | 0.182 | 0.017 | 0.031 | 44 |

Interpretation:

- Sparse context readiness passed: 50 / 50 AACR cases had workspace inputs.
- The reviewer still missed the target: pool hits were 8, precision was 0.182, and F1 only moved from 0.028 to 0.031.
- The Martian qualified publisher guardrail remained at 0.561 F1 and 0.738 precision using the cached Martian source run.
- This rejects the theory that changed-file sparse context alone unlocks AACR transfer.
- The next variable should target candidate generation quality, evidence construction, or benchmark-agnostic claim matching.

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

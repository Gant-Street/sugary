# Holdout Generalization Gate v0

Dev wins are not proof.

The hard-suite dev result should be stated carefully:

```text
PCRS-style specialist composition showed local dev-split evidence of complementarity.
It is not yet validated as a general approach.
```

The promotion workflow exists to separate tuning from evaluation.

```text
choose on dev
lock candidate and baselines
run holdout without retuning
compare against frozen baselines
emit promote / reject / needs-more-data / invalid decision
```

## Lock A Candidate

Use a dev run to freeze the selected candidate, baselines, hashes, thresholds, and suite identity.

```sh
./sugary promotion lock \
  --candidate teams/hard-specialist-team.toml \
  --baseline-method baseline-diff-only \
  --baseline-method symbol-graph-reflexion \
  --baseline-team teams/proof-carrying-team.toml \
  --suite agent-written-hard-fixtures \
  --dev-run .sugary/research/runs/<dev-run-id> \
  --out promotions/hard-specialist-v0.toml
```

The lock file records:

- candidate id, type, and manifest path
- locked baseline methods and teams
- suite id and dev split
- dev run id
- git SHA when available
- candidate manifest hash
- baseline team manifest hashes
- reviewer pack hash
- fixture suite hash
- promotion thresholds
- timestamp

## Run Holdout

Run the locked candidate and locked baselines on holdout:

```sh
./sugary promotion run promotions/hard-specialist-v0.toml --split holdout
```

Default behavior does not run team search and does not retune on holdout.

Artifacts are written under:

```text
.sugary/research/promotions/<promotion-id>/
  lock.toml
  dev-summary.json
  holdout-run/
  baseline-runs/
  promotion-scorecard.json
  generalization-report.md
  leakage-report.json
  bootstrap.json
  decision.json
```

## Decisions

Possible decisions:

- `promote`
- `reject`
- `needs_more_data`
- `invalid_due_to_leakage`
- `invalid_due_to_changed_manifest`
- `invalid_due_to_saturated_holdout`

Promotion requires:

- candidate beats the best locked baseline on F1 or usefulness-adjusted F1
- candidate recall is not materially worse than the best baseline
- candidate SNR does not regress by more than 10%
- candidate stays under the comment budget
- candidate adds at least one unique true positive beyond the best baseline
- candidate does not add net noise after merge/ranking
- holdout is not saturated
- no fatal leakage or invalidation checks fire

## Generalization Gaps

The report includes:

```text
Candidate:
Baseline winner:
Dev result:
Holdout result:
Generalization gap:
Promotion decision:
Reason:
```

Metrics include recall, precision, usefulness, SNR, F1, average comments per PR, unique hits over baseline, added noise over baseline, false-positive trap hits, saturation status, and complementarity headroom.

Expected gaps:

```text
dev_f1 - holdout_f1
dev_snr - holdout_snr
```

Unique-hit gaps are reported as `n/a` until dev baseline comparison artifacts are locked with the same structure as holdout.

## Leakage And Invalidation

Fatal invalidation checks:

- candidate manifest changed after lock
- baseline team manifest changed after lock
- reviewer pack changed after lock
- fixture suite changed after lock
- holdout input artifacts contain real holdout case ids
- holdout is saturated

Warnings:

- reviewer emits exact oracle wording suspiciously often
- reviewer emits case-name-derived claims
- reviewer appears path/category-shaped
- same candidate/suite holdout has already been run

Warnings do not always invalidate a run. Fatal reasons are explicit in `leakage-report.json` and `decision.json`.

## Holdout Ledger

Every holdout promotion run appends:

```text
.sugary/research/holdout-ledger.jsonl
```

Each entry records timestamp, suite, split, candidate id, lock file, promotion run id, git SHA, result summary, and decision.

Repeated holdout runs are allowed, but reports warn when the same candidate/suite pair has already been evaluated. Repeated holdout probing should not be treated as fresh evidence.

## Bootstrap Intervals

Small fixture suites are noisy. Promotion reports include simple deterministic bootstrap intervals over cases for:

- F1
- usefulness
- SNR
- recall

Example:

```text
Candidate F1: 0.500 [0.000, 1.000]
Candidate usefulness: 1.000 [0.000, 1.000]
Candidate SNR: 1.000 [0.000, 3.000]
Candidate recall: 0.333 [0.000, 1.000]
```

These intervals are not a formal benchmark claim. They are a guardrail against overclaiming from tiny local suites.

## Category Regression Guard

The promotion scorecard includes category slices and warnings when a candidate wins overall while regressing materially in a category where the best locked baseline performs better.

This catches cases like:

```text
overall F1 improves
but security recall collapses
```

The first version reports warnings; later versions can make selected category regressions fatal.

## Interpretation

Use this workflow before wrapping real external tools.

The standard is:

```text
we chose on dev,
locked the candidate,
tested on holdout,
and the gain survived against frozen baselines
```

Not:

```text
we tuned on dev and therefore proved the approach
```

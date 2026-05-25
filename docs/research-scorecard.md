# Research Scorecard v0

Research Scorecard v0 is Sugary's small decision layer for deciding what to test next.

It is intentionally not a learned ranker, not a production publishing policy, and not an official benchmark score. It is a reporting-only scorecard that turns existing experiment artifacts into a clearer research diagnosis.

## Why This Exists

Existing code-review-agent research gives us several settled constraints:

- Recall alone is insufficient because higher recall can come from noisy comments.
- Usefulness and noise must be visible guardrails.
- Human-comment similarity is not enough because useful review should point to behaviorally correct fixes.
- Offline benchmarks are necessary but can be Goodharted.
- Repo navigation, tool interfaces, and fixed staged pipelines are strong priors, but still need ablation.

So the scorecard does not try to invent one perfect metric. It reports the minimal signals needed to choose the next small experiment.

## Primary Metrics

Research Scorecard v0 reports:

- `defect_hits`: expected defects found by published comments.
- `expected_defects`: expected defects in the evaluated cases.
- `recall`: `defect_hits / expected_defects`.
- `published_comments`: comments the reviewer would publish.
- `avg_comments_per_pr`: published comments divided by cases.
- `noise`: unsupported, preexisting, stylistic, speculative, or duplicate published comments.
- `usefulness`: useful published comments divided by published comments.
- `SNR`: useful comments divided by noise, with zero-noise handling from the core scorer.
- `suppressed_true_claims`: true candidates generated but not published.
- `unresolved_expected_defects`: expected defects still missed.
- `evidence_tier_distribution`: hits/noise by strongest evidence tier.
- `marginal_utility_by_rank`: utility contribution from rank 1, 2, 3, 4+, and all published comments.
- `false_positive_categories`: false-positive taxonomy counts.

It also keeps existing diagnostics as secondary context:

- F1
- cost
- latency
- category slices
- public smoke transfer
- saturation diagnostics

## Reporting-Only Utility

The initial utility model is deliberately simple:

```text
true defect hit: +1
high or critical defect hit: +2 additional
noise: -1
preexisting false positive: -2
published comment attention cost: -0.1
```

This utility is not used to publish or suppress comments. It only helps compare the shape of a run.

## Evidence Tiers

Published claims are grouped by strongest evidence tier:

```text
tier_1: executable failing test
tier_2: reproducible command or trace
tier_3: static path proof
tier_4: contract or spec mismatch
tier_5: weak heuristic
unknown: no tier present
```

The immediate research question is whether stronger evidence correlates with useful defect yield and whether weak evidence correlates with noise.

## Next Ablation Recommendation

The scorecard emits deterministic recommendations:

- If false negatives dominate and unresolved defects require cross-file, contract, schema, route, middleware, or historical context, test context retrieval.
- If false positives dominate, test refutation.
- If tier 5 claims dominate noise, test evidence gating.
- If high-confidence true claims are suppressed, test ranking or publishing thresholds.
- If different reviewers contribute unique true positives, test team or hybrid composition.
- If public smoke recall is low, expand local fixtures toward public-transfer failures.

The recommendation is not a product decision. It is the next research step that should be easiest to falsify.

## Artifacts

Every experiment run writes:

```text
.sugary/research/runs/<run-id>/research-scorecard.json
.sugary/research/runs/<run-id>/research-scorecard.md
```

The normal `report.md` links to these artifacts and shows the best method by research utility plus the recommended next ablation.

## How To Use It

Run any existing experiment:

```sh
./sugary experiment run experiments/pcrs-hard-fixtures-v0.toml
```

Then inspect:

```sh
./sugary experiment report .sugary/research/runs/<run-id>
```

or open:

```text
.sugary/research/runs/<run-id>/research-scorecard.md
```

Use the scorecard to choose one next ablation. Do not add several architecture ideas in the same run unless the scorecard points to composition as the likely bottleneck.

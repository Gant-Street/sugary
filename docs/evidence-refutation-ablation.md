# Evidence/Refutation Ablation v0

This ablation is the first narrow PCRS mechanism test.

It asks:

```text
Does evidence + refutation improve useful defect yield without increasing noise?
```

## Why This Is Small

The ablation deliberately holds context and candidate generation fixed. Only evidence, refutation, and expected-value ranking change.

That means a result can be attributed to the PCRS gates rather than to a different model, different context strategy, different team, or different public benchmark adapter.

## Variants

The manifest lives at:

```text
experiments/evidence-refutation-ablation-v0.toml
```

It runs:

| Variant | Evidence | Refutation | Ranking |
| --- | --- | --- | --- |
| baseline | none | none | fixed threshold |
| evidence only | static trace stub | none | fixed threshold |
| refutation only | none | generic refuter stub | fixed threshold |
| evidence + refutation | static trace stub | generic refuter stub | fixed threshold |
| evidence + refutation + ranker | static trace stub | generic refuter stub | expected-value stub |

All variants use:

```text
context = symbol_graph_stub
candidate_generation = reflexion_stub
```

## Artifacts

When the manifest runs, Sugary writes:

```text
.sugary/research/runs/<run-id>/evidence-refutation-ablation.json
.sugary/research/runs/<run-id>/evidence-refutation-ablation.md
```

The artifact reports:

- research utility deltas versus baseline
- defect hit deltas
- noise deltas
- usefulness deltas
- evidence tier distribution
- marginal utility by rank
- whether the variants actually shared context and candidate generation
- decision: promote, reject, or needs harder fixtures

## Decision Rule

The evidence/refutation path is promoted only when it:

- improves research utility over baseline
- does not reduce defect hits
- does not increase noise
- uses the same context and candidate-generation path
- runs on cases with enough gradient

It is rejected if it fails to improve utility and increases noise.

Otherwise the result is treated as needing harder fixtures, because the current suite may not have enough signal to distinguish the mechanism.

## Command

```sh
./sugary experiment run experiments/evidence-refutation-ablation-v0.toml
```

Then inspect:

```text
.sugary/research/runs/<run-id>/evidence-refutation-ablation.md
.sugary/research/runs/<run-id>/research-scorecard.md
```

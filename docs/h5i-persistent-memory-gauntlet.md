# h5i Persistent Memory Gauntlet

The persistent memory gauntlet tests one architecture claim:

```text
h5i-backed persistent specialist memory improves review quality
over the same stateless reviewers.
```

It is a controlled local smoke experiment, not an official benchmark run.

## Command

```sh
./sugary h5i memory gauntlet \
  --train-limit 3 \
  --eval-limit 3 \
  --train-offset 0 \
  --eval-offset 3 \
  --replay-mode cache-first \
  --h5i true
```

Artifacts are written under:

```text
.sugary/research/persistent-memory-gauntlets/<run-id>/
```

Important files:

- `h5i-memory.json`
- `shuffled-memory.json`
- `h5i-memory-events.jsonl`
- `agent-bus-summary.json`
- `scorecard.json`
- `leakage-report.json`
- `report.md`

## Compared Variants

- `stateless-team`: the locked reviewer team as implemented today.
- `stateless-normalized-team`: the same merged candidate pool with the gauntlet's normalized publisher and no memory.
- `h5i-persistent-memory-team`: the same candidate claims with h5i-backed memory used for ranking/refutation.
- `shuffled-memory-control-team`: negative control using shuffled train-split memory.

The important comparison is:

```text
h5i-persistent-memory-team > stateless-normalized-team
and
h5i-persistent-memory-team > shuffled-memory-control-team
```

## Memory Rules

Training memory is derived only from prior train-split reviewer outputs and scorer feedback.

Memory may include:

- generated claim summaries
- generated claim categories
- generated claim paths
- whether the generated claim was a prior hit or prior noise on the train split

Memory must not include:

- eval oracle data
- expected claims
- known non-issues
- public benchmark source case IDs
- scorer output for eval cases

## Promotion Bar

The h5i memory approach is validated only if:

- F1 improves over stateless.
- F1 improves over shuffled-memory negative control.
- SNR does not regress by more than 10%.
- memory adds at least one unique true positive over stateless.
- memory does not add net noise.
- leakage checks are clean.

Otherwise the result is `invalidate_h5i_memory_lift` or `inconclusive_h5i_memory_lift`.

## Current Scope

This first gauntlet tests memory as a ranking/refutation variable. It does not yet test memory-assisted candidate generation. That is deliberate: generation, ranking, and persistence should be tested separately.

The normalized stateless publisher exists to keep the comparison fair: memory and no-memory variants must publish from the same candidate pool with the same comment budget.

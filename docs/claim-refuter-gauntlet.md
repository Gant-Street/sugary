# Claim-Specific Refuter Gauntlet

The claim refuter gauntlet tests whether an independent, repository-backed model
can remove noise from a frozen PCRS publisher without suppressing unique defects.

It targets claims published by the online two-comment policy but not by the
online one-comment policy. These marginal comments are where additional recall
and additional noise compete most directly.

## Boundary

Each claim is evaluated independently in an isolated detached Git worktree. The
refuter receives:

- the proposed claim and its claimed failure path;
- sanitized PR title and body;
- the PR head worktree;
- exact base and head commit SHAs;
- repository history through the isolated worktree.

It does not receive expected benchmark claims, known non-issues, scorer labels,
posterior scores, source agreement counts, or benchmark case IDs.

The refuter returns one structured verdict:

- `support`: repository evidence establishes an introduced failure;
- `refute`: repository evidence defeats the claim or its introducedness;
- `abstain`: neither side is established.

Every verdict records confidence, proof type, commands, paths, observations, the
strongest counterargument, and residual uncertainty. Results use the command
reviewer replay cache.

## Scorer-Aligned Attribution

Marginal claims cannot be classified only by whether they resemble a gold
comment. Multiple comments may match the same expected defect while adding no
new hit and increasing duplicate noise.

Sugary therefore computes each claim's leave-one-out effect:

- `essential_hit`: removing the claim loses a unique defect hit;
- `removable_noise`: removing the claim reduces noise without losing a hit;
- `neutral`: removing the claim changes neither unique hits nor noise.

The critical refuter metrics are removable-noise refutation rate and
essential-hit harm rate.

## Running

```sh
./sugary pcrs claim refuter \
  --source-run .sugary/research/pcrs-ensemble-publisher/<run> \
  --materialization-run .sugary/research/repo-materializations/<run> \
  --policy online-qualified-max2-t70 \
  --base-policy online-qualified-max1-t55 \
  --claim-limit 30 \
  --concurrency 2 \
  --replay-mode cache-first \
  --model gpt-5.5 \
  --reasoning-effort low
```

Use `replay-only` to rescore a completed run without calling Codex.

This is an unofficial local research instrument. A fixed-pool win only
qualifies a policy for a fresh locked slice; it is not a product promotion or
official benchmark claim.

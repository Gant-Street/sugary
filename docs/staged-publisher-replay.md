# Staged Publisher Replay

Staged publisher replay is a fixed-pool ablation for PCRS publisher research.

It answers one narrow question:

```text
Given the same staged candidate and validation rows, which proof/refutation/publishing policy produces the best low-noise review?
```

This matters because live model runs vary. If one experiment changes candidate generation and publisher logic at the same time, the result can be driven by a different model sample rather than a better proof gate.

## Command

```sh
./sugary pcrs staged replay \
  --source-run .sugary/research/runs/<run-id> \
  --method codex-gpt-5.5-low-staged-typed-proof-v8 \
  --baseline codex-gpt-5.5-low-no-tools \
  --suite martian-offline \
  --limit 10 \
  --offset 0
```

The command reads staged command-reviewer artifacts from:

```text
<source-run>/<method>/adapter-artifacts/<case-id>.json
```

It extracts each staged reviewer's `validation_stage` rows and converts them back into internal `ReviewClaim`-like maps. It then evaluates publisher policies without making live model calls.

## Policy Inputs

Each replayed candidate can use:

- `proof_decision`
- `proof_score`
- `proof_type`
- `root_cause_key`
- `source_role`
- `evidence_summary`
- `counterargument`
- `typed_requirements_met`
- `has_repo_evidence`
- `has_read_file`
- `has_repo_grep`
- `expected_failure_language`
- `suppressing_invariants`
- `speculative_language`

The replay does not inspect benchmark oracle data until scoring. It does not expose expected claims or known non-issues to the publisher policies.

## Outputs

Each run writes:

```text
.sugary/research/runs/<timestamp>-staged-publisher-replay-v0/
  replay-config.json
  policy-scorecards.json
  baseline-scorecard.json
  decision.json
  report.md
```

Reports are unofficial local smoke results. They are not official Martian, CR-Bench, or public benchmark scores.

## Promotion Rule

A replay policy is only eligible for a live check if it clears the configured baseline guardrails:

- higher F1 than the baseline
- usefulness no worse than the baseline
- SNR no worse than the baseline
- noise no worse than the baseline
- average comments per PR no worse than the baseline
- at least one unique true positive over the baseline

Passing replay does not prove the architecture works. It means the publisher policy is worth testing in a locked live run.

## Live Check

Replay-selected policies can be carried back into the staged command reviewer with:

```sh
SUGARY_STAGED_PUBLISHER_POLICY=source-proof-max-2 \
./sugary experiment run experiments/codex-staged-typed-proof-gate-martian-dev10-v0.toml \
  --replay-mode refresh
```

Supported policy names in v0:

- `source-proof-max-1`
- `source-proof-max-2`
- `source-proof-max-3`
- `typed-repo-proof-max-2`
- `typed-repo-proof-max-3`
- `repo-proof-score-max-2`
- `repo-proof-score-max-3`

The default remains `source-proof`, preserving the staged reviewer's prior behavior.

## Research Principle

Use this loop before changing candidate agents, tools, or models:

```text
live candidate generation once
  -> fixed validation_stage replay
  -> choose publisher policy
  -> locked live check
```

This keeps the research bitter-pilled: one variable at a time, negative results reported directly, and no benchmark claims from confounded runs.

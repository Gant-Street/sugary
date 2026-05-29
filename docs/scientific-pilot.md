# Scientific Pilot

Scientific Pilot v0 is the bridge between short smoke runs and locked promotion. It runs one candidate against one or more baselines on the same cases, chooses the strongest paired baseline, and reports deltas with bootstrap intervals over cases.

It is designed to answer a narrow question:

```text
Did this candidate beat the best paired baseline by enough evidence to enter locked promotion?
```

It is not a leaderboard submission and does not claim official benchmark performance.

## Command

Direct candidate/baseline mode:

```sh
./sugary scientific pilot \
  --suite martian-offline \
  --candidate public-static-proof-gate \
  --baseline baseline-diff-only \
  --baseline codex-gpt-5.5-xhigh \
  --limit 100 \
  --offset 0 \
  --min-cases 100 \
  --bootstrap-iterations 500
```

Experiment-manifest mode:

```sh
./sugary scientific pilot \
  --experiment experiments/public-martian-pcrs-transfer-v1.toml \
  --candidate public-pcrs-static-codex-low-team \
  --baseline codex-gpt-5.5-low \
  --baseline codex-gpt-5.5-xhigh \
  --limit 100 \
  --replay-mode cache-first \
  --min-cases 100
```

Use experiment-manifest mode when reviewers require command configuration, replay cache, teams, or external tools.

## Metrics

The pilot reports aggregate and paired deltas for:

- F1
- usefulness-adjusted F1
- recall
- usefulness
- SNR
- noise
- cost
- latency
- average comments per PR
- hits
- published claims

Bootstrap intervals are computed over paired case deltas. This matters because a candidate and baseline must be compared on the same PRs, not on independent samples.

## Decisions

Possible decisions:

- `promote_to_locked_workflow`
- `reject`
- `insufficient_evidence`

Promotion to locked workflow requires:

- sample size at or above `--min-cases`
- positive primary paired delta
- positive lower bootstrap bound for the primary metric, unless explicitly disabled
- no material SNR regression
- comment budget respected
- at least one unique true positive over the best baseline
- no net added noise

The default primary metric is usefulness-adjusted F1 because it rewards defect discovery only when the comments remain useful.

## Artifacts

Each run writes:

```text
.sugary/research/scientific-pilots/<run-id>/
  config.json
  underlying-run.txt
  method-scorecards.json
  paired-deltas.jsonl
  bootstrap.json
  decision.json
  analysis.json
  scientific-pilot-report.md
```

The underlying experiment run still writes the normal Sugary experiment artifacts under `.sugary/research/runs/`.

## Interpretation

Scientific pilots are stricter than smoke tests and weaker than final claims.

Use this sequence:

```text
smoke run
  -> scientific pilot
  -> locked promotion
  -> larger public benchmark transfer
  -> product default only after repeated evidence
```

If a pilot says `insufficient_evidence`, the right next action is usually to increase case count or fix execution/replay coverage. If it says `reject`, the candidate failed under the configured evidence bar.

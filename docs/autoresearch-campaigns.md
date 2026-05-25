# Autoresearch Campaigns

Campaign Runner v0 turns many short experiment runs into one bounded research campaign.

The runner does not edit Sugary source code, tune on holdout, submit public benchmarks, or publish GitHub comments. It only composes existing experiment primitives, checkpoints progress, ranks variants, and recommends a candidate for the locked promotion workflow.

## Run

```sh
mix escript.build
./sugary campaign run campaigns/evidence-refutation-campaign-v0.toml
```

Useful options:

```sh
./sugary campaign run campaigns/evidence-refutation-campaign-v0.toml --dry-run
./sugary campaign run campaigns/evidence-refutation-campaign-v0.toml --limit-experiments 4
./sugary campaign run campaigns/evidence-refutation-campaign-v0.toml --resume
./sugary campaign run campaigns/evidence-refutation-campaign-v0.toml --replay-mode replay-only
```

Campaign artifacts are written under:

```text
.sugary/research/campaigns/<campaign-id>/
```

## Manifest

A campaign manifest fixes the objective, search space, budget, guardrails, and stop rules before the run starts.

```toml
id = "evidence-refutation-campaign-v0"
suite = "agent-written-hard-fixtures"
split = "dev"
primary_metric = "research_utility"
replay_mode = "cache-first"

[fixed_baselines]
method_ids = ["baseline-diff-only", "symbol-graph-reflexion"]
team_paths = []

[search_space]
contexts = ["changed_files", "symbol_graph_stub"]
candidate_generations = ["baseline_single_shot", "reflexion_stub"]
evidence = ["none", "static_trace_stub"]
refutations = ["none", "generic_refuter_stub"]
rankings = ["fixed_threshold", "expected_value_stub"]
team_paths = ["teams/proof-carrying-team.toml"]

[budget]
max_experiments = 12
max_wall_time_seconds = 1200
max_estimated_cost_usd = 1.0

[guardrails]
material_recall_regression = 0.05
min_snr_ratio = 0.9
max_avg_comments_per_pr = 3.0
```

## Metrics

The primary metric is `research_utility`, from the research scorecard:

```text
true defect hits
+ severity bonuses
- false positives
- preexisting/style/speculative penalties
- published comment attention cost
```

Guardrails prevent a high utility score from hiding regressions:

- recall must not materially regress against the best completed baseline
- SNR must not regress beyond the configured ratio
- average comments per PR must stay under budget
- campaign cost must stay under budget
- oracle-backed methods fail leakage checks

## Checkpoints

Every campaign writes:

```text
campaign.toml
state.json
queue.json
completed-runs.jsonl
leaderboard.json
failures.jsonl
campaign-report.md
recommended-candidate.toml
```

`recommended-candidate.toml` is written only when a non-baseline variant beats the best baseline while passing guardrails.

## Decisions

Campaign decisions:

- `recommend_candidate`: run this candidate through locked promotion.
- `reject_search_space`: the bounded variables did not produce a useful candidate.
- `needs_harder_fixtures`: the best baseline saturated the suite.
- `needs_new_reviewer_capability`: failures remain that the current search space cannot address.
- `budget_exhausted`: wall time, experiment count, or cost stopped the campaign.
- `invalid_due_to_leakage`: the campaign attempted to tune on holdout or used oracle-backed methods.

## Holdout Rule

Campaign Runner v0 refuses to run on `split = "holdout"`. Use campaigns to search on train/dev. Use `promotion lock` and `promotion run` for holdout evaluation.

This separation is intentional: a campaign recommends candidates; a locked promotion run validates whether the gain survives.

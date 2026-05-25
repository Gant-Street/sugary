# Architecture Gauntlet v0

Architecture Gauntlet v0 tests review-system ingredients as composable variables, not mutually exclusive products.

The point is to answer:

```text
Does this ingredient help by itself?
Does it add unique signal when composed with other ingredients?
Does the composition beat its best member and the best usable reference baseline after dedupe/ranking?
```

This is different from `tool gauntlet`. Tool Gauntlet v0 replays a fixed claim pool and asks whether one tool-derived signal should influence publishing. Architecture Gauntlet v0 runs full methods, command reviewers, and teams through the normal experiment runner, then compares solo and composed performance.

## Variables

The current five directions are:

```text
native harness baseline:
  Codex, Claude Code, opencode, Semgrep, or another tool run as intended,
  then normalized into ReviewerResult. This is a reference, not a handicapped
  Sugary tool.

agentless-style pipeline:
  fixed phases such as localize -> claim -> evidence/refute -> rank.

repo-navigation reviewer:
  changed files, symbol context, materialized base/head repos, grep, and
  related-file reads. The current manifest uses a symbol-graph proxy until live
  repo tools are wired into generation.

PCRS wrapper:
  proof/evidence/refutation/ranking around candidate claims.

team/union composition:
  multiple reviewers produce claims independently; Sugary dedupes, preserves
  provenance, ranks, and scores the merged output.
```

## Run

```sh
mix escript.build

./sugary architecture gauntlet gauntlets/five-variable-architecture-v0.toml \
  --replay-mode cache-first
```

Artifacts are written under:

```text
.sugary/research/architecture-gauntlets/<run-id>/
```

The gauntlet also writes an underlying normal experiment run under:

```text
.sugary/research/runs/<run-id>/
```

## Manifest

Use `[[variables]]` for solo ingredients and `[[compositions]]` for teams or wrappers:

```toml
id = "five-variable-architecture-v0"
suite = "agent-written-hard-fixtures"
split = "dev"
replay_mode = "cache-first"

[guardrails]
min_snr_ratio = 0.9
min_usefulness_ratio = 1.0
max_added_noise = 0
max_avg_comments_per_pr = 3.0
min_unique_hits = 1

[[variables]]
id = "native-codex-low"
role = "native_harness_reference"
type = "command"
command = "elixir"
args = ["scripts/reviewers/codex_exec_reviewer.exs"]
required_executable = "codex"

[[variables]]
id = "agentless-style-pipeline"
role = "candidate"
reviewer = "pcrs-evidence-refuter"
ingredients = ["fixed_phase", "evidence", "refutation"]

[[compositions]]
id = "hard-specialist-plus-pcrs"
role = "composition"
team = "teams/hard-specialist-plus-pcrs.toml"
members = ["hard-specialist-team", "agentless-style-pipeline"]
```

Command reviewers still go through the external command boundary. They receive sanitized `ReviewInputBundle` JSON and return `ReviewerResult` JSON. They never publish directly.

## Decisions

Variable decisions:

```text
reference:
  A baseline or native harness used for comparison.

keep:
  The variable improves the reference and clears usefulness, SNR, noise,
  comment-budget, and unique-signal/noise-reduction guardrails.

quarantine:
  The variable found signal or improved a metric, but failed a guardrail.

discard:
  The variable did not add measurable value.
```

Composition decisions:

```text
promote:
  The composition beats its best member, beats the best usable reference
  baseline, and clears guardrails.

quarantine:
  The composition found signal or improved a metric, but failed guardrails.

reject:
  The composition did not beat its best member or the best usable reference.
```

## Non-Claims

Architecture Gauntlet v0 is not an official benchmark score. It does not prove PCRS generalizes. It is a research map for deciding which ingredients deserve a locked promotion run, public benchmark smoke, or a deeper live-tool gauntlet.

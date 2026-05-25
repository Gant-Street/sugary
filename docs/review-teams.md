# Review Teams

Review Teams let Sugary evaluate review architectures instead of only single reviewers.

A team is a manifest that lists reviewers. In v0 reviewers run sequentially, produce claims independently, and never communicate directly with each other. Sugary owns the merge, dedupe, ranking, scoring, reports, and any future publishing decision.

## Team Manifest

```toml
id = "proof-carrying-team"
description = "Candidate generation plus evidence/refutation reviewers."

failure_policy = "continue"
merge_strategy = "dedupe_by_key_location_and_claim"
max_published_claims = 3
metadata = { theory = "pcrs" }
artifact_fields = ["raw_claims", "merged_claims", "provenance"]

[[reviewers]]
id = "symbol-graph-reviewer"
type = "method"
method = "symbol-graph-reflexion"

[[reviewers]]
id = "sample-command-reviewer"
type = "command"
command = "elixir"
args = ["scripts/sample_command_reviewer.exs"]
timeout_ms = 5000
```

Experiments can reference a team:

```toml
[[methods]]
id = "proof-carrying-team"
team = "teams/proof-carrying-team.toml"
```

They can also reference a single reviewer:

```toml
[[methods]]
id = "baseline-single-reviewer"
reviewer = "baseline-changed-files"
```

## Merge And Provenance

Team claims are deduped by explicit `dedupe_key` first. If a claim has no usable dedupe key, Sugary falls back to normalized location, category, severity, and canonicalized claim text.

Merged claims keep provenance under `source.provenance`, including the original reviewer ID, original claim ID, and reviewer result ID. Raw reviewer claims are still written to `raw-claims.jsonl`; merged claims are written to `merged-claims.jsonl`; published claims are written to `published-claims.jsonl`.

After merging, Sugary ranks claims by severity, confidence, and reviewer agreement. `max_published_claims` caps comments per case, and a small rank threshold suppresses low-value single-reviewer claims so teams are not just noisy unions.

## Failure Policies

Supported policies:

- `continue`: reviewer failures are recorded, and successful reviewers still contribute claims.
- `fail_team`: any reviewer failure makes the team result fail with no published claims.
- `require_at_least_one_success`: the team fails only if every reviewer fails.

Reviewer failures are artifacts, not experiment-runner crashes.

## Contribution Accounting

Team reports include individual reviewer scorecards and v0 marginal contribution:

```text
team_score_with_reviewer - team_score_without_reviewer
```

This is intentionally simpler than Shapley attribution. It is enough to tell whether a team is genuinely complementary or just carried by one strong reviewer.

## External Reviewers

External command reviewers inside a team still cannot publish directly. They receive sanitized `ReviewInputBundle` JSON on stdin and return `ReviewerResult` JSON on stdout. Sugary controls merge, dedupe, ranking, scoring, and final reporting.

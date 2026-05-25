# Reviewer Complementarity

Reviewer complementarity asks whether a team is better than its strongest member.

Sugary treats this as a measured research question, not a product assumption. A team that beats a weak baseline but fails to beat its best individual reviewer is not promoted.

## Reviewer Packs

Reviewer packs are reusable collections of reviewers:

```toml
id = "baseline-pack-v0"
description = "First heterogeneous reviewer pack for complementarity testing."

[[reviewers]]
id = "security-specialist-reviewer"
type = "command"
command = "elixir"
args = ["scripts/security_specialist_reviewer_fixture.exs"]
timeout_ms = 5000
capabilities = ["security", "auth"]
```

Reviewers can be native methods or command reviewers. Command reviewers still receive sanitized `ReviewInputBundle` JSON on stdin and return `ReviewerResult` JSON on stdout. They cannot publish directly.

## Capability Tags

Capability tags describe the kind of signal a reviewer is supposed to provide:

```toml
capabilities = ["diff", "cross_file", "security", "test_gap", "contract", "static_analysis", "edge_case"]
```

Tags appear in complementarity reports so weak or duplicate reviewer classes are visible.

## Team Search

Run:

```sh
./sugary team search --pack reviewer-packs/baseline-pack-v0.toml --suite agent-written-fixtures --max-team-size 3
```

The search evaluates every individual reviewer, every pair, every team of three, and the full team. It uses cached reviewer outputs for speed, then applies the existing team merge, dedupe, ranking, and scoring path to each subset.

Artifacts are written under:

```text
.sugary/research/runs/<timestamp>-team-search-<pack-id>/
```

Important artifacts:

- `reviewer-scorecards.json`
- `team-scorecards.json`
- `coverage-matrix.json`
- `oracle-union-upper-bound.json`
- `promotion.json`
- `complementarity-summary.json`
- `report.md`

## Metrics

Complementarity reports include:

- individual reviewer F1, usefulness, and SNR
- unique hits
- duplicate hits
- noise
- marginal F1, usefulness, and SNR
- best single reviewer
- best pair
- best team of three
- full team
- oracle union upper bound
- avoidable union noise

`unique hit` means a true positive found by a reviewer that no stronger reviewer found. `duplicate hit` means the same true positive was found by another reviewer. Marginal contribution is the full-team score with the reviewer minus the full-team score without the reviewer.

## Promotion Policy

A team is promoted only if:

- it beats the best individual reviewer on F1 or usefulness-adjusted F1
- it does not reduce SNR by more than 10%
- it stays under the comment budget
- it adds at least one unique true positive beyond the best individual reviewer
- it does not add net noise after merge/ranking

Otherwise the report says:

```text
No team promoted. Best individual reviewer remains the default.
```

## Interpretation

“Team did not beat best individual” means the architecture is not yet justified for that suite. The next step should be to improve the strongest reviewer or add a genuinely missing specialist, not to ship a team-shaped product demo.

This step comes before GitHub Actions or product work because the product thesis depends on review architecture actually producing better evidence-calibrated outcomes. Fixture-only runs do not prove benchmark superiority; they prove whether the local lab can detect complementarity or its absence.

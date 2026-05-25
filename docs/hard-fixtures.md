# Hard Fixture Suite v0

Hard Fixture Suite v0 makes the local benchmark harder before Sugary moves toward product publishing or real provider integrations.

The purpose is not to claim public benchmark superiority. The purpose is to create local gradient:

```text
harder cases
+ blind holdout inputs
+ false-positive traps
+ difficulty metadata
+ saturation diagnostics
= a harness that can say when architecture comparisons are meaningful
```

## Benchmark Splits

Suite manifests live under `fixtures/suites/`.

`fixtures/suites/agent-written-hard-fixtures.toml` defines:

```toml
[suite]
id = "agent-written-hard-fixtures"

[split.train]
cases = [...]

[split.dev]
cases = [...]

[split.holdout]
cases = [...]

[split.smoke]
cases = [...]
```

Split meaning:

- `train`: allowed for developing reviewers and fixtures.
- `dev`: allowed for repeated research runs and ablations.
- `holdout`: excluded from normal tuning. Use it to check whether a method generalizes.
- `smoke`: tiny subset for quick CLI and CI checks.

Reports label the suite and split. Promotion claims must say whether they were measured on `dev` or `holdout`.

## Blind Holdout Mode

Run a holdout benchmark:

```sh
./sugary bench run --suite agent-written-hard-fixtures --split holdout --method baseline-diff-only
```

Run team search against the holdout split:

```sh
./sugary team search --pack reviewer-packs/baseline-pack-v0.toml --suite agent-written-hard-fixtures --split holdout --max-team-size 3
```

Holdout input rules:

- Reviewer input receives a blinded case id such as `holdout-case-12345`.
- Reviewer input receives suite `blind`.
- Reviewer input does not include split metadata, suite metadata, expected claims, known non-issues, scorer labels, or fixture ids.
- Reports may include real case ids after scoring.
- Holdout reports include a warning that methods should not be tuned against that split before making promotion claims.

## Saturation

A suite is saturated when the best individual reviewer finds all expected claims with zero noise.

```text
fixture_saturated =
  best individual hits all expected claims
  and best individual produces zero noise
```

When saturated, Sugary reports:

```text
This suite is saturated. It cannot support claims about team complementarity or architecture superiority.
```

This is a benchmark problem, not automatically a reviewer success. If one reviewer is perfect, a team cannot prove complementarity because there are no missing true positives to contribute.

## Complementarity Headroom

Complementarity headroom is the gap between the oracle union of all reviewer true positives and the best individual score.

```text
complementarity_headroom =
  oracle_union_score - best_individual_score
```

Useful signals:

- `0`: no local evidence that teams can improve the best reviewer on this suite.
- Greater than `0`: at least one reviewer found a true positive the best individual missed.
- High union noise: reviewers may have useful recall, but need stronger evidence gates or refutation.

## False-Positive Traps

Every hard case includes at least one known non-issue. Trap examples:

- style-only issue
- preexisting bug
- scary-looking code that is safe due to caller invariant
- irrelevant missing test
- intentional behavior documented in the PR body
- generated file that should be ignored
- auth check done in middleware
- schema compatibility handled elsewhere

The scorer treats published trap claims as noise and records the trap category when available.

## Difficulty Labels

Expected claims can include metadata:

```json
{
  "id": "tenant-isolation-leak",
  "category": "security",
  "severity": "critical",
  "required_context": ["route", "middleware", "tenant_model"],
  "difficulty": "hard",
  "expected_evidence_tier": 3,
  "specialist": "security"
}
```

Reports write `score-slices.json` so experiments can be analyzed by:

- category
- severity
- difficulty
- required context
- specialist type
- expected evidence tier

## Anti-Overfitting Warnings

Sugary flags suspicious behavior, including:

- exact oracle wording in reviewer claims
- fixture-specific case names in reviewer claims
- perfect score on `train` or `dev`
- no failures across hard cases

These warnings do not prove cheating. They say the benchmark may be too easy or the reviewer may be too fixture-shaped.

## Fixture Coverage Matrix v2

Hard-suite reports write `coverage-matrix-v2.json`.

Expected-claim rows include:

```text
Case | Expected Claim | Required Context | Difficulty | Reviewer Hits
```

Trap rows include:

```text
Case | Trap | Trap Category | Reviewer Hits
```

The matrix is meant to make blind spots obvious before building new specialists.

## Hard-Suite Commands

Build the CLI:

```sh
mix escript.build
```

Run the hard-suite experiment:

```sh
./sugary experiment run experiments/pcrs-hard-fixtures-v0.toml
```

Run a holdout smoke:

```sh
./sugary bench run --suite agent-written-hard-fixtures --split holdout --method baseline-diff-only
```

Run complementarity search:

```sh
./sugary team search --pack reviewer-packs/baseline-pack-v0.toml --suite agent-written-hard-fixtures --split holdout --max-team-size 3
```

## Interpretation

A perfect reviewer on local fixtures is not enough to promote a product claim.

Useful promotion evidence requires:

- non-oracle methods
- blind holdout results
- unsaturated fixtures
- complementarity headroom when arguing for teams
- controlled noise through evidence gates, refutation, and ranking
- local benchmark results clearly separated from public benchmark claims

If the hard suite saturates, add harder fixtures or move to real local benchmark adapters before claiming architecture superiority.

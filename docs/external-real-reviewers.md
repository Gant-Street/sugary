# External Real Reviewers v0

External reviewers are opt-in command adapters. They can produce claims, but they cannot publish comments directly.

Sugary remains responsible for:

- validating `ReviewerResult` JSON
- storing artifacts
- replay/cache behavior
- proof/evidence gates
- merge and dedupe
- scoring
- reports
- promotion decisions

## Pack Manifest

External pack:

```text
reviewer-packs/external-real-pack-v0.toml
```

Reviewer shape:

```toml
[[reviewers]]
id = "semgrep-json"
type = "command"
enabled = false
required_executable = "semgrep"
command = "elixir"
args = ["scripts/reviewers/semgrep_reviewer.exs"]
timeout_ms = 120000
capabilities = ["static_analysis", "security"]
cost_model = "free_local"
requires_network = false
requires_secrets = []
```

Rules:

- Real tools are disabled by default.
- Missing tools produce skip artifacts, not failed test suites.
- CI does not require Semgrep, opencode, Claude Code, Codex, model provider keys, or network access.
- External outputs are untrusted and are scored like any other reviewer output.

## Availability

Check a pack:

```sh
./sugary reviewers check --pack reviewer-packs/external-real-pack-v0.toml
```

Output includes:

- available reviewers
- missing executables
- missing required env vars
- disabled reviewers
- cost model
- network requirement
- safe-to-run status

## Command Contract

External commands receive:

```text
stdin:
  ReviewInputBundle JSON
```

They must emit:

```text
stdout:
  ReviewerResult JSON
```

They may emit diagnostics to stderr. Sugary captures and redacts stderr.

Exit behavior:

- `0` plus valid JSON: success
- non-zero: reviewer failure
- timeout: reviewer failure
- invalid JSON: reviewer failure
- schema-invalid JSON: reviewer failure
- disabled/missing requirement: skipped reviewer result

Reviewer failure or skip never lets an external tool publish a comment.

## Normalizers

Included wrappers:

- `scripts/reviewers/generic_json_reviewer.exs`
- `scripts/reviewers/semgrep_reviewer.exs`
- `scripts/reviewers/text_to_reviewer_result.exs`

`text_to_reviewer_result.exs` is intentionally conservative. It wraps plain text as low-confidence claims because unstructured text has weak evidence and weak introduced-by-PR support.

Claims should include:

- claim id
- summary
- path
- line/range when available
- severity
- category
- confidence
- evidence text
- source tool metadata
- raw finding reference

## Quality Checks

External findings receive artifact warnings for:

- missing file path
- missing line
- non-actionable summary
- duplicate findings
- no evidence text
- claims outside changed files, unless allowed
- generated/vendor/dependency paths
- no PR-introducedness argument

Warnings do not automatically reject claims in v0. They make noisy output visible for ranking, refutation, and promotion reports.

## Local Smoke

Run local hard fixtures:

```sh
./sugary experiment run experiments/external-real-pack-local-smoke.toml --replay-mode cache-first
```

Run hard holdout smoke:

```sh
./sugary experiment run experiments/external-real-pack-hard-holdout.toml --replay-mode cache-first
```

Reports answer:

- Does an external reviewer beat the promoted local candidate?
- Does it contribute unique hits?
- Does it add noise?
- Does a hybrid team beat local-only and external-only?
- Which tools should be kept, quarantined, or rejected?

## Public Benchmark Smoke

Martian smoke remains local and unofficial:

```sh
./sugary bench fetch martian-offline --local-only
./sugary experiment run experiments/external-real-pack-martian-smoke.toml --replay-mode cache-first
```

Rules:

- This is an unofficial local smoke only.
- Do not claim official Martian scores.
- Do not submit public benchmark results.
- If the dataset is unavailable, the adapter fails with a setup error.
- Artifacts stay local.

## Adding A Tool

1. Add a disabled reviewer entry to `reviewer-packs/external-real-pack-v0.toml`.
2. Add a wrapper script that reads `ReviewInputBundle` JSON from stdin.
3. Normalize output to `ReviewerResult` JSON.
4. Declare required executable, secrets, cost model, and network requirement.
5. Run `./sugary reviewers check --pack ...`.
6. Run with `--replay-mode cache-first`.
7. Promote only through the locked promotion workflow.

No external reviewer should become a production default without a promotion report.

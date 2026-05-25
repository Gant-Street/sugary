# Autoresearch Loop

Last updated: 2026-05-24

This document turns the PCRS thesis into an operational research machine that can be implemented with `/goal`.

The short version:

> Sugary should run a repeatable loop that ingests research signals, proposes review-method variants, runs them against benchmark fixtures, analyzes misses and false positives, and promotes only the variants that improve proof-carrying review quality under cost, latency, and noise constraints.

The first implementation should be a real research lab, not just scaffolding. It should create the protocol, local fixtures, deterministic reviewers, experiment manifests, scoring, failure analysis, reports, and a local real-benchmark smoke path. It should end by running the first benchmark panel and producing a truthful report.

## Milestone Split

Separate "the lab works" from "PCRS is proven."

Autoresearch Lab v0 should prove that Sugary can run an honest local code-review research experiment and tell us what failed. It should not claim that PCRS is validated unless the promoted methods are non-oracle methods and clear the quantitative theory bar.

### Milestone 1: Protocol And Local Scoring Harness

Goal:

> The harness can run reproducible review experiments, score them, classify failures, and produce a truthful report.

Success bar:

| Metric | Required Result |
| --- | --- |
| Fixture execution | Local fixture suite and agent-written PR fixture suite both run end to end. |
| Artifact completeness | Every experiment writes manifest, input bundles, reviewer results, claims, final reviews, scores, failures, and report. |
| No oracle leakage | Reviewer inputs exclude oracle claims, known non-issues, expected comments, failure labels, scorer outputs, and fixture-specific answer IDs. |
| Scorer correctness | Golden harness-test reviewers produce expected hits, misses, duplicates, and noise classifications. |
| Report honesty | Report distinguishes harness-test methods from research methods and does not claim theory validation from oracle-backed methods. |
| Martian smoke | Martian offline adapter can fetch or fail clearly; if data is available locally, it can run a small subset and write artifacts. |

### Milestone 2: Honest PCRS Ablation

Milestone 2 is where we test the current theory:

Current theory:

> A proof-carrying, adversarially-refuted, benchmark-calibrated review agent specialized first for agent-written PRs is the best fundamental approach to AI code review.

PCRS is only promoted if the best non-oracle PCRS variant beats the strongest implemented non-oracle baseline on the local agent-written PR suite and does not regress on the Martian offline smoke subset.

Theory success bar:

| Metric | Required Result |
| --- | --- |
| Local agent-written PR suite usefulness | PCRS improves usefulness by at least 20% relative to best baseline. |
| Local agent-written PR suite SNR | PCRS improves SNR by at least 30% relative to best baseline. |
| Local agent-written PR suite recall | PCRS recall is no more than 5% worse than best baseline, or is higher. |
| Comment budget | PCRS publishes at most 3 comments per PR on average. |
| Noise | PCRS produces fewer noise comments than the best baseline. |
| Martian offline smoke subset | PCRS does not perform worse than best baseline on usefulness or SNR. |
| Report quality | Report names the winning method, losing methods, failure clusters, and next experiment. |

If the bar is not hit, the run should still finish with a falsification report explaining which part of the theory failed: candidate generation, context retrieval, evidence construction, refutation, ranking, or benchmark fit. That is a valid research outcome, but it is not a success claim.

## Operating Model

Sugary should run research as a product discipline, not as ad hoc prompting.

Every proposed improvement should pass through the same lifecycle:

```text
research signal
  -> hypothesis
  -> method variant
  -> benchmark run
  -> scorecard
  -> failure analysis
  -> decision
  -> promotion or rejection
```

The loop has two clocks:

- Inner loop: run a benchmark experiment on a concrete method variant.
- Outer loop: ingest research, analyze aggregate failures, and choose the next experiments.

The inner loop should be executable by CLI. The outer loop can be assisted by agents at first, but decisions should remain explicit and committed as artifacts.

## Autonomy Levels

Start with conservative autonomy.

| Level | Name | Behavior | Use Now |
| --- | --- | --- | --- |
| L0 | Manual research notes | Humans write hypotheses and inspect results. | Yes |
| L1 | Assisted experiment planning | Agent proposes experiment manifests, but humans approve. | Yes |
| L2 | Automated benchmark runs | CLI runs methods, scores results, and writes reports. | Yes |
| L3 | Disposable implementation experiments | Agent creates a branch or worktree, implements a variant, runs benchmarks, and reports. | Later |
| L4 | Continuous autoresearch | Scheduled jobs ingest sources, propose patches, run benchmarks, and open PRs. | Much later |

The first `/goal` should implement L0 through L2. Do not start with self-modifying research agents. The useful foundation is artifact discipline.

## What We Are Trying To Learn

The loop should answer:

- Which reviewer strategies find real defects?
- Which strategies produce noise?
- Which context retrieval strategies improve recall?
- Which proof gates improve signal-to-noise?
- Which refuters catch false positives?
- Which comment shapes help a coding agent produce a correct fix?
- Which models are worth their cost in each role?
- Which review team topologies outperform a single reviewer?
- Which benchmark improvements transfer to fresh holdouts and real PRs?

The loop should not optimize for:

- Number of comments.
- Impressive-looking comments.
- One benchmark leaderboard.
- One model vendor.
- Prompt cleverness without measured lift.

## Core Artifacts

All research should be reproducible from files.

Suggested artifact layout:

```text
.sugary/
  research/
    sources/
      papers/
      benchmarks/
      competitor-outputs/
    claims/
      research-claims.jsonl
    experiments/
      pcrs-first-ablation.toml
    runs/
      2026-05-24T120000Z-pcrs-first-ablation/
        manifest.toml
        input-bundles/
        reviewer-results/
        claims/
        final-reviews/
        scores.json
        failures.jsonl
        report.md
    leaderboards/
      local-fixtures.json
      martian-offline.json
      cr-bench.json
```

For the repository itself:

```text
apps/
  cli/

packages/
  protocol/
  config/
  git/
  input-bundle/
  reviewers/
  review-runner/
  evidence/
  refutation/
  synthesis/
  evals/
  research/
  trace/

fixtures/
  review/
    null-guard/
    missing-auth/
    preexisting-bug/
    weak-heuristic/
    missing-test/

experiments/
  pcrs-first-ablation.toml
```

Research outputs should be committed when they define reusable fixtures, schemas, or experiment manifests. Large benchmark run outputs should usually stay as local artifacts unless they are curated reports.

## CLI Shape

Initial commands:

```sh
sugary research init
sugary research ingest --source docs/pcrs.md
sugary research list-claims
sugary bench list
sugary bench run --suite local-fixtures --method baseline-diff-only
sugary bench fetch martian-offline --local-only
sugary bench run --suite martian-offline --method baseline-diff-only --limit 5 --local-only
sugary experiment run experiments/pcrs-first-ablation.toml
sugary experiment report .sugary/research/runs/<run-id>
sugary failures list .sugary/research/runs/<run-id>
```

Later commands:

```sh
sugary research ingest --source arxiv:2603.11078
sugary research propose --from .sugary/research/runs/<run-id>
sugary experiment compare --baseline baseline-diff-only --candidate pcrs-evidence-refuter
sugary team score --team teams/default-pcrs.toml --suite local-fixtures
sugary bench fetch martian-offline
sugary bench import cr-bench
sugary bench import c-crab
```

## Module Design

### Research Orchestrator

Coordinates the loop:

- Load experiment manifest.
- Resolve benchmark suites.
- Resolve method variants.
- Run review pipeline for each case.
- Score outputs.
- Analyze failures.
- Write report.
- Update local leaderboard.

It should be deterministic where possible. If a model call is nondeterministic, the run should record model, provider, temperature, prompt hash, and output.

### Source Ingester

Turns papers, docs, benchmark pages, competitor outputs, and internal notes into structured research claims.

Input examples:

- `docs/pcrs.md`
- arXiv paper metadata and excerpts.
- Martian benchmark update notes.
- Local benchmark failure reports.
- Competitor review comments captured from benchmark PRs.

Output:

```json
{
  "id": "research-claim-hyperagent-navigator-001",
  "source": {
    "title": "HyperAgent",
    "url": "https://arxiv.org/html/2409.16299v1",
    "retrievedAt": "2026-05-24T12:00:00Z"
  },
  "claim": "Navigator role is critical for repo-scale software engineering tasks.",
  "evidence": "Reported GPT-4o SWE-bench Tiny pass rate drops from 15% to 7% without Navigator.",
  "component": "repo_navigation",
  "prediction": "Navigator-assisted context retrieval should improve cross-file review recall.",
  "experiment": "Compare diff-only vs symbol graph vs navigator-assisted review on local and public suites.",
  "status": "candidate"
}
```

The first implementation can use hand-authored JSON files and simple markdown extraction. LLM-assisted extraction can come later.

### Oracle Boundary

Benchmark oracles are scorer-only data.

Reviewer pipelines must never read:

- `oracle.expectedClaims`
- `oracle.knownNonIssues`
- `expected/final-review.md`
- failure labels
- scorer outputs
- fixture-specific answer IDs
- benchmark gold comments

Only the scorer, failure analyzer, and report writer may read oracle fields. `ReviewInputBundle` must contain the diff, PR metadata, allowed repository context, policy, and method configuration, but not the answer key.

No method variant used for theory promotion may read fixture oracle data, expected claims, known non-issues, scorer labels, or fixture-specific IDs. Oracle-backed reviewers are allowed only for harness unit tests and must be excluded from promotion scorecards.

### Method Grammar

Defines the searchable space of review methods.

The first grammar should be explicit, small, and versioned:

```yaml
context:
  diff_only:
    description: "Only changed hunks and PR metadata."
  changed_files:
    description: "Diff plus full changed files within token budget."
  symbol_graph_stub:
    description: "Changed symbols and nearby references from simple static extraction."

candidate_generation:
  golden_perfect:
    class: "harness_test"
    description: "Oracle-backed reviewer used only to prove scoring."
  golden_noisy:
    class: "harness_test"
    description: "Oracle-backed reviewer that emits true positives plus known noise."
  golden_missing_context:
    class: "harness_test"
    description: "Oracle-backed reviewer that intentionally misses cross-file issues."
  golden_duplicate:
    class: "harness_test"
    description: "Oracle-backed reviewer that emits duplicate claims."
  baseline_single_shot:
    class: "research"
    description: "One native reviewer emits claims from the input bundle."
  reflexion_stub:
    class: "research"
    description: "Two-pass candidate generation. Search for misses, then emit claims."

evidence:
  none:
    min_tier: 5
  static_trace_stub:
    min_tier: 3
  fixture_oracle:
    class: "harness_test"
    min_tier: 1

refutation:
  none: {}
  generic_refuter_stub:
    class: "research"
    description: "Generic refuter based on claim provenance, evidence tier, duplication, and introduced-by-PR assessment. It must not read oracle fields."

ranking:
  fixed_threshold:
    description: "Sort by severity, confidence, evidence tier."
  expected_value_stub:
    description: "Use expected review value formula with global weights. It must not use fixture-specific oracle calibration."

comment_style:
  plain_comment: {}
  proof_carrying_comment: {}
```

The grammar is not just configuration. It is the search space for ablations.

Methods are split into two classes:

- `harness_test`: may use oracle-backed deterministic behavior to test scoring, reporting, duplicate detection, and failure classification. These methods are never eligible for theory promotion.
- `research`: may read only `ReviewInputBundle`, method config, and allowed runtime artifacts. These methods are eligible for baseline comparison and future promotion.

### Benchmark Runner

Runs method variants against benchmark cases.

Responsibilities:

- Load benchmark case.
- Build `ReviewInputBundle`.
- Run reviewer or review team.
- Collect `ReviewClaim[]`.
- Run evidence gate.
- Run refuter.
- Run ranker.
- Render final review.
- Score against oracle.
- Persist trace.

Benchmark case format:

```json
{
  "id": "local-null-guard-001",
  "suite": "local-fixtures",
  "repo": {
    "path": "fixtures/review/null-guard/repo",
    "baseSha": "base",
    "headSha": "head"
  },
  "pr": {
    "title": "Add retry path to session loading",
    "body": "Retries transient database errors."
  },
  "oracle": {
    "expectedClaims": [
      {
        "id": "null-user-retry-build-session",
        "category": "bug",
        "severity": "high",
        "path": "src/session.ts",
        "description": "Retry path passes nullable user to buildSession."
      }
    ],
    "knownNonIssues": [
      {
        "id": "style-use-early-return",
        "description": "Do not request style-only early return."
      }
    ]
  }
}
```

### Scorer

The scorer should evaluate claims, not comments.

Core scores:

```json
{
  "cases": 5,
  "expectedClaims": 6,
  "publishedClaims": 7,
  "hits": 4,
  "validSuggestions": 1,
  "noise": 2,
  "suppressedTrueClaims": 1,
  "precision": 0.714,
  "recall": 0.667,
  "f1": 0.69,
  "usefulness": 0.714,
  "snr": 2.5,
  "avgCommentsPerPr": 1.4,
  "estimatedUsd": 0.18,
  "p95LatencyMs": 1200
}
```

Definitions:

- `hit`: published claim matches an expected oracle claim.
- `validSuggestion`: published claim is useful but not the target oracle claim.
- `noise`: published claim is wrong, irrelevant, unsupported, duplicate, or too weak.
- `suppressedTrueClaim`: claim existed internally but was blocked by evidence, refutation, or ranking.
- `precision`: hits plus valid suggestions divided by published claims.
- `recall`: hits divided by expected claims.
- `usefulness`: hits plus valid suggestions divided by published claims.
- `snr`: hits plus valid suggestions divided by noise, with a zero-noise guard.

For c-CRAB-style evaluation, add:

- `agentFixAttempted`
- `agentFixPassed`
- `behavioralPassRate`
- `structuralPassRate`

Do not implement coding-agent repair in v0. Keep the schema ready.

### Failure Analyzer

Classifies every miss and false positive.

False negative categories:

- `missing_context`
- `wrong_symbol_localization`
- `failed_to_understand_requirement`
- `no_test_synthesis`
- `no_runtime_execution`
- `model_reasoning_failure`
- `comment_suppressed_too_aggressively`
- `oracle_disagreement`

False positive categories:

- `preexisting_bug`
- `stylistic_preference`
- `speculative_edge_case`
- `invalid_api_assumption`
- `test_does_not_reproduce`
- `duplicate_comment`
- `low_severity_noise`
- `line_mapping_error`

Failure record:

```json
{
  "id": "failure-local-null-guard-001-fn-1",
  "caseId": "local-null-guard-001",
  "methodId": "baseline-diff-only",
  "type": "false_negative",
  "category": "missing_context",
  "expectedClaimId": "null-user-retry-build-session",
  "summary": "The reviewer did not inspect buildSession and missed the null dereference.",
  "suggestedExperiment": "Add changed-symbol context for callees."
}
```

### Report Writer

Every experiment run should produce a concise report:

```md
# Experiment Report: pcrs-first-ablation

## Decision

Promote `evidence-refuter` to candidate. It improves SNR by 40% at the same recall on local fixtures.

## Scorecard

| Method | Recall | Usefulness | SNR | Avg Comments | Cost |
| --- | --- | --- | --- | --- | --- |

## What Improved

## What Regressed

## Failure Clusters

## Next Experiments
```

The report should be useful to a human before it is useful to an agent.

## Experiment Manifest

The first ablation manifest should be committed in `experiments/pcrs-first-ablation.toml`.

```toml
id = "pcrs-first-ablation"
description = "Measure whether context, evidence gates, and refutation improve local review quality."
suite = "local-fixtures"
max_cost_usd = 1.00
max_duration_seconds = 600

[[methods]]
id = "a-diff-only-single-shot"
context = "diff_only"
candidate_generation = "baseline_single_shot"
evidence = "none"
refutation = "none"
ranking = "fixed_threshold"
comment_style = "plain_comment"

[[methods]]
id = "b-changed-files"
context = "changed_files"
candidate_generation = "baseline_single_shot"
evidence = "none"
refutation = "none"
ranking = "fixed_threshold"
comment_style = "plain_comment"

[[methods]]
id = "c-symbol-graph"
context = "symbol_graph_stub"
candidate_generation = "baseline_single_shot"
evidence = "none"
refutation = "none"
ranking = "fixed_threshold"
comment_style = "plain_comment"

[[methods]]
id = "d-symbol-graph-candidate-swarm"
context = "symbol_graph_stub"
candidate_generation = "reflexion_stub"
evidence = "none"
refutation = "none"
ranking = "fixed_threshold"
comment_style = "plain_comment"

[[methods]]
id = "e-evidence-gate"
context = "symbol_graph_stub"
candidate_generation = "reflexion_stub"
evidence = "static_trace_stub"
refutation = "none"
ranking = "fixed_threshold"
comment_style = "proof_carrying_comment"

[[methods]]
id = "f-adversarial-refutation"
context = "symbol_graph_stub"
candidate_generation = "reflexion_stub"
evidence = "static_trace_stub"
refutation = "generic_refuter_stub"
ranking = "fixed_threshold"
comment_style = "proof_carrying_comment"

[[methods]]
id = "g-calibrated-ranker"
context = "symbol_graph_stub"
candidate_generation = "reflexion_stub"
evidence = "static_trace_stub"
refutation = "generic_refuter_stub"
ranking = "expected_value_stub"
comment_style = "proof_carrying_comment"

[promotion]
min_recall_delta = 0.00
min_snr_delta = 0.10
max_cost_multiplier = 2.00
max_avg_comments_per_pr = 3
```

The first version can use deterministic stubs. The point is to lock the artifact flow and scoring loop before expensive model calls.

## Local Fixture Suite

The first benchmark suite should be tiny but carefully chosen.

Required cases:

| Case | Purpose | Expected Behavior |
| --- | --- | --- |
| `null-guard` | Basic cross-function bug. | Context helps find a concrete failure path. |
| `missing-auth` | Security/authorization issue. | Claim must cite changed route and missing permission check. |
| `preexisting-bug` | False-positive control. | Refuter should suppress bug not introduced by PR. |
| `weak-heuristic` | Noise control. | Ranker should suppress unsupported style/speculation. |
| `missing-test` | Test-gap review. | Claim should name changed behavior and suggested test. |
| `duplicate-claims` | Deduplication. | Multiple generators should collapse to one published claim. |

Each fixture should include:

```text
repo/
  before/
  after/
case.json
expected/
  claims.json
  final-review.md
```

If using real Git commits is too much for v0, start with synthetic `before` and `after` directories and generate diffs from them. Move to real Git repositories once the protocol works.

## Promotion Policy

Do not promote a method because it has one good-looking run.

Promotion requires:

- Scorecard improvement against baseline.
- No material regression in usefulness or SNR.
- Cost within budget.
- Failure analysis reviewed.
- Trace artifacts present.
- At least one new regression fixture if the method was motivated by a prior failure.

Suggested decisions:

- `promote`: becomes default candidate for next experiments.
- `keep_for_mode`: useful only for security, deep, or benchmark mode.
- `reject`: inferior or too noisy.
- `needs_more_data`: inconclusive.
- `quarantine`: promising but unsafe, flaky, or too costly.

## External Benchmark Adapters

Public benchmarks should be runnable locally before Sugary submits anything anywhere. The default posture is local-only: fetch or point at benchmark data, normalize it into Sugary benchmark cases, run experiments, and write local reports. No leaderboard submission, remote result upload, or public claims should happen from the v0 harness.

Order of integration:

1. Local fixtures.
2. Martian offline benchmark.
3. CR-Bench.
4. c-CRAB-style repair evaluation.
5. SWE-bench-derived localization/repair submodules.
6. Fresh online-style holdouts.

Rationale:

- Local fixtures make development fast.
- Martian offline is practical for comparing review comments against curated real PRs.
- CR-Bench directly targets the recall/noise tradeoff.
- c-CRAB is more expensive but closer to behaviorally useful review.
- SWE-bench is useful for submodules, not the primary review metric.
- Fresh holdouts protect against static benchmark overfitting.

Public-source notes:

- Martian's repository advertises offline and online benchmark directories and an open-source evaluation pipeline.
- CR-Bench defines usefulness and SNR metrics around defect-focused review.
- c-CRAB evaluates whether generated review comments guide a coding agent to behaviorally correct fixes.
- HyperAgent and SWE-agent motivate agent-optimized navigation and execution tools.
- Agentless warns against unnecessary open-ended autonomy.

### Local Real Benchmark Mode

Local real benchmark mode should support:

```sh
sugary bench fetch martian-offline --local-only
sugary bench run --suite martian-offline --method baseline-diff-only --limit 5 --local-only
sugary bench run --suite cr-bench --method pcrs-evidence-refuter --local-only
sugary experiment run experiments/pcrs-martian-smoke.toml --local-only
```

Default behavior:

- Store downloaded benchmark metadata under `.sugary/research/benchmarks/` or a user cache path.
- Keep benchmark repositories and large artifacts out of git unless explicitly curated as small fixtures.
- Normalize benchmark cases into `BenchmarkCase` records.
- Write scores and reports locally.
- Never submit to a leaderboard.
- Never publish benchmark claims from a single local run.
- Respect upstream benchmark licenses and terms.

The first real benchmark adapter should be a Martian offline smoke adapter because it is directly code-review focused and has an open repository. The v0 implementation does not need to reproduce the full official scoring pipeline, but it should prove that Sugary can fetch or locate the dataset, enumerate cases, run a small local subset, and write Sugary-native scorecards.

Suggested v0 commands:

```sh
sugary bench fetch martian-offline --local-only
sugary bench list
sugary bench run --suite martian-offline --limit 3 --method baseline-diff-only --local-only
```

Suggested v0 non-goals:

- Do not submit results upstream.
- Do not claim official benchmark scores.
- Do not require network access in unit tests.
- Do not require the full benchmark dataset in the repo.
- Do not block local fixture development on upstream benchmark availability.

## External Reviewer Adapters

External tools should be first-class reviewers.

Generic command adapter:

```toml
[[reviewers]]
id = "opencode-review"
type = "command"
command = "opencode"
args = ["run", "/review", "--json"]
timeout_ms = 900000
network = "inherit"
env_allowlist = ["OPENCODE_API_KEY"]
```

Adapter contract:

```text
stdin: ReviewInputBundle JSON
stdout: ReviewerResult JSON
stderr: captured and redacted logs
exit 0: success if stdout is valid ReviewerResult JSON
exit non-zero: reviewer failure, not experiment failure
```

Never let external reviewers publish comments directly. They produce claims. Sugary verifies, ranks, and publishes.

## Security And Budget Guardrails

The research loop can run untrusted code, external CLIs, and model calls. It needs hard boundaries.

Defaults:

- No secrets in traces.
- Redact environment variables from logs.
- Per-run cost cap.
- Per-method cost cap.
- Per-reviewer timeout.
- Network off for fixture execution unless explicitly enabled.
- No auto-promotion to production defaults.
- No self-modifying code in the main worktree.
- No automatic pushes or PRs in v0.

When L3 autonomy is added:

- Use isolated worktrees.
- Use branch prefix `codex/research-`.
- Require benchmark report before commit.
- Require human approval before merge.

## First `/goal` To Run

Use this as the first implementation request:

### Compact Prompt

This prompt is under 4,000 characters.

```text
Implement Autoresearch Lab v0: Protocol + Local Scoring Harness for Sugary.

Build an Elixir-first Mix CLI. Primary objective: create a reproducible local research loop for proof-carrying code review experiments. v0 proves the lab works; it must not claim PCRS theory validation.

Implement:
- Protocol structs/schemas: ReviewInputBundle, ReviewClaim, Evidence, ReviewerResult, BenchmarkCase, ExperimentManifest, Scorecard, FailureRecord.
- No-oracle boundary: reviewers never see oracle.expectedClaims, knownNonIssues, expected comments, failure labels, scorer outputs, fixture answer IDs, or gold comments. Only scorer/failure/report may read oracle. Oracle-backed methods are harness_test only and excluded from promotion.
- CLI: sugary research init; sugary bench list; sugary bench fetch martian-offline --local-only; sugary bench run --suite local-fixtures --method <id>; sugary bench run --suite martian-offline --method <id> --limit 3 --local-only; sugary experiment run experiments/pcrs-first-ablation.toml; sugary experiment report <run-dir>.
- Harness-test reviewers: golden-perfect, golden-noisy, golden-missing-context, golden-duplicate.
- Non-oracle research stubs: diff-only baseline, changed-files baseline, symbol-graph stub, reflexion stub, evidence gate, generic refuter, expected-value ranker.
- Fixtures: null-guard, missing-auth, preexisting-bug, weak-heuristic, missing-test, duplicate-claims; agent-written slice: hallucinated-api, plausible-wrong-logic, missing-edge-case-test, overbroad-refactor, weak-auth-generated-route, integration-contract-mismatch.
- Martian offline smoke adapter: fetch/locate locally, enumerate cases, run small subset, write Sugary artifacts; clear setup error if unavailable.
- Experiment manifests: pcrs-first-ablation.toml and pcrs-agent-pr-first-proof.toml. Mark theory ablation as non-validating unless all promoted methods are non-oracle.

Every experiment writes .sugary/research/runs/<run-id>/{manifest.toml,input-bundles,reviewer-results,claims,final-reviews,scores.json,failures.jsonl,report.md}. Scorer reports hits, valid suggestions, noise, suppressed true claims, precision, recall, F1, usefulness, SNR, avg comments/PR, cost, latency. Failure analyzer uses docs taxonomy. Run harness validation before finishing and write lab success/failure report.

Tests: schema validation, fixture loading, no-oracle enforcement, scoring, failure classification, manifest parsing, report generation. README quickstart.

Non-goals: no real model providers, GitHub comments, public benchmark submission/official score claims, network in unit tests, full Martian dataset in repo, c-CRAB repair, self-modifying agents, hosted dashboard.
```

### Full Prompt

```text
Implement Autoresearch Lab v0: Protocol + Local Scoring Harness for Sugary.

Build and run the protocol-first local benchmark and experiment harness described in docs/autoresearch-loop.md. This is an Elixir-first research runner, not a hosted product.

Primary objective:

Create a reproducible local research loop that can run review method variants against fixture suites, score claims, classify failures, and produce truthful experiment reports.

Important distinction:

- v0 proves the lab works.
- v0 does not prove the PCRS theory.
- The final report may say a PCRS stub passed a local ablation, but it must not claim the PCRS theory is validated unless all promoted methods are non-oracle methods and the theory success bar is met.

Harness success bar:

- Local fixture suite and agent-written PR fixture suite both run end to end.
- Every experiment writes manifest, input bundles, reviewer results, claims, final reviews, scores, failures, and report.
- Reviewer inputs exclude oracle claims, known non-issues, expected comments, failure labels, scorer outputs, and fixture-specific answer IDs.
- Golden harness-test reviewers produce expected hits, misses, duplicates, and noise classifications.
- Reports distinguish harness-test methods from research methods.
- Martian offline smoke adapter can fetch or fail clearly; if data is available locally, it can run a small subset and write artifacts.

Acceptance criteria:

- Create an Elixir Mix project or umbrella suitable for a research runner CLI.
- Add protocol schemas for ReviewInputBundle, ReviewClaim, Evidence, ReviewerResult, BenchmarkCase, ExperimentManifest, BenchmarkRunResult, Scorecard, and FailureRecord.
- Add a no-oracle-leakage boundary between reviewer inputs and scorer-only fields.
- Add a CLI with:
  - sugary research init
  - sugary bench list
  - sugary bench fetch martian-offline --local-only
  - sugary bench run --suite local-fixtures --method <method-id>
  - sugary bench run --suite martian-offline --method <method-id> --limit 3 --local-only
  - sugary experiment run experiments/pcrs-first-ablation.toml
  - sugary experiment report <run-dir>
- Add deterministic harness-test reviewers:
  - golden-perfect-reviewer
  - golden-noisy-reviewer
  - golden-missing-context-reviewer
  - golden-duplicate-reviewer
- Add honest non-oracle method stubs for:
  - diff_only + baseline_single_shot
  - changed_files + baseline_single_shot
  - symbol_graph_stub + baseline_single_shot
  - symbol_graph_stub + reflexion_stub
  - evidence gate
  - rule-based generic refutation
  - expected-value ranker stub
- Add local fixture suite with at least:
  - null-guard
  - missing-auth
  - preexisting-bug
  - weak-heuristic
  - missing-test
  - duplicate-claims
- Add an agent-written PR fixture slice with at least:
  - hallucinated-api
  - plausible-wrong-logic
  - missing-edge-case-test
  - overbroad-refactor
  - weak-auth-generated-route
  - integration-contract-mismatch
- Add benchmark adapter interface plus a Martian offline smoke adapter that can fetch or locate the benchmark locally, enumerate cases, run a small subset, and write Sugary-native artifacts. If the upstream dataset is unavailable, the command should fail with a clear setup error rather than silently passing.
- Add experiments/pcrs-first-ablation.toml.
- Add experiments/pcrs-agent-pr-first-proof.toml, but mark it as a theory ablation that cannot validate PCRS unless all promoted methods are non-oracle methods.
- Running the experiment writes:
  - .sugary/research/runs/<run-id>/manifest.toml
  - input bundles
  - reviewer results
  - claims
  - final reviews
  - scores.json
  - failures.jsonl
  - report.md
- The scorer reports hits, valid suggestions, noise, suppressed true claims, precision, recall, F1, usefulness, SNR, average comments per PR, cost, and latency.
- The failure analyzer classifies false negatives and false positives using the taxonomy in docs/autoresearch-loop.md.
- Run the harness validation experiment before finishing and write a final lab success or lab failure report.
- Add unit tests for schema validation, fixture loading, scoring, failure classification, experiment manifest parsing, and report generation.
- Add README quickstart instructions for running the local autoresearch loop.

Non-goals:

- Do not integrate real model providers.
- Do not integrate GitHub comments.
- Do not submit public benchmark results or claim official scores.
- Do not require network access in unit tests.
- Do not require the full Martian dataset to be checked into this repo.
- Do not implement coding-agent repair for c-CRAB.
- Do not add self-modifying research agents.
- Do not build a hosted dashboard.
```

## Second `/goal` To Run

After v0 works:

```text
Add the first external reviewer command adapter and make it usable in Autoresearch Loop experiments.

Acceptance criteria:

- Add a command reviewer adapter that passes ReviewInputBundle JSON to an external process and reads ReviewerResult JSON from stdout.
- Add timeout, exit-code, stderr capture, and log redaction.
- Add per-reviewer cost and artifact fields, even if external tools do not report cost yet.
- Add a sample command reviewer that wraps a local script fixture.
- Add docs showing how opencode, Claude Code, Codex, Semgrep, or an internal tool can be adapted once their JSON output format is known.
- Add tests for successful command output, invalid JSON, timeout, non-zero exit, and redaction.

Non-goals:

- Do not require opencode, Claude Code, Codex, or Semgrep to be installed in CI.
- Do not publish external reviewer comments directly.
```

## Third `/goal` To Run

After the command adapter works:

```text
Add Review Team v0 to the autoresearch harness.

Acceptance criteria:

- Add ReviewTeam manifest schema.
- Allow one or more reviewers per method variant.
- Run reviewers sequentially first, with a clear interface for future parallelism.
- Merge reviewer claims by dedupe key and location.
- Preserve per-reviewer provenance.
- Add team scorecards.
- Add a default local team and a proof-carrying team.
- Add tests for dedupe, provenance, reviewer failure isolation, and score aggregation.

Non-goals:

- Do not build a public team registry.
- Do not add billing or hosted execution.
```

## When To Leave The Research Loop And Build Product

Move toward GitHub Action and hosted product only when:

- The local loop can compare methods reproducibly.
- The proof object schema is stable enough.
- At least one method beats baseline on local fixtures.
- False-positive suppression is visible in scorecards.
- External reviewer adapter exists or has a clear contract.
- Reports are good enough to guide decisions.

This keeps Sugary from becoming another comment bot before the review science is working.

## Sources

- [CR-Bench: Evaluating the Real-World Utility of AI Code Review Agents](https://arxiv.org/html/2603.11078v1)
- [Code Review Agent Benchmark / c-CRAB](https://arxiv.org/html/2603.23448v1)
- [HyperAgent: Generalist Software Engineering Agents to Solve Coding Tasks at Scale](https://arxiv.org/html/2409.16299v1)
- [SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering](https://arxiv.org/abs/2405.15793)
- [Agentless: Demystifying LLM-based Software Engineering Agents](https://arxiv.org/abs/2407.01489)
- [The AI Scientist: Towards Fully Automated Open-Ended Scientific Discovery](https://arxiv.org/abs/2408.06292)
- [Martian Code Review Bench repository](https://github.com/withmartian/code-review-benchmark)
- [Martian Code Review Bench announcement](https://withmartian.com/post/code-review-bench-v0)

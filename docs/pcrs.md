# Proof-Carrying Review Search

Last updated: 2026-05-24

Proof-Carrying Review Search, or PCRS, is Sugary's core technical thesis:

> Winning AI code review will come from proof-carrying review search, not from better PR comments. The reviewer should generate many possible defect hypotheses, then only publish comments that survive evidence construction, adversarial refutation, and benchmark-calibrated ranking.

Most AI review tools are comment generators. They look at a diff, retrieve some context, and emit plausible suggestions. That creates a structural recall/noise tradeoff: asking harder for defects increases the number of real issues found, but it also increases unsupported comments. Sugary should instead treat every candidate review as a claim that must carry a proof object.

The durable product is not a single prompt, model, or reviewer. It is the system that can search broadly, prove narrowly, refute aggressively, rank by expected value, and stay quiet when evidence is weak.

## Core Theory

The best automated reviewer is not the model that can imagine the most possible bugs. It is the system that can:

- Search for many defect hypotheses.
- Localize each hypothesis to the changed code and relevant context.
- Construct evidence for the hypothesis.
- Try to disprove the hypothesis.
- Rank surviving claims by expected review value.
- Publish a small number of comments with enough proof to be useful.

This makes the internal unit of work a `ReviewClaim`, not a PR comment.

```json
{
  "claim": "This PR allows a deleted user to reach buildSession after a retry.",
  "location": {
    "path": "src/session.ts",
    "startLine": 42,
    "endLine": 45
  },
  "introducedByPr": true,
  "failurePath": [
    "the new retry branch calls loadUser",
    "loadUser can return null",
    "the retry branch passes the result to buildSession",
    "buildSession reads user.id without a guard"
  ],
  "evidence": [
    {
      "type": "static_trace",
      "strength": "strong",
      "summary": "The non-retry branch checks for null, but the retry branch does not."
    }
  ],
  "counterarguments": [
    {
      "source": "critic",
      "summary": "No caller-level guard exists on the retry path.",
      "status": "rejected"
    }
  ],
  "confidence": 0.82,
  "severity": "high",
  "suggestedFix": "Return early when the retried lookup returns null.",
  "suggestedTest": "Add a test where the first lookup throws and the retry returns null.",
  "publishDecision": "publish"
}
```

Only after a claim survives verification does it become a human-facing comment.

## Research Signals

The current public research points toward PCRS:

| Signal | What It Suggests | Design Implication |
| --- | --- | --- |
| CR-Bench | Iterative search can improve recall but harm usefulness and signal-to-noise. In the reported GPT-5.2 run, Reflexion improved recall from 27.01% to 32.76%, while usefulness dropped from 83.63% to 66.10% and SNR from 5.11 to 1.95. | Search harder, but do not publish raw search output. Add verifier, refuter, and ranker gates. |
| c-CRAB | Review quality is better measured by whether a comment helps a coding agent produce a behaviorally correct fix than by semantic similarity to human text. Current tools in the paper solve 20.1% to 32.1% individually, and the union of four tools covers 41.5%. | Comments should be shaped as debuggable claims with failure path, fix, and test. |
| HyperAgent | Repository navigation is a central capability. The reported GPT-4o ablation dropped SWE-bench Tiny pass rate from 15% to 7% without the Navigator and increased average cost from $0.42 to $2.81. | Navigation and context retrieval should be first-class, agent-optimized components. |
| SWE-agent | Agent-computer interface design materially affects repository navigation, editing, and test execution. | Sugary should expose tools built for reviewer agents, not just dump diffs into prompts. |
| Agentless | Simple localization, repair, and validation phases can outperform more open-ended agent designs on SWE-bench Lite. | Do not worship multi-agent complexity. Use fixed phases and only add agents where ablations show lift. |
| Martian Code Review Bench | Static benchmarks can be gamed or leaked; pairing offline benchmarks with fresh online-style evaluation improves robustness. | Optimize across multiple benchmarks and fresh holdouts, not a single leaderboard. |
| AI Scientist-style loops | Automated research workflows are plausible when grounded in external scoring signals. | Build an autoresearch loop around benchmark feedback, not vibes. |

## System Pattern

Sugary should be a protocol-first hexagonal pipeline:

```text
GitHub PR / Local Branch
        |
        v
ReviewInputBundle
        |
        v
Candidate Generation
        |
        v
ReviewClaims
        |
        v
Evidence Construction
        |
        v
Adversarial Refutation
        |
        v
Benchmark-Calibrated Ranking
        |
        v
Final Review
        |
        v
Publisher
```

All reviewer engines are adapters. They can be native Sugary reviewers, model providers, Claude Code, opencode, Codex, Semgrep, custom shell commands, or internal company agents. They do not publish directly. They produce claims.

The core owns:

- Protocol schemas.
- Input bundle construction.
- Reviewer execution.
- Tool sandboxing.
- Evidence storage.
- Refutation.
- Ranking.
- Synthesis.
- Publishing.
- Evaluation.

This keeps the system open while preserving product quality.

## Review Claim Lifecycle

### 1. Candidate Generation

The candidate generation stage maximizes recall. It should intentionally generate more hypotheses than the product will publish.

Potential generators:

| Generator | Purpose |
| --- | --- |
| Diff semantic reviewer | Finds changed-line bugs and local regressions. |
| Symbol impact reviewer | Follows changed functions, classes, and exports through references. |
| Contract reviewer | Checks schemas, types, API contracts, permissions, migrations, and feature flags. |
| Test-gap reviewer | Finds missing or weakened tests for changed behavior. |
| Historical reviewer | Searches prior PRs, issues, and dismissed comments for project-specific patterns. |
| Adversarial input reviewer | Asks which input, state, or timing condition breaks the change. |
| Security reviewer | Checks auth, tenant isolation, injection, secrets, and unsafe defaults. |
| Runtime reviewer | Looks for issues visible through execution, logs, environment, or state assumptions. |

This is the stage where review teams matter. Different reviewers can search different parts of the defect space.

### 2. Evidence Construction

Each candidate should be converted into evidence. Evidence is graded by strength.

| Tier | Evidence Type | Meaning |
| --- | --- | --- |
| 1 | Executable failing test | The bug can be made to fail before a fix and pass after a fix. |
| 2 | Reproducible command or trace | Build, typecheck, lint, static analyzer, API call, script, or runtime trace proves the issue. |
| 3 | Static path proof | Sugary can show a concrete data or control path from changed code to failure. |
| 4 | Contract or spec mismatch | The PR violates an issue requirement, schema, permission model, API contract, or documented invariant. |
| 5 | Weak heuristic | The idea is plausible but not enough to comment by default. |

Default production review should publish Tier 1 through strong Tier 4 claims. Tier 5 should usually be suppressed, stored for analysis, or shown only in deep/security modes.

### 3. Adversarial Refutation

Before publishing, Sugary should try to kill each claim.

Refuters ask:

- Is this behavior pre-existing?
- Is it actually introduced by the PR?
- Is the claim contradicted by tests, types, or code?
- Is there a caller-level guard?
- Is the severity exaggerated?
- Is the suggested fix wrong or incomplete?
- Is the comment too speculative for a human reviewer?
- Is this already covered by another finding?

The refuter should have independent context and, when useful, a different model or tool stack than the proposer.

### 4. Ranking

Ranking should estimate expected review value:

```text
expected_review_value =
  P(real_defect)
  * P(introduced_by_pr)
  * severity_weight
  * fixability
  * evidence_strength
  * benchmark_calibration
  - developer_noise_cost
```

Thresholds should differ by mode:

| Mode | Ranking Posture |
| --- | --- |
| Production default | High precision, small number of comments. |
| Security | Higher recall, more tolerance for supported warnings. |
| Agent-written PR | Higher recall and stronger verification because generated code may have different defect distributions. |
| Benchmark | Optimize benchmark-specific F1, usefulness, SNR, or c-CRAB pass rate. |
| Deep | Higher budget and more cross-file exploration. |

### 5. Publication

Published comments should be proof-carrying but concise.

Human-facing comments should include:

- Claim.
- Impact.
- Evidence.
- Suggested fix.
- Suggested test or verification path.
- Confidence or severity when useful.

They should not include:

- Raw internal debate.
- Unsupported speculation.
- Multiple weak alternatives.
- Model provenance unless requested.
- Praise or generic summaries.

## Review Teams

PCRS makes review teams concrete. A team is not just "run three models." A team is a search topology.

Example:

```toml
name = "sugary/default-pcrs"
version = "0.1.0"
description = "Balanced low-noise proof-carrying review team."

[[reviewers]]
id = "diff-semantic"
type = "native"
role = "candidate_generator"
focus = ["logic", "changed_lines"]

[[reviewers]]
id = "symbol-impact"
type = "native"
role = "navigator"
focus = ["call_graph", "references", "tests"]

[[reviewers]]
id = "claude-code"
type = "command"
role = "candidate_generator"
command = "claude"
args = ["code", "review", "--json"]
timeout_ms = 900000

[[reviewers]]
id = "semgrep"
type = "command"
role = "evidence_builder"
command = "semgrep"
args = ["scan", "--json"]
timeout_ms = 300000

[[reviewers]]
id = "independent-refuter"
type = "native"
role = "refuter"
model = "openai:gpt-5.1"

[synthesis]
strategy = "proof_carrying"
max_comments = 8
min_evidence_tier = 4
publish_disagreements = false
```

Community and commercial review teams can package:

- Reviewer roster.
- Roles.
- Prompts.
- Model routing.
- Budgets.
- Supported languages and frameworks.
- Evidence requirements.
- Refutation strategy.
- Synthesis policy.
- Eval scorecards.

This is the network effect: users can build and share review teams, while Sugary can publish recommended and premium teams with measured performance.

## Harness Design

PCRS requires two harnesses.

### Review Harness

The review harness runs reviewers in a controlled way. It gives each reviewer normalized input and requires structured output.

```text
reviewer(input_bundle, reviewer_config) -> reviewer_result
```

Reviewer output must be structured:

```json
{
  "reviewerId": "symbol-impact",
  "claims": [],
  "artifacts": [],
  "cost": {
    "estimatedUsd": 0.12,
    "actualUsd": 0.11
  },
  "timing": {
    "startedAt": "2026-05-24T12:00:00Z",
    "finishedAt": "2026-05-24T12:01:12Z"
  }
}
```

Required controls:

- Timeouts.
- Cost limits.
- Network policy.
- Secret policy.
- Sandbox policy.
- Artifact capture.
- Log redaction.
- Deterministic replay where possible.

### Evaluation Harness

The evaluation harness measures reviewers, proof gates, team topologies, and ranking policies.

It consumes the same artifacts as production:

```text
input_bundle.json
team.json
reviewer_results/*.json
claims/*.json
final_review.json
trace.jsonl
```

This avoids a split between product code and benchmark code.

## Autoresearch Loop

Sugary should be built as an autoresearch lab first and a product second. The product emerges from the system that wins repeatable evaluations.

See [docs/autoresearch-loop.md](autoresearch-loop.md) for the operational `/goal`-ready plan, including commands, artifacts, schemas, local fixtures, and staged implementation prompts.

```text
papers + benchmark results + competitor outputs
        |
        v
research claim extractor
        |
        v
method grammar / architecture search
        |
        v
implementation generator
        |
        v
benchmark runner
        |
        v
failure analyzer
        |
        v
new hypotheses
```

### Literature Ingester

For each paper, blog post, or benchmark update, extract:

```json
{
  "source": "HyperAgent",
  "claim": "Navigator role is critical for repo-scale software engineering tasks.",
  "evidence": "Ablation without Navigator reduced GPT-4o SWE-bench Tiny pass rate from 15% to 7%.",
  "component": "repo_navigation",
  "prediction": "Better navigation should improve cross-file review recall.",
  "experiment": "Compare diff-only, symbol graph, and navigator-assisted review on CR-Bench and Martian subsets."
}
```

### Method Grammar

The loop should search over components, not random prompts.

```yaml
context:
  - diff_only
  - changed_symbol_graph
  - dependency_slice
  - test_slice
  - issue_plus_pr_plus_repo
  - historical_pr_memory

candidate_generation:
  - single_shot
  - reflexion
  - tree_search
  - specialist_swarm
  - adversarial_input_generation

evidence:
  - none
  - static_trace
  - typecheck
  - unit_test_synthesis
  - mutation_test
  - contract_check

refutation:
  - none
  - same_model_self_critique
  - independent_model
  - tool_backed_refuter

ranking:
  - fixed_threshold
  - learned_calibrator
  - benchmark_specific_threshold
  - severity_weighted_expected_value

comment_style:
  - plain_comment
  - failure_path
  - suggested_patch
  - suggested_test
  - proof_carrying_comment
```

### Benchmark Suite

Sugary should evaluate against multiple signals:

| Benchmark | Purpose |
| --- | --- |
| Martian Code Review Bench offline | Reproducible comparison against real PRs and golden comments. |
| Martian online-style holdouts | Fresh PRs and developer-action-like evaluation to reduce benchmark leakage. |
| CR-Bench and CR-Bench Verified | Defect-focused review metrics including recall, usefulness, and SNR. |
| c-CRAB | Test-based measure of whether comments lead to behaviorally correct fixes. |
| SWE-bench and SWE-bench Verified | Secondary evaluation for localization, repair, and validation submodules. |
| Internal regression fixtures | Every serious miss and false positive becomes a fixture. |

### Failure Analyzer

Each missed issue and false positive should be classified.

```yaml
false_negative_reason:
  - missing_context
  - wrong_symbol_localization
  - failed_to_understand_requirement
  - no_test_synthesis
  - no_runtime_execution
  - model_reasoning_failure
  - comment_suppressed_too_aggressively
  - benchmark_gold_issue_not_actionable

false_positive_reason:
  - preexisting_bug
  - stylistic_preference
  - speculative_edge_case
  - invalid_api_assumption
  - test_does_not_reproduce
  - duplicate_comment
  - low_severity_noise
```

The failure analyzer creates new hypotheses:

```text
Observation:
False negatives cluster around schema and API contract changes.

Hypothesis:
A dedicated contract-reconstruction pass improves recall on interface and integration bugs.

Experiment:
Add API/schema contract reviewer and run CR-Bench taxonomy slices plus Martian TypeScript and Go subsets.

Decision:
Keep only if F1 improves and SNR does not drop more than 10%.
```

## Falsifiable Hypotheses

PCRS should be evaluated through explicit hypotheses.

| Hypothesis | Test | Win Condition |
| --- | --- | --- |
| H1: Review is bottlenecked by localization and context, not comment writing. | Diff-only vs changed-symbol graph vs navigator-assisted review. | Navigator version improves recall or F1 at the same comment budget. |
| H2: Proof gates beat Reflexion alone. | Reflexion candidate generation with and without evidence/refutation gates. | Same or higher recall with materially higher usefulness and SNR. |
| H3: c-CRAB rewards fix-oriented comments. | Plain bug comment vs failure-path plus suggested fix plus suggested test. | Higher c-CRAB pass rate. |
| H4: Fixed phases beat open-ended autonomy for review. | Free-form agent vs localization -> candidate -> evidence -> refutation -> ranking. | Better cost-adjusted F1 and fewer pathological loops. |
| H5: Cheap models can do navigation and summaries, but not final reasoning. | Model-routing ablation by role. | Similar score at lower cost. |
| H6: Historical reviewer taste improves production alignment. | No repo memory vs accepted/dismissed-comment memory. | Higher useful-comment rate and lower ignored-comment rate. |
| H7: Agent-written PR review is the best wedge. | Human PRs vs Claude/Codex/Cursor-generated PRs. | Stronger relative lift on agent-generated PRs. |

## Milestones

### Milestone 1: Protocol And Benchmark Harness

Build:

- `ReviewInputBundle` schema.
- `ReviewClaim` schema.
- `ReviewerResult` schema.
- Local artifact format.
- Fake reviewer.
- Baseline single-shot reviewer.
- Benchmark runner over local fixtures.

Do not build:

- GitHub publishing.
- Hosted dashboard.
- Full review teams.
- Auto-fix.

### Milestone 2: Proof Object Schema

Require every internal candidate to include:

- Claim.
- Location.
- Introduced-by-PR assessment.
- Severity.
- Failure path.
- Evidence.
- Counterargument.
- Suggested fix.
- Suggested test.
- Publish decision.

No proof object, no comment.

### Milestone 3: First Ablation

Run:

```text
A: diff-only single shot
B: diff + repo context
C: diff + symbol graph
D: diff + symbol graph + candidate swarm
E: D + evidence gate
F: E + adversarial refutation
G: F + calibrated ranker
```

Target pattern:

```text
C/D improves recall.
E/F restores SNR and usefulness.
G improves benchmark-specific F1 without overfitting.
```

### Milestone 4: External Reviewer Adapter

Add a command reviewer adapter:

```toml
[[reviewers]]
id = "opencode-review"
type = "command"
command = "opencode"
args = ["run", "/review", "--json"]
timeout_ms = 900000
```

This allows Sugary to piggyback on Claude Code, opencode, Codex, Semgrep, and internal tools without becoming a thin wrapper.

### Milestone 5: Review Teams

Add:

- Team manifest.
- Parallel reviewer execution.
- Per-reviewer budgets.
- Per-reviewer traces.
- Synthesis across claims.
- Team scorecards.

MVP can remain a team of one. The protocol should make teams natural.

## Implementation Implications

The first codebase should be shaped around protocols, not UI. Because the first goal is the autoresearch lab, the runner should be Elixir-first: experiments, benchmark cases, reviewers, evidence builders, refuters, rankers, and report writers are naturally supervised concurrent processes.

Suggested Mix umbrella shape:

```text
apps/
  sugary_cli/
  sugary_protocol/
  sugary_config/
  sugary_git/
  sugary_input_bundle/
  sugary_reviewers/
  sugary_runner/
  sugary_evidence/
  sugary_refutation/
  sugary_synthesis/
  sugary_evals/
  sugary_research/
  sugary_trace/
  sugary_report/
```

Important interfaces:

```elixir
defmodule Sugary.Reviewers.Reviewer do
  @callback review(Sugary.Protocol.ReviewInputBundle.t(), map()) ::
              {:ok, Sugary.Protocol.ReviewerResult.t()} | {:error, term()}
end

defmodule Sugary.Evidence.Builder do
  @callback build_evidence(map()) ::
              {:ok, Sugary.Protocol.EvidenceResult.t()} | {:error, term()}
end

defmodule Sugary.Refutation.Refuter do
  @callback refute(Sugary.Protocol.ReviewClaim.t(), Sugary.Protocol.ReviewInputBundle.t()) ::
              {:ok, Sugary.Protocol.RefutationResult.t()} | {:error, term()}
end

defmodule Sugary.Synthesis.Ranker do
  @callback rank([Sugary.Protocol.ReviewClaim.t()], map()) ::
              {:ok, [Sugary.Protocol.RankedClaim.t()]} | {:error, term()}
end
```

Canonical artifacts:

```text
.sugary/run/input.json
.sugary/run/team.toml
.sugary/run/reviewers/<id>/result.json
.sugary/run/claims/<claim-id>.json
.sugary/run/final-review.json
.sugary/run/trace.jsonl
```

This keeps shell commands, external agents, future TypeScript wrappers, and hosted services interoperable. The protocol artifacts remain JSON/TOML even though the first runner is Elixir.

## Product Implications

PCRS changes the product pitch:

- Not "better AI PR comments."
- Not "we call the best model."
- Not "three bots review your PR."

The pitch becomes:

> Sugary searches for defects with a team of reviewers, constructs proof for candidate claims, tries to refute them, and publishes only the supported issues.

That is a sharper wedge against existing review tools because it attacks their main weakness: noisy plausible comments.

## Open Questions

- Should benchmark harness come before GitHub Action?
- Should the first benchmark target CR-Bench fixtures, Martian offline fixtures, or our own tiny fixture set?
- Should proof objects require executable tests before publishing in benchmark mode only, or also in production deep mode?
- Should refutation use a different model by default?
- Should review teams be stored as TOML manifests, JSON manifests, or package-like directories?
- Should the first external adapter target opencode, Claude Code, Semgrep, or a generic command protocol?
- Should the first product wedge explicitly target agent-written PRs?

## Sources

- [CR-Bench: Evaluating the Real-World Utility of AI Code Review Agents](https://arxiv.org/html/2603.11078v1)
- [Code Review Agent Benchmark / c-CRAB](https://arxiv.org/html/2603.23448v1)
- [HyperAgent: Generalist Software Engineering Agents to Solve Coding Tasks at Scale](https://arxiv.org/html/2409.16299v1)
- [SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering](https://arxiv.org/abs/2405.15793)
- [Agentless: Demystifying LLM-based Software Engineering Agents](https://arxiv.org/abs/2407.01489)
- [The AI Scientist: Towards Fully Automated Open-Ended Scientific Discovery](https://arxiv.org/abs/2408.06292)
- [Martian Code Review Bench repository](https://github.com/withmartian/code-review-benchmark)
- [Martian Code Review Bench announcement](https://withmartian.com/post/code-review-bench-v0)

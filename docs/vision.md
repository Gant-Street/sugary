# Sugary Vision

Last updated: 2026-05-24

Sugary is an open, user-aligned code review system. It should become the best way for individuals, maintainers, and engineering teams to get useful automated review without handing over model choice, source-code control, review policy, or economic leverage to a closed SaaS.

The product should feel closer to opencode than to a conventional AI review bot: bring your own provider keys, run locally or in your own CI, keep the workflow inspectable, and pay only for convenience that actually saves work. The hosted product can be excellent, but the core engine must remain useful without it.

## Executive Summary

The opportunity is straightforward:

- Code review is valuable because it protects production, maintains quality, transfers context, and teaches engineering judgment.
- Existing AI review tools have proven demand, but many capture value by controlling the execution environment, model access, context index, and Git integration.
- Model costs will keep falling, open models will keep improving, and teams will increasingly already have model provider accounts.
- The durable value is not reselling tokens. It is the review operating system: context assembly, policy, workflow integration, search, evidence construction, adversarial refutation, evaluation, memory, and publication.

Sugary should be the open review operating system for software teams.

The initial wedge is simple:

> Run a high-quality AI review on a pull request using the user's own API key, generate many candidate defect hypotheses, and publish only the sparse, actionable comments that survive evidence construction, adversarial refutation, and calibrated ranking.

The long-term product is broader:

> A review platform that learns each repository's architecture, test strategy, risk model, and engineering standards, then helps teams review code, propose fixes, enforce policies, and understand change impact across GitHub, GitLab, Bitbucket, local branches, and self-hosted environments.

The core technical thesis is [Proof-Carrying Review Search](pcrs.md):

> Winning AI code review will come from proof-carrying review search, not from better PR comments. The reviewer should generate many possible defect hypotheses, then only publish comments that survive evidence construction, adversarial refutation, and benchmark-calibrated ranking.

Under this thesis, Sugary is not primarily a comment generator. It is a review harness, team orchestrator, proof system, adversarial verifier, evaluator, synthesizer, and publisher.

## Core Belief

Most AI code review products are misaligned at the business-model layer. If the vendor profits mainly by abstracting away model access and charging a large markup over inference, the product is incentivized to:

- Keep the review process opaque.
- Make model selection difficult to compare.
- Make switching expensive.
- Charge per seat even when marginal work is mostly automated.
- Capture context and workflow lock-in.
- Optimize for visible activity instead of trusted judgment.

Sugary should invert those incentives:

- The user owns the API keys.
- The user chooses the model.
- The user controls where source code is processed.
- The user sees cost before and after every run.
- The user can reproduce review decisions.
- The user can leave without losing project configuration and review memory.
- The open-source engine is good enough to be credible on its own.

Hosted Sugary can charge for collaboration, orchestration, managed runners, dashboards, analytics, enterprise controls, and support. It should not need to hold the user's model access hostage.

## Product Principles

### 1. BYOK is a first-class product promise

Bring-your-own-key is not a settings-page checkbox. It changes the entire product design.

Sugary must support:

- OpenAI, Anthropic, Google Gemini, OpenRouter, Azure OpenAI, AWS Bedrock, local OpenAI-compatible endpoints, Ollama, LM Studio, and future providers through adapters.
- Provider routing by task, cost, latency, context length, and privacy requirements.
- Per-repository, per-organization, and per-run provider policies.
- Hard cost caps before a review begins.
- Token and dollar accounting after a review finishes.
- Local-only mode where no hosted Sugary service sees source code.
- Hosted mode where users can still use their own provider credentials.

The product should make vendor lock-in feel technically unnecessary.

### 2. Sparse beats noisy

The default review should comment only when there is a plausible defect, security issue, maintainability risk, test gap, API contract break, migration hazard, or product-impacting behavior change.

Sugary should avoid:

- Compliments.
- Generic summaries as line comments.
- Style preferences unless configured.
- Restating what the diff obviously does.
- Commenting on generated files.
- Repeating lint, type-check, or test output unless it explains impact.
- Low-confidence speculation presented as fact.

The best automated review feels like a senior engineer leaving three important comments, not an assistant filling the page.

### 3. Evidence before opinion

Every finding should answer:

- What is wrong?
- Why does it matter?
- Where is the evidence?
- How can the author verify it?
- What is the smallest reasonable fix?
- How confident is Sugary?

When possible, findings should include:

- A line or range in the diff.
- A relevant call path, import path, or data-flow path.
- A failing command or static-analysis result.
- A proposed patch.
- A reproduction note.
- A link to project policy or prior decision.

Internally, findings should be modeled as review claims with proof objects. A weak but interesting idea can be useful to the search process, but it should not become a PR comment until it has evidence, has survived refutation, and clears the publish threshold.

### 4. Policy is code

Review configuration should be stored in the repository. The hosted product can offer UI editing, but the source of truth should be portable files.

Policy must cover:

- Review depth.
- Provider selection.
- Cost budgets.
- Paths to include or exclude.
- Generated-code detection.
- Custom rules.
- Comment thresholds.
- Security posture.
- Test commands.
- Sandboxing rules.
- Team-specific conventions.

### 5. Reviews are pipelines, not magic prompts

The review engine should be built as a pipeline with observable intermediate artifacts:

- Event payload.
- Checked-out repository state.
- Diff parse.
- File classification.
- Repo map.
- Context packs.
- Tool outputs.
- Model prompts.
- Model responses.
- Candidate review claims.
- Verification results.
- Final comments.
- Cost and latency report.

This makes the system debuggable, testable, and trustworthy.

### 6. Fixes matter more than comments

Comments are useful, but the highest-value workflow is:

1. Detect a real issue.
2. Explain why it matters.
3. Offer a safe patch.
4. Let the author apply or request a PR update.
5. Learn from accept/reject feedback.

Sugary should eventually support patch suggestions, branch commits, and follow-up fix PRs. The first implementation can be comment-only, but the architecture should treat fixes as first-class artifacts.

### 7. Local-first, hosted-optional

The open-source CLI should be useful without a hosted account.

Required local capabilities:

- Review a local branch against a base branch.
- Review a GitHub PR from CI.
- Produce markdown output.
- Produce structured JSON output.
- Estimate and enforce cost budgets.
- Use provider keys from environment variables or local config.
- Run without sending source code to Sugary-controlled servers.

Hosted capabilities should add convenience:

- GitHub App installation.
- Managed runners.
- Team dashboards.
- Review analytics.
- Centralized configuration.
- Organization policy management.
- Encrypted secret management.
- Web-based review traces.
- Billing for orchestration, not mandatory model resale.

### 8. The user can inspect and override anything

Every important decision should be inspectable:

- Why was this file reviewed?
- Why was this file ignored?
- Which context was provided to the model?
- Which model reviewed this finding?
- Which rule triggered?
- Why was a candidate finding suppressed?
- How much did this review cost?
- Which comments were deduplicated?

The user should be able to override decisions in config, comments, CLI flags, or the dashboard.

## Market And Competitive Context

This section is based on public information available on 2026-05-13. Competitor packaging and features can change quickly.

### CodeRabbit

Observed positioning:

- AI code reviews for pull requests.
- GitHub, GitLab, and related workflow integrations.
- PR summaries, line comments, chat-style interaction, custom instructions, and higher-tier collaboration features.
- Public-repository/free-tier positioning plus paid plans for teams and enterprises.

What CodeRabbit has validated:

- Developers will install an AI reviewer into real repositories.
- PR summaries and line comments are an accepted workflow surface.
- Teams want custom instructions and repository-specific behavior.
- Review tools can expand toward planning, chat, IDE/CLI, and project context.

Potential openings for Sugary:

- Make the review engine open and reproducible.
- Make BYOK central rather than incidental.
- Make review traces visible.
- Make cost accounting explicit.
- Make self-hosting and local review part of the default story.
- Compete on comment precision instead of comment volume.

### Greptile

Observed positioning:

- AI code review with deeper repository context.
- Codebase indexing and graph/context understanding.
- Rules, learnings, MCP-style integrations, and self-hosted or enterprise-oriented options.

What Greptile has validated:

- Context quality is a major differentiator.
- Teams want the reviewer to learn repository-specific conventions.
- Enterprise buyers care about deployment, security, and control.
- Review is only one interface to a broader codebase understanding engine.

Potential openings for Sugary:

- Treat context construction as an open, inspectable pipeline.
- Let users choose their own vector store, local index, or hosted index.
- Store rules and learnings in portable repository files where possible.
- Make model routing and cost tradeoffs transparent.
- Publish evaluations that make review quality measurable.

### GitHub Copilot, Qodo, Reviewpad, Sonar, Snyk, Semgrep, And Others

The review space is crowded because review is a natural aggregation point for many signals:

- Static analysis.
- Security scanning.
- Test results.
- AI reasoning.
- Ownership.
- Architecture policy.
- Release risk.
- Compliance.

Sugary should not try to replace all specialized tools immediately. It should orchestrate them intelligently and explain their results in the review workflow.

### opencode As Product Inspiration

opencode's important lesson is not just terminal UI. It is incentive design:

- Users can bring provider credentials.
- Providers are modular.
- The system can run close to the user's code.
- The workflow is inspectable and scriptable.
- The product does not need to pretend that one vendor model is always best.

Sugary should apply the same philosophy to review:

- Bring any model.
- Run anywhere.
- Store policy in code.
- Emit structured artifacts.
- Make cost visible.
- Make the hosted product optional but worth paying for.

## Positioning

### One-sentence positioning

Sugary is the open, BYOK code review agent that gives teams senior-level PR feedback without locking them into a model vendor, opaque SaaS, or noisy bot.

### Short positioning

Sugary reviews pull requests with the models and infrastructure you choose. It runs locally, in CI, or as a hosted GitHub App; builds inspectable context from your repository; enforces your review policy as code; and leaves only sparse, evidence-backed comments.

### What Sugary Is

- An open-source review engine.
- A provider-agnostic model orchestration layer.
- A Git-platform integration.
- A repository context engine.
- A policy-as-code system for review quality.
- A cost-aware AI workflow.
- A long-term memory layer for team review standards.

### What Sugary Is Not

- A generic chatbot pasted into pull requests.
- A linter replacement.
- A security scanner replacement.
- A model reseller disguised as a review product.
- A tool that comments for the sake of activity.
- A hosted-only product.
- A black box that asks for broad repository access and gives no trace.

## Target Users

### Individual Maintainers

Needs:

- Review PRs from contributors.
- Catch obvious bugs before merge.
- Get help understanding unfamiliar contributions.
- Avoid noise on small public projects.
- Keep costs low or use existing model subscriptions.

Sugary value:

- Free local/CI review.
- Public-repo friendly defaults.
- BYOK cost control.
- Sparse comments.
- No required hosted account.

### Small Teams

Needs:

- Consistent review standards.
- Faster reviews when the team is busy.
- Better test-gap detection.
- Shared project conventions.
- Simple GitHub integration.

Sugary value:

- GitHub Action or App.
- Repo config committed to source.
- Team memory.
- Review metrics.
- Provider flexibility.

### Scaling Engineering Organizations

Needs:

- Review consistency across repositories.
- Auditability.
- Security and compliance posture.
- Central policies with repo overrides.
- Cost management.
- Model governance.

Sugary value:

- Organization policy management.
- Self-hosted or private cloud runners.
- SSO and RBAC in hosted product.
- Audit logs.
- Model/provider policy controls.
- Data retention controls.

### Agencies And Consultancies

Needs:

- Review many client repositories.
- Keep client code isolated.
- Customize rules per project.
- Provide review artifacts.

Sugary value:

- Workspace isolation.
- Portable config.
- Per-client provider settings.
- JSON/markdown review exports.
- Cost attribution.

### Open Source Projects

Needs:

- Help with contributor PRs.
- Strong public transparency.
- Minimal setup.
- No hidden cost surprises.
- Avoid hostile or annoying bot behavior.

Sugary value:

- Public repo defaults.
- Visible config.
- Comment budget.
- Contributor-safe CI mode.
- Maintainer commands.

## Jobs To Be Done

When I open a pull request, I want Sugary to:

- Identify bugs that human reviewers are likely to care about.
- Find missing tests for changed behavior.
- Notice risky migrations, compatibility breaks, and security issues.
- Explain impact clearly enough that the author can fix the issue.
- Suggest a minimal patch when possible.
- Avoid repeating what existing tools already say.
- Adapt to my repository's conventions.
- Respect my cost and privacy requirements.

When I maintain a repository, I want Sugary to:

- Review contributor PRs without leaking secrets.
- Avoid running untrusted code unless explicitly allowed.
- Follow project-specific instructions stored in the repo.
- Let me suppress patterns that are not useful.
- Help onboard contributors through useful comments.

When I manage a team, I want Sugary to:

- Reduce review latency.
- Improve review consistency.
- Track whether automated review comments are useful.
- Make cost predictable.
- Enforce organization policies.
- Provide audit trails.

## Product Surface

### CLI

The CLI is the foundation and should work before any hosted service exists.

Example commands:

```sh
sugary review
sugary review --base main --head feature/foo
sugary review --pr 123
sugary review --format json
sugary review --mode deep
sugary review --max-cost 2.00
sugary explain .sugary/reviews/run_123.json
sugary init
sugary providers list
sugary doctor
```

CLI responsibilities:

- Resolve repository state.
- Load config.
- Select provider/model.
- Estimate cost.
- Build diff and context.
- Run local tools.
- Call model providers.
- Generate review claims.
- Render markdown and JSON.
- Optionally post to a Git platform.

### GitHub Action

The first integration should be a GitHub Action because it is transparent, easy to install, and keeps execution in the user's CI.

Example workflow:

```yaml
name: Sugary Review

on:
  pull_request:
    types: [opened, synchronize, reopened, ready_for_review]

permissions:
  contents: read
  pull-requests: write
  checks: write

jobs:
  review:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          fetch-depth: 0
      - uses: sugary-ai/sugary-action@v1
        env:
          OPENAI_API_KEY: ${{ secrets.OPENAI_API_KEY }}
        with:
          mode: standard
          max-cost: "1.50"
```

Public fork safety:

- Default pull_request event should not expose secrets to untrusted fork code.
- The action should support a safe no-secrets mode that uses no provider key and simply exits with a clear explanation.
- Maintainers can trigger a trusted review manually with a repository dispatch, workflow dispatch, or comment command.
- Documentation must explain the risk of pull_request_target workflows.

### GitHub App

The hosted product can provide a GitHub App for teams that want less CI setup.

App responsibilities:

- Receive pull request events.
- Schedule review jobs.
- Manage installation permissions.
- Post review summaries and line comments.
- Update existing comments instead of duplicating them.
- Store review traces according to retention policy.
- Route work to hosted, customer-managed, or local runners.

### Web Dashboard

The dashboard should be useful but not mandatory.

Core dashboard views:

- Repositories.
- Review runs.
- Findings.
- Cost.
- Model usage.
- Accepted/rejected comments.
- Rules and suppressions.
- Provider status.
- Audit log.

The dashboard should never become the only place configuration can live. Changes made in the dashboard should be exportable to config files.

### Pull Request Comments

Default comment style:

```md
**Potential null access in retry path**

`loadUser` can return `null`, but the new retry branch passes the result to
`buildSession` without the guard used in the normal path. This can throw for
deleted users after a transient database error.

Evidence: `loadUser` returns `User | null`; `buildSession` reads `user.id`.

Suggested fix: return early when the retried lookup is null, matching the
existing non-retry branch.

Confidence: high
```

Comment rules:

- Use line comments for localized issues.
- Use a top-level summary for cross-cutting risks.
- Group related findings.
- Include confidence and severity.
- Prefer one clear fix over multiple speculative alternatives.
- Do not ask rhetorical questions.
- Do not generate praise.
- Do not mention internal prompt or chain-of-thought details.

### Pull Request Summary

The summary should be useful to reviewers, not a generic changelog.

It should include:

- What changed.
- Review mode and model/provider used.
- Commands run.
- Cost and token usage.
- Files skipped and why.
- Highest-risk findings.
- Test gaps.
- Follow-up recommendations.

It should not replace line comments for concrete issues.

### Comment Commands

Eventually support:

- `/sugary review`
- `/sugary review deep`
- `/sugary review file path/to/file.ts`
- `/sugary explain`
- `/sugary fix`
- `/sugary quiet`
- `/sugary accept`
- `/sugary reject not-a-bug`
- `/sugary remember prefer zod schemas for API input validation`

Commands should be auditable and permissioned.

## Review Modes

### Quick

Purpose:

- Fast, cheap review for small diffs.

Behavior:

- Minimal context.
- No expensive repository indexing.
- Limited comments.
- Small or medium model preferred.

### Standard

Purpose:

- Default PR review.

Behavior:

- Diff-aware context.
- Repo map.
- Relevant neighboring files.
- Existing tests.
- Static tool outputs.
- Comment deduplication.
- Cost cap enforced.

### Deep

Purpose:

- Risky changes, large PRs, release branches.

Behavior:

- Larger context budget.
- Multi-agent review.
- More tool execution.
- Call path and test impact analysis.
- Higher model tier.
- Slower and more expensive.

### Security

Purpose:

- Threat-focused review.

Behavior:

- Authentication, authorization, injection, deserialization, secrets, crypto, dependency, and data-exposure checks.
- Security scanner ingestion when available.
- Higher evidence threshold.

### Test

Purpose:

- Test-gap analysis.

Behavior:

- Identify changed behavior.
- Map to existing tests.
- Suggest missing cases.
- Avoid generic "add tests" comments.

### Release

Purpose:

- Merge readiness and operational risk.

Behavior:

- Migration risks.
- Backward compatibility.
- Config changes.
- Observability changes.
- Rollback concerns.
- Performance hotspots.

## System Architecture

Sugary should be divided into independently testable subsystems.

```text
Git Event / CLI Command
        |
        v
Run Orchestrator
        |
        +--> Repository Adapter
        +--> Config Resolver
        +--> Provider Router
        +--> Budget Manager
        +--> Tool Runner
        +--> Context Engine
        +--> Review Agents
        +--> Claim Verifier
        +--> Comment Renderer
        +--> Platform Publisher
        +--> Trace Store
```

### Execution Modes

#### Local CLI

- Runs on the user's machine.
- Reads local working tree.
- Uses local environment variables for provider keys.
- Writes output to terminal and files.
- Optional GitHub posting through user token.

#### CI Runner

- Runs inside GitHub Actions, GitLab CI, Buildkite, CircleCI, or similar.
- Uses CI secrets for provider keys.
- Posts comments using platform token.
- Stores artifacts in CI.

#### Hosted Runner

- Runs in Sugary-managed infrastructure.
- Uses encrypted user-supplied provider keys or Sugary-managed provider billing if offered.
- Stores traces according to plan and retention settings.
- Provides dashboard and analytics.

#### Customer-managed Runner

- Runs inside customer infrastructure.
- Connects to Sugary control plane for scheduling and metadata.
- Keeps source code and provider keys in customer environment.
- Suitable for enterprise and regulated customers.

### Control Plane vs Execution Plane

Control plane:

- Repository installation metadata.
- Organization and user accounts.
- Policy distribution.
- Job queue.
- Runner registration.
- Audit logs.
- Billing for hosted convenience.
- Dashboard API.

Execution plane:

- Source checkout.
- Tool execution.
- Provider calls.
- Context building.
- Review claim generation.
- Comment publishing.

The control plane should not require access to source code when a customer-managed or CI runner is used.

## Review Pipeline

### 1. Intake

Inputs:

- CLI flags or Git platform webhook.
- Repository URL and commit SHAs.
- Pull request metadata.
- Author, branch, labels, changed files.
- Prior review state.

Outputs:

- `ReviewRun` record.
- Immutable run ID.
- Event payload snapshot.

### 2. Checkout And Diff Resolution

Responsibilities:

- Fetch base and head commits.
- Compute merge-base.
- Generate unified diff.
- Generate file-level metadata.
- Detect renames, copies, deletions, generated files, binary files, and lockfiles.
- Map diff positions to platform-specific line references.

GitHub-specific notes:

- Pull request review comments require careful mapping to file path, commit, side, and line or diff position.
- Sugary should keep a platform-neutral comment model and convert at publish time.

### 3. Config Resolution

Config precedence:

1. CLI flags.
2. Environment variables.
3. Repository config.
4. Organization config.
5. Built-in defaults.

Initial config file:

```toml
[review]
mode = "standard"
max_comments = 12
min_confidence = "medium"
ignore_drafts = true
comment_on_generated = false

[budget]
max_usd = 2.00
warn_usd = 1.00

[provider]
default = "openai:gpt-5.1-mini"
deep = "anthropic:claude-sonnet-4.5"
cheap = "openrouter:openai/gpt-oss-120b"

[paths]
include = ["**/*"]
exclude = [
  "**/*.lock",
  "dist/**",
  "generated/**",
  "vendor/**"
]

[tools]
commands = [
  "npm test -- --runInBand",
  "npm run typecheck",
  "npm run lint"
]
timeout_seconds = 600
network = "off"

[comments]
style = "concise"
include_confidence = true
include_cost_summary = true
update_previous = true

[rules]
custom = [
  "Do not suggest broad rewrites unless the diff introduces a concrete bug.",
  "Prefer existing project helpers over new dependencies.",
  "Flag missing tests only when you can name the behavior that lacks coverage."
]
```

### 4. Budget Planning

Before model calls, Sugary should estimate:

- Diff size.
- Context size.
- Number of files.
- Planned model calls.
- Expected token usage.
- Expected cost.

If a budget would be exceeded:

- Downgrade mode if configured.
- Use cheaper model for triage.
- Reduce context.
- Review only high-risk files.
- Ask for explicit override in interactive CLI.
- Fail closed in CI with a clear message.

### 5. Tool Execution

Tools can provide cheap evidence before model calls.

Possible tools:

- Type checker.
- Test runner.
- Linter.
- Formatter check.
- Dependency audit.
- Secret scanner.
- Semgrep.
- Language server diagnostics.
- Build command.
- Custom project commands.

Rules:

- Tool execution must be timeout-bound.
- Commands must be configured, inferred conservatively, or manually approved.
- Untrusted PRs should not execute arbitrary code with secrets available.
- Tool outputs should be summarized before being passed to models.
- Tool failures should be findings only when they are attributable to the diff or block review confidence.

### 6. Repository Mapping

The repo map should be cheap, local, and incremental.

Data to collect:

- File tree.
- Language breakdown.
- Package/workspace structure.
- Import graph.
- Exports and public API symbols.
- Test file mapping.
- Ownership hints from CODEOWNERS.
- Existing config files.
- Framework detection.
- Database migration directories.
- Generated-code patterns.

Implementation options:

- `git` for changed files and history.
- `ripgrep` for textual search.
- `tree-sitter` for syntax-aware symbol extraction.
- Language servers where available.
- Package manager metadata.
- Optional vector index for larger repositories.

The first implementation can use a lightweight repo map and grow into semantic indexing later.

### 7. Context Assembly

Context should be built as "packs" with explicit purpose.

Examples:

- Diff pack: changed hunks and surrounding code.
- File pack: full changed file when small enough.
- Symbol pack: definitions of changed functions/classes.
- Test pack: nearby tests and missing-test hints.
- Policy pack: relevant config and rules.
- Tool pack: summarized diagnostics.
- History pack: related previous findings and decisions.
- Dependency pack: package manifests and lockfile summaries.

Context selection should be explainable in trace output.

### 8. Candidate Claim Generation

Reviewers should emit structured review claims, not final comments. Candidate generation should optimize for recall and can use one reviewer, a review team, external tools, or command adapters such as Claude Code, opencode, Codex, Semgrep, or internal agents.

Example schema:

```json
{
  "claim": "Null user can reach buildSession",
  "category": "bug",
  "severity": "high",
  "confidence": 0.82,
  "path": "src/session.ts",
  "startLine": 42,
  "endLine": 45,
  "introducedByPr": true,
  "failurePath": [
    "the retry branch calls loadUser",
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
  "suggestedFix": "Return early when the retried lookup returns null.",
  "suggestedTest": "Add a test where the first lookup throws and the retry returns null.",
  "publishDecision": "candidate"
}
```

### 9. Evidence Construction

Each candidate claim should be converted into a proof object where possible.

Evidence tiers:

- Tier 1: executable failing test.
- Tier 2: reproducible command, trace, typecheck, lint, static analyzer, API call, or script.
- Tier 3: static data-flow or control-flow path.
- Tier 4: contract, schema, permission, issue, or documented invariant mismatch.
- Tier 5: weak heuristic.

Default production review should publish only claims with strong enough evidence for the selected mode.

### 10. Adversarial Refutation

Sugary should try to disprove candidate claims before publishing them.

Refutation checks:

- Is this behavior pre-existing?
- Is it actually introduced by the PR?
- Is the claim contradicted by tests, types, or code?
- Is there a caller-level guard?
- Is the severity exaggerated?
- Is the suggested fix wrong or incomplete?
- Is the comment too speculative for a human reviewer?
- Is this already covered by another finding?

### 11. Verification And Ranking

Sugary should not publish raw model or reviewer output.

Verification steps:

- Validate schema.
- Confirm referenced lines exist in the diff or relevant files.
- Check that the finding is not a duplicate.
- Check that the finding is not contradicted by tool output.
- Check that the suggested fix compiles conceptually.
- Suppress low-confidence claims below threshold.
- Suppress comments on ignored paths.
- Rank by severity, confidence, evidence strength, introduced-by-PR probability, actionability, benchmark calibration, and developer noise cost.

Optional second-pass model:

- "Critic" reviews candidate claims for false positives.
- "Editor" rewrites final comments for clarity and brevity.

### 12. Publishing

Publishing should be idempotent.

Rules:

- Update previous Sugary comments when possible.
- Avoid duplicate comments after force-push.
- Delete or resolve stale comments when fixed if platform allows.
- Post one summary comment per run.
- Respect max comment limits.
- Fall back to summary if line mapping fails.
- Store platform comment IDs in run state.

### 13. Learning

Learning should be explicit and reversible.

Signals:

- Author applies suggested patch.
- Reviewer reacts positively.
- Maintainer marks comment useful.
- Maintainer dismisses as false positive.
- Comment thread is resolved without code change.
- User invokes `/sugary remember`.
- User adds suppression rule.

Memory types:

- Repository rules.
- Organization rules.
- Suppression patterns.
- Architecture notes.
- Test conventions.
- Prior false positives.

Memory should be exportable and reviewable.

## Agent Design

Sugary should use specialized reviewers where specialization improves precision. Agents are roles in the pipeline, not necessarily separate long-running processes.

### Router

Decides:

- Review mode.
- Files requiring deeper analysis.
- Which agents to run.
- Model for each task.
- Context budget.

### Diff Analyst

Responsibilities:

- Explain changed behavior.
- Identify touched APIs.
- Classify files.
- Detect generated and low-risk changes.
- Produce concise change summary.

### Bug Reviewer

Responsibilities:

- Logic errors.
- Null/undefined paths.
- Error handling.
- Race conditions.
- State transitions.
- Boundary conditions.
- API misuse.

### Security Reviewer

Responsibilities:

- Authentication and authorization.
- Injection.
- SSRF.
- XSS.
- CSRF.
- Deserialization.
- Secrets.
- Cryptography misuse.
- Dependency exposure.
- Data leakage.

### Test Reviewer

Responsibilities:

- Changed behavior with no corresponding tests.
- Broken or stale tests.
- Overly broad snapshots.
- Missing edge cases.
- Migration coverage.
- Contract tests.

### Architecture Reviewer

Responsibilities:

- Layering violations.
- Public API compatibility.
- Dependency direction.
- Shared abstractions.
- Cross-package effects.
- Backward compatibility.

### Operations Reviewer

Responsibilities:

- Migrations.
- Config changes.
- Feature flags.
- Observability.
- Rollback.
- Performance.
- Resource usage.

### Comment Editor

Responsibilities:

- Remove hedging.
- Remove filler.
- Make comments concise.
- Ensure every comment is actionable.
- Normalize tone.
- Preserve technical evidence.

### Claim Critic

Responsibilities:

- Challenge candidate claims.
- Detect false positives.
- Identify unsupported claims.
- Ensure line mapping is accurate.
- Ensure severity is justified.

## Context Engine

The context engine is the heart of product quality.

### Inputs

- Diff.
- Full repository files.
- Git history.
- CODEOWNERS.
- Config files.
- Package manifests.
- Test files.
- Tool outputs.
- Prior review runs.
- User rules.

### Outputs

- Repo map.
- Relevant file sets.
- Symbol graph.
- Test map.
- Context packs.
- Trace metadata.

### Required Capabilities

#### Language Detection

Detect file language from extension and content. Use language-specific parsers where available, but fall back gracefully.

#### Changed Symbol Detection

For each changed file:

- Identify changed functions/classes/components/types.
- Identify exported symbols.
- Identify imports and downstream references when cheap.

#### Test Mapping

Map source files to likely tests:

- Naming conventions.
- Directory proximity.
- Import references.
- Framework conventions.
- Existing test commands.

#### Risk Scoring

Assign file and change risk:

- Authentication/authorization code.
- Payment/billing code.
- Data migrations.
- Public APIs.
- Infrastructure/config.
- Dependency changes.
- Large deletions.
- Test removal.
- Concurrency code.
- Serialization boundaries.

#### Incremental Indexing

For large repositories, cache:

- File hashes.
- Parsed symbols.
- Import graph.
- Embeddings if enabled.
- Previous summaries.

Cache should be local by default and portable where possible.

## Provider System

### Provider Abstraction

Provider adapter interface:

```ts
interface ModelProvider {
  id: string;
  listModels(): Promise<ModelInfo[]>;
  complete(request: ModelRequest): Promise<ModelResponse>;
  estimateCost(request: ModelRequest): CostEstimate;
  supports(feature: ProviderFeature): boolean;
}
```

Features to model:

- Tool calling.
- JSON schema output.
- Large context.
- Vision input.
- Prompt caching.
- Streaming.
- Batch API.
- Reasoning effort.
- Local endpoint.
- Data retention guarantees.

### Routing Policy

Routing should support:

- Default model.
- Cheap model.
- Deep model.
- Security model.
- Local-only model.
- Fallback models.
- Provider allowlist and denylist.
- Max cost per model call.
- Max latency.

Example:

```toml
[models.router]
triage = "openai:gpt-5.1-mini"
deep = "anthropic:claude-sonnet-4.5"
critic = "google:gemini-3-pro"
local = "ollama:qwen3-coder"

[models.limits]
max_call_usd = 0.50
max_run_usd = 2.00
```

### Cost Transparency

Every run should report:

- Provider.
- Model.
- Input tokens.
- Output tokens.
- Cached tokens if applicable.
- Estimated cost.
- Actual cost when provider returns usage.
- Cost by pipeline stage.

The CLI should show a preflight cost estimate before expensive local interactive runs.

## Security And Privacy

### Data Handling

Default posture:

- Do not send source code to Sugary servers in local/CI mode.
- Send source only to the configured model provider.
- Allow local-only model mode.
- Redact detected secrets from prompts and traces.
- Store traces locally unless hosted storage is enabled.
- Make retention explicit.

Hosted posture:

- Encrypt provider keys.
- Isolate tenants.
- Minimize source retention.
- Support no-retention mode for traces.
- Support customer-managed runners.
- Provide audit logs.

### Prompt Injection Defense

Source code, comments, issue text, and PR descriptions can be adversarial. The model must treat repository content as data, not instructions.

Controls:

- Strong system messages separating policy from content.
- Context blocks labeled as untrusted.
- Tool calls controlled by Sugary, not by model text.
- No automatic execution of commands suggested by a model.
- No secret exposure in prompts.
- Review claims validated outside the model.

### CI Security

Risks:

- Untrusted fork PRs can alter code that CI executes.
- `pull_request_target` can expose secrets if used incorrectly.
- Tests can exfiltrate secrets over network.
- Generated artifacts can smuggle prompt injection.

Controls:

- Safe default GitHub Action using `pull_request`, not `pull_request_target`.
- No provider secrets available to untrusted fork code by default.
- Manual trusted re-run workflow.
- Tool runner network disabled by default for untrusted PRs.
- Configurable command allowlist.
- Clear documentation.

### Permissions

GitHub App permissions should be minimal:

- Contents: read.
- Pull requests: read/write for comments.
- Checks: write if using check runs.
- Metadata: read.

Avoid broad write permissions until fix commits are implemented.

### Secret Redaction

Sugary should scan:

- Diffs.
- Tool outputs.
- Environment-derived config.
- Trace artifacts.

Redaction should happen before model calls and before trace persistence.

## Data Model

### ReviewRun

Fields:

- `id`
- `repo`
- `platform`
- `baseSha`
- `headSha`
- `pullRequestNumber`
- `mode`
- `status`
- `startedAt`
- `finishedAt`
- `configHash`
- `costEstimate`
- `actualCost`
- `summary`

### DiffFile

Fields:

- `path`
- `oldPath`
- `status`
- `language`
- `additions`
- `deletions`
- `isGenerated`
- `isBinary`
- `riskScore`
- `hunks`

### ReviewClaim

Fields:

- `id`
- `runId`
- `claim`
- `category`
- `severity`
- `confidence`
- `path`
- `startLine`
- `endLine`
- `side`
- `introducedByPr`
- `failurePath`
- `evidence`
- `counterarguments`
- `suggestedFix`
- `suggestedTest`
- `agent`
- `model`
- `dedupeKey`
- `publishDecision`

### ReviewComment

Fields:

- `id`
- `claimId`
- `platform`
- `platformCommentId`
- `path`
- `line`
- `body`
- `status`
- `createdAt`
- `updatedAt`

### Rule

Fields:

- `id`
- `scope`
- `text`
- `severity`
- `paths`
- `enabled`
- `source`

### ProviderProfile

Fields:

- `provider`
- `model`
- `role`
- `maxInputTokens`
- `maxOutputTokens`
- `costPerInputToken`
- `costPerOutputToken`
- `features`

## Configuration Philosophy

Configuration should be:

- Human-editable.
- Version-controlled.
- Validated by schema.
- Portable between local, CI, and hosted runs.
- Small by default.
- Extensible for advanced teams.

Suggested files:

```text
.sugary/config.toml
.sugary/rules.md
.sugary/memory.md
.sugary/suppressions.toml
```

### `.sugary/rules.md`

Purpose:

- Store durable team review preferences.
- Use natural language.
- Keep rules visible in code review.

Example:

```md
# Sugary Rules

- Prefer existing service helpers over adding new direct database queries.
- Any new public API endpoint must include authorization tests.
- Migration PRs must include rollback notes unless they are additive only.
- Do not request tests for pure copy changes.
```

### `.sugary/suppressions.toml`

Purpose:

- Avoid repeated false positives.
- Keep suppressions auditable.

Example:

```toml
[[suppressions]]
dedupe_key = "react-exhaustive-deps-custom-hook"
reason = "Project intentionally wraps this hook pattern."
expires = "2026-08-01"
```

## Evaluation Strategy

Sugary should treat review quality as an engineering problem.

### Metrics

Core metrics:

- Precision: percent of comments judged useful.
- False positive rate.
- Accepted suggestion rate.
- Resolved-with-code-change rate.
- Comments per PR.
- Cost per reviewed PR.
- Time to first review.
- Duplicate comment rate.
- Stale comment rate.
- Maintainer override rate.

Quality should optimize for precision before recall. Missing one marginal issue is better than training users to ignore the bot.

### Benchmark Suite

Create an open benchmark and connect to public review benchmarks:

- Realistic PR fixtures.
- Seeded bugs.
- Known expected claims.
- Known non-issues.
- Multi-language coverage.
- Golden JSON claims.
- Cost and latency tracking.
- CR-Bench and CR-Bench Verified for recall, usefulness, and signal-to-noise.
- c-CRAB-style executable tests to measure whether comments lead to behaviorally correct fixes.
- Martian Code Review Bench for offline comparison and online-style fresh holdouts.
- SWE-bench-style localization, repair, and validation fixtures for submodule quality.

Fixture categories:

- Null handling.
- Authorization bypass.
- SQL/command injection.
- XSS.
- Race condition.
- Migration risk.
- Breaking API change.
- Missing tests.
- Dependency vulnerability.
- Performance regression.
- Incorrect error handling.

### Regression Tests

Every false positive and missed important issue can become a test fixture.

The project should include:

- Parser tests.
- Diff mapping tests.
- Provider adapter tests.
- Prompt snapshot tests.
- Review claim schema tests.
- Comment rendering tests.
- GitHub publishing tests with mocked API.
- End-to-end review fixtures.

### Autoresearch Loop

Sugary should use benchmark results to search for better review methods:

- Extract claims from papers, benchmark updates, competitor outputs, and failed runs.
- Convert those claims into component-level experiments.
- Run ablations across context, candidate generation, evidence construction, refutation, ranking, and comment style.
- Keep Pareto improvements by score, cost, latency, usefulness, and signal-to-noise.
- Convert false positives and false negatives into regression fixtures.

See [docs/pcrs.md](pcrs.md) for the detailed research thesis and [docs/autoresearch-loop.md](autoresearch-loop.md) for the operational `/goal`-ready implementation plan.

## Initial Technical Stack

The first implementation should optimize for contributor speed and GitHub integration.

Recommended stack:

- TypeScript.
- Node.js.
- pnpm workspace.
- Vitest for tests.
- Zod for schemas.
- Commander or Clipanion for CLI.
- Octokit for GitHub API.
- Pino for structured logging.
- simple-git or direct `git` subprocess calls.
- tree-sitter where useful, introduced after the diff pipeline works.
- SQLite for local trace/cache storage if needed.

Rationale:

- GitHub API and Actions ecosystem are strong in TypeScript.
- Provider SDKs are readily available.
- JSON schema, CLI, and config tooling are mature.
- Contributors can move quickly.

Avoid early complexity:

- Do not build a hosted dashboard before the CLI and Action are useful.
- Do not require vector search for the MVP.
- Do not build multi-platform support before GitHub works well.
- Do not invent a plugin system before core interfaces stabilize.
- Do not self-host model inference as part of the initial product.

## Proposed Repository Structure

```text
sugary/
  README.md
  LICENSE
  package.json
  pnpm-workspace.yaml
  docs/
    vision.md
    architecture.md
    security.md
    configuration.md
  packages/
    cli/
    core/
    config/
    git/
    github/
    providers/
    review/
    tools/
    trace/
  examples/
    github-action/
    configs/
  fixtures/
    reviews/
  .github/
    workflows/
```

Package responsibilities:

- `core`: shared types, schemas, run orchestration interfaces.
- `config`: config loading, validation, defaults.
- `git`: repository and diff operations.
- `providers`: model provider adapters and routing.
- `review`: context assembly, agents, claim verification.
- `tools`: command execution and tool output normalization.
- `github`: GitHub API publishing and line mapping.
- `trace`: run artifacts, local storage, redaction.
- `cli`: command-line entry points.

## MVP Definition

The first public MVP should do one thing well:

> Review a GitHub pull request from CI using a user-supplied provider key and publish a concise summary plus high-confidence line comments.

Required MVP capabilities:

- `sugary init`.
- `sugary review --base <sha> --head <sha>`.
- OpenAI-compatible provider adapter.
- Config file with review mode, ignored paths, max comments, and max cost.
- Diff parsing and file classification.
- Basic repo map.
- Context assembly for changed files.
- Structured review claim generation.
- Claim verification.
- Markdown and JSON output.
- GitHub Action wrapper.
- GitHub PR summary comment.
- GitHub line comments.
- Idempotent comment updating.
- Cost estimate and actual token usage report.
- Unit tests for diff parsing, config, provider abstraction, and rendering.

MVP non-goals:

- Hosted dashboard.
- GitLab and Bitbucket.
- Multi-agent deep review.
- Persistent vector index.
- Auto-fix commits.
- Enterprise SSO.
- Billing.

## Roadmap

### Phase 0: Foundation

Deliverables:

- Vision document.
- Project README.
- Architecture notes.
- TypeScript workspace.
- CLI skeleton.
- Config schema.
- Provider interface.
- Local markdown review output.

Success criteria:

- A contributor can run `sugary review --help`.
- Config validates with useful errors.
- A fake reviewer can produce deterministic review claims for tests.

### Phase 1: Local Review

Deliverables:

- Git diff resolution.
- Context assembly for changed files.
- OpenAI-compatible provider adapter.
- Structured finding schema.
- Markdown and JSON report.
- Cost tracking.

Success criteria:

- A user can review a local branch against `main`.
- Review output is useful without posting comments.
- Fixture tests run in CI.

### Phase 2: GitHub Action

Deliverables:

- Action wrapper.
- Pull request metadata ingestion.
- GitHub line mapping.
- Summary comment publishing.
- Line comment publishing.
- Idempotency.
- Public-fork safety docs.

Success criteria:

- Public repo can install Sugary with one workflow file.
- PR comments do not duplicate across pushes.
- Safe failure when provider key is unavailable.

### Phase 3: Quality System

Deliverables:

- Claim critic pass.
- Comment editor pass.
- Tool runner.
- Test command ingestion.
- Generated-code detection.
- Suppression file.
- Benchmark fixtures.

Success criteria:

- False positives decrease across benchmark fixtures.
- Tool output improves evidence without creating noise.
- Users can suppress repeated non-issues.

### Phase 4: Memory And Rules

Deliverables:

- `.sugary/rules.md`.
- `.sugary/memory.md`.
- Comment feedback commands.
- Learning capture.
- Rule attribution in claims.

Success criteria:

- Maintainers can teach Sugary project conventions.
- Learned preferences are visible and reversible.

### Phase 5: Hosted Product

Deliverables:

- GitHub App.
- Managed runners.
- Dashboard.
- Review traces.
- Team settings.
- Encrypted provider keys.
- Usage analytics.

Success criteria:

- Teams can install Sugary without editing CI.
- Hosted users still retain provider choice.
- Local/CI users are not second-class.

### Phase 6: Enterprise And Ecosystem

Deliverables:

- Customer-managed runners.
- SSO and RBAC.
- Audit logs.
- Central org policies.
- GitLab support.
- Bitbucket support.
- Plugin/tool integration API.
- Self-hosted control plane option if demand justifies it.

Success criteria:

- Larger organizations can adopt Sugary without violating security posture.
- Integrators can add tools without modifying core review logic.

## Business Model

Sugary should monetize convenience and collaboration, not captivity.

### Open Source

Free:

- CLI.
- Core review engine.
- Provider adapters.
- GitHub Action.
- Local traces.
- Repository config.

### Hosted Free

Possible:

- Free public repositories.
- Limited private repo reviews.
- BYOK only.
- Basic dashboard.

### Hosted Pro

Charge for:

- Managed GitHub App.
- Managed runners.
- Review history.
- Team dashboard.
- Analytics.
- Rule management UI.
- Higher hosted run limits.
- Priority queues.

### Enterprise

Charge for:

- Customer-managed runners.
- SSO.
- RBAC.
- Audit logs.
- Central policies.
- Compliance support.
- Deployment support.
- Custom retention.
- Dedicated support.

### Avoid

- Mandatory per-seat pricing disconnected from usage.
- Hidden model markups as the main margin source.
- Charging users to access their own review traces.
- Making export difficult.
- Artificial limits that push users away from local mode.

## Success Metrics

Product metrics:

- Weekly active repositories.
- Reviews per active repository.
- Install-to-first-review conversion.
- Median comments per PR.
- Useful-comment rate.
- False-positive report rate.
- Accepted suggestion rate.
- Repeat usage after first week.
- Local-to-hosted conversion.

Engineering metrics:

- Review latency p50/p95.
- Cost per review p50/p95.
- Provider error rate.
- Comment publish failure rate.
- Line mapping failure rate.
- Benchmark precision.
- Benchmark recall for high-severity issues.

Business metrics:

- Hosted conversion rate.
- Gross margin excluding model cost.
- Managed runner utilization.
- Revenue per active repository.
- Support burden by plan.

## Brand And Tone

The product should feel:

- Direct.
- Technically serious.
- Calm.
- Precise.
- Open.
- Developer-native.

The bot should not feel:

- Chatty.
- Cute at the expense of clarity.
- Overconfident.
- Scolding.
- Salesy.
- Generic.

Voice examples:

- Good: "This branch skips the existing null guard before calling `buildSession`, which can throw for deleted users after a retry."
- Bad: "Great work! One small thought: maybe consider checking for null here?"
- Bad: "This code may have an issue."

## Documentation Strategy

Docs should be excellent from the start because trust is a core feature.

Required docs:

- Quickstart.
- BYOK provider setup.
- GitHub Action setup.
- Configuration reference.
- Security model.
- Public fork safety.
- Cost controls.
- Comment quality philosophy.
- Troubleshooting.
- Architecture.
- Contributing.

Docs should include:

- Copy-paste commands.
- Minimal examples.
- Explicit threat model.
- Known limitations.
- Provider-specific notes.
- Upgrade guides.

## Risks And Mitigations

### Risk: Review Quality Is Not Better Than Competitors

Mitigations:

- Build benchmark suite early.
- Optimize for precision.
- Store false positives as regression tests.
- Make context traceable.
- Use critic pass.
- Ingest tool evidence.

### Risk: BYOK Creates Setup Friction

Mitigations:

- Excellent setup docs.
- `sugary doctor`.
- OpenAI-compatible default path.
- Optional hosted managed keys later.
- Clear provider examples.

### Risk: Comments Become Noise

Mitigations:

- Strict default max comments.
- Confidence threshold.
- Suppressions.
- No praise comments.
- No style comments by default.
- Useful-comment feedback loop.

### Risk: Security Incident From CI Misconfiguration

Mitigations:

- Safe default workflows.
- Public fork documentation.
- No `pull_request_target` quickstart.
- Network-off tool runner for untrusted PRs.
- Secret redaction.
- Minimal permissions.

### Risk: Hosted Product Undermines Open Promise

Mitigations:

- Keep CLI and Action first-class.
- Public config schema.
- Export all data.
- Do not make hosted-only model features necessary.
- Document local mode proudly.

### Risk: Provider APIs Change Frequently

Mitigations:

- Adapter boundaries.
- Contract tests.
- OpenAI-compatible fallback.
- Provider capability discovery.
- Versioned provider profiles.

### Risk: Large Repositories Are Too Expensive

Mitigations:

- Risk scoring.
- Context budgets.
- Incremental indexing.
- Cached summaries.
- Cheap triage model.
- File/path targeting.
- Explicit cost caps.

## Open Questions

- Should the first CLI be published as `sugary`, `sugary-ai`, or under another package scope?
- Should the first provider adapter target OpenAI's official API or a generic OpenAI-compatible endpoint?
- Should config use TOML, YAML, or JSONC? TOML is readable, but YAML is familiar in CI.
- Should the first GitHub integration post review comments directly or use Checks annotations first?
- What is the minimum acceptable line-mapping fidelity before public release?
- How much trace data should be stored by default in local mode?
- Should `.sugary/memory.md` be edited by bot PRs, or only by humans?
- What license should apply long term if the hosted business becomes important? The repo currently uses MIT.
- Should local model support be included in MVP or phase 2?
- Should review prompts live as code, markdown templates, or both?

## Immediate `/goal` Implementation Brief

If `/goal` is used to begin implementation, the first goal should be:

If the next step is the research machine rather than the product CLI, use the detailed Autoresearch Loop v0 prompt in [docs/autoresearch-loop.md](autoresearch-loop.md).

> Build the local TypeScript CLI foundation for Sugary: workspace setup, protocol schemas, config schema, reviewer abstraction, git diff resolution, structured proof-carrying review output, and a fake reviewer-backed test path.

Suggested acceptance criteria:

- Repository has a pnpm TypeScript workspace.
- `sugary review --help` works.
- `sugary init` creates `.sugary/config.toml`.
- `sugary review --base main --head HEAD --reviewer fake` emits markdown and JSON artifacts.
- The fake reviewer returns deterministic structured review claims from fixture input.
- Config validation errors are clear.
- Unit tests cover config loading, git diff parsing, review claim schema validation, evidence schema validation, and markdown rendering.
- CI runs tests.
- README has local quickstart instructions.

Suggested first package boundaries:

- `packages/core`: types and schemas.
- `packages/config`: config loader.
- `packages/git`: diff and repository helpers.
- `packages/reviewers`: reviewer interface plus fake reviewer.
- `packages/evidence`: proof object and evidence helpers.
- `packages/review`: orchestration, ranking, synthesis, and rendering.
- `packages/cli`: CLI entry point.

Suggested first commands:

```sh
sugary init
sugary review --base main --head HEAD --reviewer fake
sugary review --base main --head HEAD --format json --out .sugary/reviews/latest.json
sugary doctor
```

Suggested non-goals for the first `/goal` run:

- Do not integrate real model providers yet.
- Do not post GitHub comments yet.
- Do not build a hosted service.
- Do not add vector search.
- Do not add auto-fix.
- Do not build full review teams yet, but keep the reviewer interface and artifact protocol team-compatible.

## Source Links Consulted

- [CodeRabbit pricing](https://www.coderabbit.ai/pricing)
- [CodeRabbit documentation](https://docs.coderabbit.ai/)
- [Greptile documentation](https://docs.greptile.com/)
- [Greptile pricing](https://www.greptile.com/pricing)
- [opencode provider documentation](https://opencode.ai/docs/providers)
- [GitHub REST API: pull requests](https://docs.github.com/en/rest/pulls)
- [GitHub webhook events and payloads](https://docs.github.com/en/webhooks/webhook-events-and-payloads)
- [GitHub Actions security guidance for pull_request_target](https://securitylab.github.com/resources/github-actions-preventing-pwn-requests/)
- [CR-Bench: Evaluating the Real-World Utility of AI Code Review Agents](https://arxiv.org/html/2603.11078v1)
- [Code Review Agent Benchmark / c-CRAB](https://arxiv.org/html/2603.23448v1)
- [HyperAgent: Generalist Software Engineering Agents to Solve Coding Tasks at Scale](https://arxiv.org/html/2409.16299v1)
- [SWE-agent: Agent-Computer Interfaces Enable Automated Software Engineering](https://arxiv.org/abs/2405.15793)
- [Agentless: Demystifying LLM-based Software Engineering Agents](https://arxiv.org/abs/2407.01489)
- [The AI Scientist: Towards Fully Automated Open-Ended Scientific Discovery](https://arxiv.org/abs/2408.06292)
- [Martian Code Review Bench repository](https://github.com/withmartian/code-review-benchmark)

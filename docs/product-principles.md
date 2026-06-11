# Product Principles

Sugary exists to become the best code review system for real customer PRs and MRs, not merely a bot that writes plausible comments.

The core product thesis:

```text
Winning AI code review comes from proof-carrying review search:
search broadly, prove narrowly, refute aggressively, and publish sparingly.
```

## 1. Outcomes Over Comments

The unit of value is a prevented defect, not a generated review comment.

Sugary should optimize for:

- high true-defect recall
- high precision
- low duplicate/noise rate
- actionable failure paths
- fixes that a human or coding agent can verify
- low enough latency and cost for normal PR flow

Sugary should not optimize for:

- sounding senior
- filling a comment budget
- style feedback volume
- raw candidate count
- benchmark-only wording matches

## 2. Proof-Carrying Claims

Every published comment should be backed by an internal proof object.

A claim should answer:

- what changed in this PR
- why the issue is introduced by this PR, not preexisting
- what concrete failure follows
- what repo evidence supports the failure path
- what would refute the claim
- what fix or test would verify the issue

No proof object, no comment.

## 3. Real Repo Access, Bounded Tools

Reviewers need access to the actual repository state.

Sugary should materialize or use a real checkout whenever possible:

- base ref
- head ref
- merge/diff state
- changed files
- relevant unchanged files
- git history

But repo access should be exposed through bounded, auditable tools:

- read file
- grep repository
- grep git history
- show commit
- inspect diff
- inspect changed symbol references

Do not dump the full repo into the prompt. The model should ask targeted questions and cite the answers.

## 4. Tools Are Evidence, Not Authority

Tools do not publish comments. Models do not publish comments. Reviewers produce candidate claims.

Sugary owns:

- evidence construction
- refutation
- dedupe
- ranking
- score accounting
- final publish decisions

Every tool observation used for a comment should be captured as an artifact.

## 5. Refutation Is First-Class

A good reviewer is not the one that imagines the most bugs. It is the one that withholds unsupported claims.

Every serious claim should face adversarial checks:

- Is this behavior preexisting?
- Is it intentional?
- Is there a caller invariant?
- Is auth handled elsewhere?
- Is a compatibility layer present?
- Is this a duplicate root cause?
- Is this just scary-looking code?

Suppression is a product feature.

## 6. Benchmark-Driven, Not Benchmark-Gamed

Benchmarks are instruments, not the mission.

Sugary should use benchmarks to find gradients:

- Martian Code Review Bench
- CR-Bench-style defect review
- c-CRAB-style fix usefulness
- local hard fixtures
- customer PR replay sets

But promotion requires transfer:

- dev to holdout
- benchmark to benchmark
- benchmark to customer-like PRs
- synthetic fixtures to real repos

A method that wins one benchmark by exploiting fixture shape should be rejected.

## 7. Fixed Inputs For Publisher Research

Publisher, dedupe, and ranking experiments must run on fixed captured candidate pools whenever possible.

Live end-to-end runs are necessary, but they confound:

- candidate generation variance
- validation variance
- model nondeterminism
- publisher behavior

To learn what works, Sugary should separate:

```text
candidate generation -> validation artifacts -> publisher replay -> scoring
```

Only after a publisher improves fixed replay should it earn a live end-to-end run.

## 8. One Variable At A Time

New tools, models, prompts, memory, teams, and publishers are all variables.

Each variable must earn its place through ablation:

- define the expected benefit
- hold other variables fixed
- run against a meaningful sample
- measure F1, precision, recall, SNR, noise, duplicates, latency, and cost
- keep it only if the data justifies the complexity

Complexity is debt until proven otherwise.

## 9. Model And Harness Agnostic

Sugary should be the review harness, not the model vendor.

Users should be able to bring:

- OpenAI-compatible APIs
- Anthropic-compatible APIs
- local tools
- Codex
- Claude Code
- opencode
- static analyzers
- internal reviewer scripts

Sugary's moat is the protocol, evidence gate, refuter, publisher, benchmark loop, and product ergonomics.

## 10. Security By Default

Code review runs touch proprietary code and sometimes secrets.

Default posture:

- least-privilege repo access
- read-only review execution first
- no oracle leakage
- no secret values in cache keys or logs
- redacted stdout/stderr artifacts
- explicit network/secrets declarations for external tools
- ephemeral hosted workspaces
- local-first execution whenever practical

Security review itself should be a first-class specialist, but the review infrastructure also needs to be secure.

## 11. Local-First, Hosted Later

The first great product experience should work locally.

Local mode gives users:

- bring-your-own-key economics
- direct repo access
- fast experimentation
- privacy
- easy integration with existing agents

Hosted mode can come later, but it must preserve the same protocol and evidence artifacts.

## 12. Simple Product, Serious Engine

The user-facing product should feel simple:

```sh
sugary review
```

Underneath, Sugary can run a serious proof/search/refutation pipeline. The product should hide orchestration complexity unless the user asks for artifacts, debug traces, or benchmark reports.

Less surface area is better. More proof is better.

## Current Strategic Default

Until experiments prove otherwise, Sugary should prioritize:

```text
repo-materialized PCRS
+ bounded repo/history tools
+ typed proof gates
+ adversarial refutation
+ publisher replay ablations
+ calibrated, low-noise publishing
```

Do not add persistent agents, broad memory, arbitrary bash, or more model roles until the current proof/refutation/publisher loop is stronger on fixed replay and live end-to-end runs.

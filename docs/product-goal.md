# Sugary Product Goal

Sugary will be the highest-signal AI code review product, delivered through the
pull-request workflow developers already understand.

The initial experience is deliberately conventional:

1. Install the GitHub App.
2. Open a pull request.
3. Receive a small number of inline findings.
4. Resolve or dismiss those findings.

Sugary wins by publishing fewer, more useful comments. Every published finding
must describe a consequential defect, carry concrete repository evidence,
survive adversarial refutation, and clear explicit precision and comment-budget
thresholds.

## Product Promise

> High-signal code review that works directly with your coding agent.

## Novel Capability

Sugary closes the loop between review and code generation:

```text
Sugary verifies a defect
        -> sends a structured claim and evidence to a coding agent
        -> the agent repairs the defect
        -> Sugary reviews and verifies the repair
        -> the PR shows fixed findings, unresolved findings, and residual risk
```

The long-term product moves review from a downstream commenting step into an
adversarial verification loop that runs alongside software generation.

## Success Contract

Sugary must demonstrate all of the following on leakage-safe, realistic data:

- Higher review F1 than leading AI code-review products.
- High precision with few low-value, duplicate, or incorrect comments.
- A measurable improvement in final-patch correctness after repair.
- A low rate of harmful or unnecessary agent-generated repairs.
- Fewer human interruptions for routine defects.
- Concrete evidence for every published finding.
- Reliable abstention and human escalation when evidence is insufficient.

The long-term benchmark target is greater than 70% F1 over thousands of diverse,
real pull requests. This is a target, not a current claim. A benchmark result is
not a product win unless the same method also improves final-patch correctness
without unacceptable regressions in precision, harmful repairs, latency, cost,
or human interruption.

## Research Contract

Every research loop must preserve a locked incumbent and state its hypothesis
before execution. A candidate may replace an incumbent only when it:

- improves the primary metric on the declared evaluation set;
- respects the operating point's precision and comment budget;
- does not materially regress signal-to-noise, repair safety, latency, or cost;
- survives a fresh holdout or transfer gate before becoming a product default;
- has no oracle leakage or benchmark-specific reviewer inputs;
- produces reproducible artifacts that explain gains and failures.

Sugary maintains distinct operating points:

- **Trust default:** the highest-precision product posture.
- **Qualified F1:** the best balanced review posture that clears quality gates.
- **Recall diagnostic:** a non-product posture used to measure candidate-pool
  headroom and identify missing verification or ranking capabilities.

Product operating points must make publish decisions from the current PR alone.
A policy that distributes a global comment budget across a benchmark corpus is
an offline diagnostic, even if its F1 is higher, because it cannot run online.

Diagnostic results must never be presented as product performance.

## Product Principle

Review quality comes before review volume. Sugary should not identify every
conceivable concern. It should surface the findings most likely to be real,
consequential, and worth acting on.

## Strategy

- **Proven:** Automated review in pull requests.
- **Better:** Higher-F1, evidence-backed findings with substantially less noise.
- **New:** Structured communication with coding agents to repair and re-review
  defects before human approval.

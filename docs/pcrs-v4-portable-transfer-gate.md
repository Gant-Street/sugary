# PCRS v4 Portable Transfer Gate

PCRS v4 tests one new variable: a benchmark-agnostic portable candidate source backed by the Codex CLI command reviewer.

The reviewer receives only a sanitized `ReviewInputBundle`. If a local base/head workspace exists, Sugary passes blinded workspace paths so the reviewer can inspect the target repo read-only. If no workspace exists, the same reviewer falls back to PR metadata and diff review.

Run the full local transfer gate:

```sh
./sugary pcrs portable transfer gate --suites martian-offline,aacr-bench --limit 50 --replay-mode cache-first
```

The report is written under:

```text
.sugary/research/transfer-gates/<run-id>/
  portable-transfer-scorecard.json
  portable-transfer-report.md
  martian-offline-run-dir.txt
  aacr-bench-run-dir.txt
  martian-publisher-dir.txt
```

The gate reports:

- Candidate-pool hits, recall, noise, and claim count.
- Published hits, noise, precision, F1, and comments.
- Static-proof ablation against `public-static-proof-gate`.
- Public benchmark leakage checks.
- Workspace availability.
- Replay/live execution mix.
- Martian publisher guardrails after adding the portable source as an extra tail source.

Current strict targets:

```text
AACR first-50 candidate-pool hits >= 10
AACR published precision >= 0.500
Martian trust/default F1 >= 0.466 and precision >= 0.840
Martian qualified F1 >= 0.552 and precision >= 0.720
```

This is not an official Martian, CR-Bench, or AACR score. It does not call a benchmark API, does not submit results, and does not claim leaderboard rank.

Do not add AACR-specific static patterns to pass this gate. A failure is useful transfer evidence.

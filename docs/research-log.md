# Research Log

This log records local research checkpoints. Results here are not product claims, official benchmark submissions, or public leaderboard scores.

## 2026-05-25: First Martian Public-Transfer Smoke

Command sequence:

```sh
git clone --depth=1 https://github.com/withmartian/code-review-benchmark.git .sugary/research/benchmarks/martian-offline
elixir scripts/benchmarks/fetch_martian_diffs.exs --limit 3
mix escript.build
./sugary experiment run experiments/public-martian-codex-transfer-v0.toml --replay-mode cache-first
```

Run artifact:

```text
.sugary/research/runs/20260525T171825Z-public-martian-codex-transfer-v0
.sugary/research/public-smoke/20260525T171825Z-public-martian-codex-transfer-v0
```

Scope:

- Benchmark: Martian Code Review Bench offline, local smoke only.
- Cases: 3 Discourse PRs.
- Golden comments: 9.
- Official score: no.
- Leaderboard claim: no.

Result:

| Method | Recall | Precision | F1 | Usefulness | SNR | Avg comments/PR | Noise |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `baseline-diff-only` | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0 |
| `hard-specialist-plus-pcrs` | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0 |
| `codex-gpt-5.5-low` | 0.222 | 0.400 | 0.286 | 0.400 | 0.667 | 1.667 | 3 |
| `codex-gpt-5.5-xhigh` | 0.222 | 0.333 | 0.267 | 0.333 | 0.500 | 2.000 | 4 |

Interpretation:

- The synthetic hard-fixture specialist team did not transfer to real Martian PRs.
- `gpt-5.5` low reasoning beat xhigh on this tiny subset by producing the same number of hits with less noise and lower latency.
- Public cases exposed the useful gradient missing from the saturated local dev split.
- Failure clusters were dominated by `missing_context` and `speculative_edge_case`.
- Complementarity headroom was positive, so a PCRS architecture can still improve if it adds context retrieval, evidence gates, and refutation around live reviewer candidates.

Next research move:

Build a public-transfer PCRS candidate that wraps live Codex low as candidate generation, then adds evidence/refutation/ranking before publication. The target is not more raw comments; it is higher public-smoke usefulness/F1 with SNR no worse than the live baseline.

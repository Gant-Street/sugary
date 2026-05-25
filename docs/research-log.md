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

## 2026-05-25: PCRS Static Proof Gate Stretch

Command sequence:

```sh
mix run -e 'IO.puts(Sugary.Runner.run_experiment_file!("experiments/public-martian-pcrs-static-proof-v0.toml"))'
```

Run artifact:

```text
.sugary/research/runs/20260525T174422Z-public-martian-pcrs-static-proof-v0
.sugary/research/public-smoke/20260525T174422Z-public-martian-pcrs-static-proof-v0
```

Scope:

- Benchmark: same 3-case Martian offline local smoke subset.
- Official score: no.
- Leaderboard claim: no.
- Live model calls: no. This run tested a deterministic static proof gate against the same public-transfer smoke.

Result:

| Method | Recall | Precision | F1 | Usefulness | SNR | Avg comments/PR | Noise |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `public-static-proof-gate` | 0.444 | 1.000 | 0.615 | 1.000 | 4.000 | 1.333 | 0 |
| prior best live baseline: `codex-gpt-5.5-low` | 0.222 | 0.400 | 0.286 | 0.400 | 0.667 | 1.667 | 3 |

Stretch target:

- F1 target: >= 0.350. Actual: 0.615.
- Usefulness target: >= 0.450. Actual: 1.000.
- SNR target: >= 0.667. Actual: 4.000.
- Noise target: <= 3. Actual: 0.
- Avg comments/PR target: <= 1.667. Actual: 1.333.

Interpretation:

- The gain came from publishing fewer, proof-carrying static claims, not from more raw comment generation.
- The proof gate hit four public smoke defects: duplicate Ruby method arity override, hardcoded upload limit, migration bypassing model normalization, and nil dereference after `TopicUser.find_by`.
- Five expected defects remain unfound, so this is not a general PCRS validation.
- A scorer bug was fixed during the audit: public fuzzy matching now selects the strongest semantic match rather than the first matching golden comment.

Next research move:

Turn this into a real PCRS loop by using live model/Codex output for candidate generation, then applying static proof construction, adversarial refutation, and ranking before publication. The next target should preserve this no-noise behavior while recovering some of the five remaining false negatives.

## 2026-05-25: PCRS Public Transfer Campaign v1

Command sequence:

```sh
elixir scripts/benchmarks/fetch_martian_diffs.exs --limit 25
mix run -e 'IO.puts(Sugary.Runner.run_experiment_file!("experiments/public-martian-pcrs-transfer-v1.toml"))'
```

Run artifact:

```text
.sugary/research/runs/20260525T183827Z-public-martian-pcrs-transfer-v1
.sugary/research/public-smoke/20260525T183827Z-public-martian-pcrs-transfer-v1
```

Scope:

- Benchmark: Martian Code Review Bench offline, local smoke only.
- Cases: 25 public benchmark PRs with cached diffs.
- Golden comments: 74.
- Official score: no.
- Leaderboard claim: no.
- Live model calls: yes for `pcrs-codex-proof-low`; raw Codex baselines replayed from the prior live run cache.

Result:

| Method | Recall | Precision | F1 | Usefulness | SNR | Avg comments/PR | Noise | Hits |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `public-static-proof-gate` | 0.054 | 1.000 | 0.103 | 1.000 | 4.000 | 0.160 | 0 | 4 |
| `codex-gpt-5.5-low` | 0.257 | 0.559 | 0.352 | 0.559 | 1.267 | 1.360 | 15 | 19 |
| `codex-gpt-5.5-xhigh` | 0.284 | 0.525 | 0.368 | 0.525 | 1.105 | 1.600 | 19 | 21 |
| `pcrs-codex-proof-low` | 0.324 | 0.558 | 0.410 | 0.558 | 1.263 | 1.720 | 19 | 24 |
| `public-pcrs-static-codex-low-team` | 0.338 | 0.658 | 0.446 | 0.658 | 1.923 | 1.520 | 13 | 25 |

Stretch target:

- Beat best raw live Codex baseline on F1. Actual: `0.446` vs `0.368`.
- Preserve or improve usefulness. Actual: `0.658` vs `0.525`.
- Preserve or improve SNR. Actual: `1.923` vs `1.105`.
- Do not increase noise per PR. Actual: `13` noise comments vs `19`.
- Recover at least 20% more true positives than the static proof gate. Actual: `25` hits vs `4`.

Interpretation:

- The first larger public-transfer result supports the narrow PCRS mechanism: static proof claims plus low-reasoning live candidate generation, merged and ranked by Sugary, beat both raw low and raw xhigh Codex baselines on this unofficial local smoke set.
- The stronger xhigh model found two more hits than low, but added four more noise comments and much higher latency; model strength alone was not the best tradeoff.
- The repaired live wrapper improved over raw baselines on F1, but the team composition was better because it retained the high-precision static proof claims while avoiding some wrapper duplicate/noise behavior.
- This is still not an official Martian score, not a public benchmark claim, and not general PCRS validation.
- The research scorecard recommends the next ablation around ranking or publishing threshold. Rank-3 comments were net negative for the winning team, while rank-1 comments carried most utility.

Next research move:

Freeze the winning public-smoke candidate shape and run a ranking-threshold ablation on the same 25-case replay cache: compare max 1, max 2, and max 3 comments per PR, plus an agreement/evidence-aware ranker. The target is to keep most of the 25 hits while cutting speculative false positives.

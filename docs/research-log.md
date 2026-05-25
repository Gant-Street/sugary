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

## 2026-05-25: Ranking Policy Ablation v1

Command sequence:

```sh
mix run -e 'IO.puts(Sugary.RankingPolicyAblation.run!(source_run: ".sugary/research/runs/20260525T183827Z-public-martian-pcrs-transfer-v1", method_id: "public-pcrs-static-codex-low-team", baselines: ["codex-gpt-5.5-xhigh"], suite: "martian-offline", limit: 25, offset: 0, id: "ranking-policy-ablation-v1-dev"))'
elixir scripts/benchmarks/fetch_martian_diffs.exs --limit 25 --offset 25
mix run -e 'IO.puts(Sugary.Runner.run_experiment_file!("experiments/public-martian-ranking-fresh-v1.toml"))'
mix run -e 'IO.puts(Sugary.RankingPolicyAblation.run!(source_run: ".sugary/research/runs/20260525T215029Z-public-martian-ranking-fresh-v1", method_id: "public-pcrs-static-codex-low-team", baselines: ["codex-gpt-5.5-xhigh"], suite: "martian-offline", limit: 25, offset: 25, id: "ranking-policy-ablation-v1-fresh"))'
```

Run artifacts:

```text
.sugary/research/runs/20260525T214920Z-ranking-policy-ablation-v1-dev
.sugary/research/runs/20260525T215029Z-public-martian-ranking-fresh-v1
.sugary/research/runs/20260525T222815Z-ranking-policy-ablation-v1-fresh
```

Scope:

- Benchmark: Martian Code Review Bench offline, local smoke only.
- Dev slice: cases 1-25 from the existing public-transfer run.
- Fresh slice: cases 26-50, selected before seeing results.
- Official score: no.
- Leaderboard claim: no.
- Live model calls: yes for the fresh slice; ranking ablations replay fixed captured claims.

Dev-slice result:

| Policy | Recall | F1 | Usefulness | SNR | Avg comments/PR | Noise | Hits | Utility | Decision |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `codex-gpt-5.5-xhigh` | 0.284 | 0.368 | 0.525 | 1.105 | 1.600 | 19 | 21 | -2.000 | raw baseline |
| `team-ev-max-1` | 0.216 | 0.337 | 0.762 | 3.200 | 0.840 | 5 | 16 | 8.900 | rejected by F1 guardrail |
| `team-ev-max-2` | 0.311 | 0.434 | 0.719 | 2.556 | 1.280 | 9 | 23 | 10.800 | promoted for fresh check |
| `team-ev-max-3` | 0.338 | 0.446 | 0.658 | 1.923 | 1.520 | 13 | 25 | 8.200 | lower utility |

Fresh-slice result:

| Policy | Recall | F1 | Usefulness | SNR | Avg comments/PR | Noise | Hits | Utility | Decision |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `codex-gpt-5.5-xhigh` | 0.190 | 0.293 | 0.632 | 1.714 | 0.760 | 7 | 12 | 3.100 | raw baseline |
| `team-ev-max-1` | 0.206 | 0.313 | 0.650 | 1.857 | 0.800 | 7 | 13 | 4.000 | failed promotion guardrails |
| `team-ev-max-2` | 0.222 | 0.322 | 0.583 | 1.400 | 0.960 | 10 | 14 | 1.600 | rejected |
| `team-ev-max-3` | 0.222 | 0.322 | 0.583 | 1.400 | 0.960 | 10 | 14 | 1.600 | rejected |

Interpretation:

- The dev slice supported a max-2 policy because the third ranked comment was net negative while the second ranked comment still carried positive utility.
- The fresh slice did not validate that promotion. `team-ev-max-2` recovered two more hits than raw xhigh but added three more noise comments and regressed usefulness/SNR.
- `team-ev-max-1` was the closest fresh-slice result: one extra hit, no added noise, slightly better F1/usefulness/SNR, but one extra comment and not enough margin for promotion under the current guardrails.
- This is a useful negative result. The public-transfer candidate's raw claim pool improved recall, but the ranking policy is not robust enough across adjacent Martian slices.

Next research move:

Do not tune another threshold directly on the fresh slice. Build a real evidence/refutation scorer that predicts which second-ranked comments are worth publishing. The next target should beat raw `codex-gpt-5.5-xhigh` on a locked fresh slice with no added noise and no comment-count regression, while preserving at least one unique true positive.

## 2026-05-25: Evidence/Refutation Ranker v1 Stretch

Command sequence:

```sh
mix run -e 'IO.puts(Sugary.EvidenceRefutationRanker.tune_and_lock!(source_run: ".sugary/research/runs/20260525T183827Z-public-martian-pcrs-transfer-v1", method_id: "public-pcrs-static-codex-low-team", baseline_id: "codex-gpt-5.5-xhigh", suite: "martian-offline", limit: 25, offset: 0, id: "evidence-refutation-ranker-v1-dev"))'
elixir scripts/benchmarks/fetch_martian_diffs.exs --limit 25 --offset 50
elixir scripts/benchmarks/fetch_martian_diffs.exs --limit 25 --offset 75
mix run -e 'IO.puts(Sugary.EvidenceRefutationRanker.evaluate!(lock_path: ".sugary/research/runs/20260525T224028Z-evidence-refutation-ranker-v1-dev/ranker-lock.json", source_run: ".sugary/research/runs/20260525T215029Z-public-martian-ranking-fresh-v1", baseline_id: "codex-gpt-5.5-xhigh", suite: "martian-offline", limit: 25, offset: 25, id: "evidence-refutation-ranker-v1-holdout-26-50"))'
mix run -e 'IO.puts(Sugary.EvidenceRefutationRanker.aggregate!(evaluation_dirs: [".sugary/research/runs/20260525T224152Z-evidence-refutation-ranker-v1-holdout-26-50"], id: "evidence-refutation-ranker-v1-available-holdout-aggregate"))'
```

Run artifacts:

```text
.sugary/research/runs/20260525T224028Z-evidence-refutation-ranker-v1-dev
.sugary/research/runs/20260525T224152Z-evidence-refutation-ranker-v1-holdout-26-50
.sugary/research/runs/20260525T224213Z-evidence-refutation-ranker-v1-available-holdout-aggregate
```

Scope:

- Benchmark: Martian Code Review Bench offline, local smoke only.
- Dev slice: cases 1-25.
- Intended stretch slice: cases 51-100.
- Actual available holdout: cases 26-50, because upstream `benchmark_data.json` at Martian SHA `279f279` contains 50 cases total.
- Official score: no.
- Leaderboard claim: no.
- Fresh tuning: no. The ranker was locked before evaluation on cases 26-50.

Dev-slice locked policy:

| Policy | Recall | F1 | Usefulness | SNR | Avg comments/PR | Noise | Hits | Utility |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `codex-gpt-5.5-xhigh` | 0.284 | 0.368 | 0.525 | 1.105 | 1.600 | 19 | 21 | -2.000 |
| `balanced-top2-t2.3` | 0.324 | 0.449 | 0.727 | 2.667 | 1.320 | 9 | 24 | 11.700 |

Available-holdout result:

| Method | Recall | F1 | Usefulness | SNR | Avg comments/PR | Noise | Hits | Utility |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `codex-gpt-5.5-xhigh` | 0.190 | 0.293 | 0.632 | 1.714 | 0.760 | 7 | 12 | 3.100 |
| `balanced-top2-t2.3` | 0.222 | 0.322 | 0.583 | 1.400 | 0.960 | 10 | 14 | 1.600 |

Stretch target:

- Beat raw xhigh F1: passed.
- Preserve usefulness: failed.
- Preserve SNR: failed.
- Do not increase noise: failed.
- Do not increase comments/PR: failed.
- Add at least two unique true positives: passed.
- Paired wins > losses: passed, 8 wins / 7 losses / 10 ties.

Interpretation:

- The evidence/refutation scorer did not solve publishing. It found additional true positives, but it still admitted too many second-ranked false positives.
- The result strengthens the diagnosis from the previous loop: the candidate pool contains useful extra signal, but our current evidence features are too weak to separate good second comments from noise.
- Failure analysis reported 9 admitted false positives and 1 suppressed true positive on cases 26-50. Average false-positive publish score was 4.665, which means the current features are overconfident on noisy claims rather than merely setting the threshold too low.
- The planned cases 51-100 stretch was blocked by public benchmark data availability, not tool failure.

Next research move:

Stop optimizing scalar thresholds. Build an adversarial refuter that produces explicit counterarguments for each candidate claim before ranking. The next target should reduce false-positive publish scores on the available holdout without using holdout oracle labels for tuning.

## 2026-05-25: Adversarial Refuter Ranker v1

Command sequence:

```sh
mix run -e 'IO.puts(Sugary.AdversarialRefuterRanker.tune_and_lock!(source_run: ".sugary/research/runs/20260525T183827Z-public-martian-pcrs-transfer-v1", method_id: "public-pcrs-static-codex-low-team", baseline_id: "codex-gpt-5.5-xhigh", refuter_ids: ["codex-gpt-5.5-xhigh"], suite: "martian-offline", limit: 25, offset: 0, id: "adversarial-refuter-ranker-v1-dev"))'
mix run -e 'IO.puts(Sugary.AdversarialRefuterRanker.evaluate!(lock_path: ".sugary/research/runs/20260525T225108Z-adversarial-refuter-ranker-v1-dev/refuter-lock.json", source_run: ".sugary/research/runs/20260525T215029Z-public-martian-ranking-fresh-v1", baseline_id: "codex-gpt-5.5-xhigh", suite: "martian-offline", limit: 25, offset: 25, id: "adversarial-refuter-ranker-v1-holdout-26-50"))'
```

Run artifacts:

```text
.sugary/research/runs/20260525T225108Z-adversarial-refuter-ranker-v1-dev
.sugary/research/runs/20260525T225138Z-adversarial-refuter-ranker-v1-holdout-26-50
```

Scope:

- Benchmark: Martian Code Review Bench offline, local smoke only.
- Dev slice: cases 1-25.
- Holdout slice: cases 26-50.
- Official score: no.
- Leaderboard claim: no.
- Fresh tuning: no. The refuter policy was locked before evaluation on cases 26-50.
- Refuter source: raw `codex-gpt-5.5-xhigh` claims, used as independent no-oracle support/counterargument evidence.

Dev-slice locked policy:

| Policy | Recall | F1 | Usefulness | SNR | Avg comments/PR | Noise | Hits | Unique hits over raw |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `codex-gpt-5.5-xhigh` | 0.284 | 0.368 | 0.525 | 1.105 | 1.600 | 19 | 21 | n/a |
| `refuter_unique_guarded-top2-t3.6` | 0.243 | 0.367 | 0.750 | 3.000 | 0.960 | 6 | 18 | 6 |

Holdout result:

| Method | Recall | F1 | Usefulness | SNR | Avg comments/PR | Noise | Hits | Unique hits over raw |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `codex-gpt-5.5-xhigh` | 0.190 | 0.293 | 0.632 | 1.714 | 0.760 | 7 | 12 | n/a |
| `evidence-refutation-ranker-v1` | 0.222 | 0.322 | 0.583 | 1.400 | 0.960 | 10 | 14 | 8 |
| `refuter_unique_guarded-top2-t3.6` | 0.143 | 0.231 | 0.600 | 1.500 | 0.600 | 6 | 9 | 3 |

Interpretation:

- The adversarial refuter reduced false positives compared with the previous evidence/refutation ranker: noise fell from 10 to 6 and comments fell from 24 to 15.
- It also lowered average admitted false-positive publish score from 4.665 to 3.880.
- However, it over-suppressed true positives. Hits fell from 14 to 9, F1 fell from 0.322 to 0.231, and it still failed raw-xhigh usefulness/SNR guardrails.
- The result supports the direction but rejects this deterministic refuter as a promotion candidate.
- Independent-support counterarguments are useful, but too blunt. Claims without xhigh support can still be real unique true positives; treating missing support as a broad penalty suppresses too much of the PCRS advantage.

Next research move:

Move from heuristic counterarguments to proof-specific refutation. For each candidate, the refuter should try to produce a concrete disproof: preexisting behavior, caller invariant, test coverage, API contract, changed-file mismatch, or benchmark/source-context contradiction. Missing independent support should be one weak signal, not the main objection.

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

## 2026-05-25: Read-Only Tool Gauntlet v0

Command sequence:

```sh
mix run -e 'IO.puts(Sugary.ToolGauntlet.run!(source_run: ".sugary/research/runs/20260525T215029Z-public-martian-ranking-fresh-v1", method_id: "public-pcrs-static-codex-low-team", baseline_id: "codex-gpt-5.5-xhigh", suite: "martian-offline", limit: 25, offset: 25, id: "readonly-tool-gauntlet-v0-regression", capabilities: ["read_changed_files", "base_preexisting_check", "repo_rg"], max_published: 2, min_score: 2.0))'
```

Run artifact:

```text
.sugary/research/tool-gauntlets/20260525T231803Z-readonly-tool-gauntlet-v0-regression
```

Scope:

- Benchmark: Martian Code Review Bench offline, local smoke only.
- Cases: 26-50, already inspected in earlier loops. This is a contaminated regression slice, not fresh holdout evidence.
- Candidate pool: replayed `public-pcrs-static-codex-low-team` claims.
- Baseline: replayed `codex-gpt-5.5-xhigh` claims.
- Model calls: none.
- Official score: no.

Result:

| Variant | F1 | Usefulness | SNR | Hits | Noise | Avg comments/PR |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Raw baseline: `codex-gpt-5.5-xhigh` | 0.293 | 0.632 | 1.714 | 12 | 7 | 0.760 |
| Source method: `public-pcrs-static-codex-low-team` | 0.322 | 0.583 | 1.400 | 14 | 10 | 0.960 |
| Control no-tool ranker | 0.322 | 0.583 | 1.400 | 14 | 10 | 0.960 |
| `read_changed_files` | 0.322 | 0.583 | 1.400 | 14 | 10 | 0.960 |
| `base_preexisting_check` | 0.322 | 0.583 | 1.400 | 14 | 10 | 0.960 |
| `repo_rg` | 0.322 | 0.583 | 1.400 | 14 | 10 | 0.960 |

Decision:

- `read_changed_files`: discard for this replay slice.
- `base_preexisting_check`: discard for this replay slice.
- `repo_rg`: discard for this replay slice because no local target repository checkout was available.
- Kept capabilities: none.

Interpretation:

- This is a useful negative result. Naive post-hoc changed-file and preexisting signals did not separate the remaining true positives from noise in the replayed public candidate pool.
- The result does not mean repo tools are useless. It means these v0 replay signals are too weak once the candidate pool is already mostly changed-file-grounded.
- `repo_rg` cannot be meaningfully evaluated until Sugary can materialize or locate target repository checkouts for benchmark cases.
- The next tooling loop should test live model access to a single read-only repo-navigation interface on cases with real target files, or first build the benchmark checkout/overlay layer needed for `rg` and `read_file` to be real tools rather than unavailable signals.

## 2026-05-25: Repo Materialization v0

Command sequence:

```sh
mix run -e 'IO.puts(Sugary.RepoMaterializer.run!(suite: "martian-offline", limit: 30, offset: 0, mode: "plan", id: "martian-repo-materialization-v0-plan-30"))'
mix run -e 'IO.puts(Sugary.RepoMaterializer.run!(suite: "martian-offline", limit: 30, offset: 0, mode: "metadata", id: "martian-repo-materialization-v0-metadata-30"))'
mix run -e 'IO.puts(Sugary.RepoMaterializer.run!(suite: "martian-offline", limit: 1, offset: 0, mode: "fetch", id: "martian-repo-materialization-v0-fetch-smoke"))'
mix run -e 'IO.puts(Sugary.RepoMaterializer.run!(suite: "martian-offline", limit: 10, offset: 0, mode: "fetch", id: "martian-repo-materialization-v0-fetch-discourse-10"))'
```

Run artifacts:

```text
.sugary/research/repo-materializations/20260525T233008Z-martian-repo-materialization-v0-plan-30
.sugary/research/repo-materializations/20260525T233018Z-martian-repo-materialization-v0-metadata-30
.sugary/research/repo-materializations/20260525T233048Z-martian-repo-materialization-v0-fetch-smoke
.sugary/research/repo-materializations/20260525T233120Z-martian-repo-materialization-v0-fetch-discourse-10
```

Scope:

- Benchmark: Martian Code Review Bench offline, local smoke only.
- Reviewer behavior: unchanged.
- Model calls: none.
- Network: GitHub API for metadata, git fetch for fetch-mode cases.
- Official score: no.

Result:

| Run | Cases | Planned | Metadata resolved | Workspace ready | Exact diff parity | Failed |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Plan, first 30 | 30 | 30 | 0 | 0 | 0 | 0 |
| Metadata, first 30 | 30 | 0 | 30 | 0 | 0 | 0 |
| Fetch smoke, first case | 1 | 0 | 0 | 1 | 1 | 0 |
| Fetch Discourse slice | 10 | 0 | 0 | 10 | 10 | 0 |

Interpretation:

- Martian can back real-repo experiments. The first 30 cases all point to supported GitHub PR or commit URLs.
- GitHub metadata resolved exact base/head SHAs for 30/30 cases.
- Fetch mode successfully materialized the first 10 Discourse cases into base/head workspaces with exact changed-file parity.
- The Discourse fetch slice produced 10 tool-ready cases for read-only repo navigation experiments.
- This is not reviewer validation. It only establishes the missing substrate needed to test whether `rg`, `read_file`, and later execution tools actually improve review.

Next research move:

Run a live single-variable tool ablation on the 10 materialized Discourse cases:

```text
A: same Codex model, diff-only prompt
B: same Codex model, same prompt budget, plus read-only repo navigator transcript
```

Promotion should require higher F1 or usefulness-adjusted F1, no usefulness/SNR regression, no added noise, paired wins over losses, and latency within a fixed budget.

## 2026-05-30: Martian Autoresearch 50-Case Loop v0

Command sequence:

```sh
./sugary repo materialize --suite martian-offline --limit 50 --offset 0 --mode fetch
./sugary architecture gauntlet gauntlets/martian-autoresearch-50-v0.toml --replay-mode cache-first
./sugary scientific pilot --experiment experiments/martian-autoresearch-v0.toml --candidate pcrs-codex-repo-low-strict --baseline codex-gpt-5.5-low --limit 50 --offset 0 --replay-mode cache-first --min-cases 50 --bootstrap-iterations 500 --primary-metric usefulness_adjusted_f1 --min-primary-delta 0.05 --max-added-comments-per-pr 0 --min-snr-ratio 0.9 --max-added-noise 0 --id martian-autoresearch-strict-pilot-v0
mix run -e 'IO.puts(Sugary.RankingPolicyAblation.run!(source_run: ".sugary/research/runs/20260530T032918Z-martian-autoresearch-50-v0-experiment", method_id: "pcrs-codex-repo-low-strict", baselines: ["codex-gpt-5.5-low"], suite: "martian-offline", limit: 50, offset: 0, id: "martian-autoresearch-ranking-budget-uaf1-v0", min_uaf1_delta: 0.05))'
mix run -e 'IO.puts(Sugary.RankingPolicyAblation.run!(source_run: ".sugary/research/runs/20260530T072359Z-martian-autoresearch-v0", method_id: "pcrs-codex-repo-low-strict", baselines: ["codex-gpt-5.5-low"], suite: "martian-offline", limit: 50, offset: 0, id: "martian-autoresearch-ranking-budget-repeat-uaf1-v0", min_uaf1_delta: 0.05))'
```

Run artifacts:

```text
.sugary/research/repo-materializations/20260530T032351Z-repo-materialization-v0
.sugary/research/architecture-gauntlets/20260530T032917Z-martian-autoresearch-50-v0
.sugary/research/runs/20260530T032918Z-martian-autoresearch-50-v0-experiment
.sugary/research/scientific-pilots/20260530T082402Z-martian-autoresearch-strict-pilot-v0
.sugary/research/runs/20260530T082559Z-martian-autoresearch-ranking-budget-uaf1-v0
.sugary/research/runs/20260530T082559Z-martian-autoresearch-ranking-budget-repeat-uaf1-v0
```

Scope:

- Benchmark: Martian Code Review Bench offline, local smoke only.
- Cases: 50 materialized Martian cases.
- Golden comments: 137.
- Repositories: Discourse, Sentry, Cal.com, Grafana, Keycloak, and Sentry Greptile mirror cases.
- Workspace readiness: 50/50 base/head workspaces materialized with exact changed-file parity.
- Official score: no.
- Leaderboard claim: no.
- Live model calls: yes. The loop intentionally used Codex CLI through Sugary's command boundary.

Architecture gauntlet result:

| Method | F1 | UAF1 | Recall | Usefulness | SNR | Hits | Noise | Avg comments/PR | Decision |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `codex-gpt-5.5-low` | 0.305 | 0.152 | 0.219 | 0.500 | 1.000 | 30 | 30 | 1.200 | reference |
| `codex-gpt-5.5-repo-low` | 0.277 | 0.129 | 0.197 | 0.466 | 0.871 | 27 | 31 | 1.160 | quarantine |
| `pcrs-codex-proof-low` | 0.330 | 0.173 | 0.241 | 0.524 | 1.100 | 33 | 30 | 1.260 | keep |
| `pcrs-codex-repo-low` | 0.379 | 0.214 | 0.285 | 0.565 | 1.300 | 39 | 30 | 1.380 | keep |
| `pcrs-codex-repo-low-strict` | 0.362 | 0.210 | 0.263 | 0.581 | 1.385 | 36 | 26 | 1.240 | keep |
| `martian-pcrs-repo-plus-codex-low` | 0.370 | 0.161 | 0.321 | 0.436 | 0.772 | 44 | 57 | 2.020 | quarantine |

Strict scientific pilot repeat:

| Method | F1 | UAF1 | Recall | Usefulness | SNR | Hits | Noise | Avg comments/PR |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `codex-gpt-5.5-low` | 0.297 | 0.149 | 0.212 | 0.500 | 1.000 | 29 | 29 | 1.160 |
| `pcrs-codex-repo-low-strict` | 0.355 | 0.207 | 0.255 | 0.583 | 1.400 | 35 | 25 | 1.200 |

Scientific pilot decision:

- Aggregate UAF1 delta: +0.0586.
- Hits: +6.
- Noise: -4.
- SNR: +0.400.
- Published claims: +2 over 50 PRs.
- Bootstrap UAF1 delta estimate: +0.0733 with interval [-0.0066, 0.1567].
- Decision: reject for promotion-grade claim because the paired confidence interval crossed zero.

Ranking-budget result on the gauntlet capture:

| Policy | F1 | UAF1 | Recall | Usefulness | SNR | Hits | Noise | Avg comments/PR | Decision |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `codex-gpt-5.5-low` | 0.305 | 0.152 | 0.219 | 0.500 | 1.000 | 30 | 30 | 1.200 | baseline |
| `team-ev-max-1` | 0.311 | 0.203 | 0.204 | 0.651 | 1.867 | 28 | 15 | 0.860 | promoted for next locked check |

Ranking-budget repeat result:

| Policy | F1 | UAF1 | Recall | Usefulness | SNR | Hits | Noise | Avg comments/PR | Decision |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `codex-gpt-5.5-low` | 0.297 | 0.149 | 0.212 | 0.500 | 1.000 | 29 | 29 | 1.160 | baseline |
| `team-ev-max-2` | 0.362 | 0.241 | 0.248 | 0.667 | 2.000 | 34 | 17 | 1.020 | promoted for next locked check |

Interpretation:

- Raw repo access alone was negative at low reasoning. It lowered F1, usefulness, and SNR while increasing latency.
- PCRS structure without repo access was directionally positive but did not clear the stretch target.
- PCRS plus materialized repo context produced the strongest raw lift, but the non-strict variant published too many comments.
- Strict PCRS plus repo context repeatedly improved aggregate UAF1, SNR, usefulness, hits, and noise, but the live strict reviewer still published slightly more comments than the baseline.
- Replay ranking-budget policies fixed the comment budget on both captured samples. The best policy changed between samples (`team-ev-max-1` then `team-ev-max-2`), which means the exact threshold is not yet stable enough to call production-ready.
- The team composition found more hits but added too much noise. It should not be promoted.

Conclusion:

The loop hit the aggregate stretch target only after adding a ranking-budget layer over strict PCRS repo claims. This is real local evidence for the PCRS thesis, but it is not a general validation and not an official benchmark claim.

Next research move:

Lock the strict PCRS repo candidate plus an explicit budgeted ranking policy, then evaluate it on a fresh Martian slice or a refreshed public benchmark source. Promotion should require:

- UAF1 delta >= +0.05.
- SNR no worse than baseline.
- Average comments per PR no higher than baseline.
- No added net noise.
- At least one unique true positive.
- Paired bootstrap interval not crossing zero, or enough additional cases to explain why the interval is still underpowered.

## 2026-05-30: Martian Offline Parity Export v0

Command sequence:

```sh
mix escript.build
./sugary martian parity export --source-run .sugary/research/runs/20260530T072359Z-martian-autoresearch-v0 --method pcrs-codex-repo-low-strict --tool sugary-pcrs-repo-budget-max2 --policy team-ev-max-2 --martian-dir .sugary/research/benchmarks/martian-offline/offline --model-dir sugary_local_parity_v0 --limit 50 --offset 0 --id martian-official-parity-v0
cd .sugary/research/benchmarks/martian-offline/offline
MARTIAN_MODEL=sugary_local_parity_v0 uv run python -m code_review_benchmark.step2_extract_comments --tool sugary-pcrs-repo-budget-max2 --limit 1
MARTIAN_MODEL=sugary_local_parity_v0 uv run python -m code_review_benchmark.step2_5_dedup_candidates --tool sugary-pcrs-repo-budget-max2 --force
MARTIAN_MODEL=sugary_local_parity_v0 uv run python -m code_review_benchmark.step3_judge_comments --tool sugary-pcrs-repo-budget-max2 --dedup-groups results/sugary_local_parity_v0/dedup_groups.json --limit 1
uv run python analysis/benchmark_dashboard.py
uv run pytest
```

Run artifacts:

```text
.sugary/research/martian-parity/20260530T152430Z-martian-official-parity-v0
.sugary/research/benchmarks/martian-offline/offline/results/sugary_local_parity_v0/candidates.json
.sugary/research/benchmarks/martian-offline/offline/results/sugary_local_parity_v0/dedup_groups.json
```

Scope:

- Benchmark: Martian Code Review Bench offline, local official artifact parity only.
- Cases: 50/50 local Martian PRs.
- Sugary source run: `20260530T072359Z-martian-autoresearch-v0`.
- Method: `pcrs-codex-repo-low-strict`.
- Budget policy: `team-ev-max-2`.
- Tool id inserted into Martian artifacts: `sugary-pcrs-repo-budget-max2`.
- Official score: no.
- Submission: no.

Result:

| Check | Result |
| --- | ---: |
| PRs with Sugary review entry in `benchmark_data.json` | 50/50 |
| Martian-style candidates written | 51 |
| Singleton dedup groups written | 51 |
| Martian benchmark commit | `279f279` |
| Martian pytest suite | 28 passed |

Official pipeline status:

- Step 2 extraction loaded 50 PRs, then stopped with `ValueError: MARTIAN_API_KEY environment variable required`.
- Step 2.5 dedup loaded `results/sugary_local_parity_v0/dedup_groups.json`, then stopped with the same missing key.
- Step 3 judge loaded the Sugary candidates and dedup groups, then stopped with the same missing key.
- Dashboard generation completed against existing bundled evaluations, but cannot include Sugary until Step 3 writes evaluations for `sugary-pcrs-repo-budget-max2`.

Interpretation:

- Sugary now reaches local official-harness artifact parity: Martian can see Sugary as a tool with one review entry per PR plus model-local candidates and dedup groups.
- The remaining blocker is benchmark judge credentials, not missing local Sugary artifacts.
- The current `dedup_groups.json` is a singleton no-LLM fallback, not Martian's official LLM dedup.
- This still does not validate PCRS as a general approach and does not create a public benchmark claim.

Next research move:

Configure `MARTIAN_API_KEY` and a fixed `MARTIAN_MODEL`, run Martian Step 2, Step 2.5, Step 3, and dashboard locally for `sugary-pcrs-repo-budget-max2`, then compare the official local precision/recall/F1 against CodeRabbit, Cubic, Greptile, and the other bundled tools without submitting anything.

## 2026-05-30: Martian No-Key Comparison v0

Command sequence:

```sh
mix escript.build
./sugary martian no-key report --sugary-tool sugary-pcrs-repo-budget-max2 --model-dir sugary_local_parity_v0 --martian-dir .sugary/research/benchmarks/martian-offline/offline --id martian-no-key-comparison-v0
```

Run artifact:

```text
.sugary/research/martian-no-key/20260530T154335Z-martian-no-key-comparison-v0
```

Scope:

- API key: none.
- Official Sugary score: no.
- Existing bundled Martian evaluations: yes.
- Sugary status: exported but unjudged.

Sugary pending judge workload:

| Item | Count |
| --- | ---: |
| PRs with Sugary review entry | 50/50 |
| Sugary candidates awaiting Martian judge | 51 |
| Candidate/golden judge pairs | 145 |

Competitor focus from bundled evaluations, averaged across three judge models:

| Tool | Avg F1 | Avg Precision | Avg Recall | Avg candidates/PR |
| --- | ---: | ---: | ---: | ---: |
| `cubic-v2` | 0.608 | 0.552 | 0.676 | 3.493 |
| `cubic-dev` | 0.417 | 0.289 | 0.752 | 7.527 |
| `greptile-v4-1` | 0.413 | 0.372 | 0.465 | 3.587 |
| `greptile-v4` | 0.406 | 0.312 | 0.582 | 5.400 |
| `greptile` | 0.400 | 0.409 | 0.392 | 2.853 |
| `coderabbit` | 0.352 | 0.255 | 0.569 | 6.427 |

Top bundled tool:

- `cubic-v2` averaged 0.608 F1 across the bundled judge files.
- `cubic-v2` used about 3.5 candidates per PR, which is far denser than Sugary's current 51 candidates across 50 PRs.

Interpretation:

- Without `MARTIAN_API_KEY`, the best available work is target analysis, proxy iteration, and making the official score gap explicit.
- Sugary's exported candidate budget is conservative relative to top bundled tools, so the next no-key research loop should focus on higher-recall candidate generation while preserving the budgeted publisher.
- Any claim that Sugary beats or trails these tools must wait for official judging of Sugary's candidates.

## 2026-05-30: PCRS Ensemble Publisher v0

Command sequence:

```sh
mix escript.build
./sugary pcrs ensemble publisher --id pcrs-ensemble-publisher-v0 --limit 50 --offset 0
./sugary martian parity export --source-run .sugary/research/pcrs-ensemble-publisher/20260530T162313Z-pcrs-ensemble-publisher-v0 --method pcrs-ensemble-publisher-v0 --tool sugary-pcrs-ensemble-v0 --policy raw --martian-dir .sugary/research/benchmarks/martian-offline/offline --model-dir sugary_pcrs_ensemble_v0 --limit 50 --offset 0 --id pcrs-ensemble-v0-parity
./sugary martian no-key report --sugary-tool sugary-pcrs-ensemble-v0 --model-dir sugary_pcrs_ensemble_v0 --martian-dir .sugary/research/benchmarks/martian-offline/offline --id pcrs-ensemble-v0-no-key
```

Run artifacts:

```text
.sugary/research/pcrs-ensemble-publisher/20260530T162313Z-pcrs-ensemble-publisher-v0
.sugary/research/martian-parity/20260530T162334Z-pcrs-ensemble-v0-parity
.sugary/research/martian-no-key/20260530T162334Z-pcrs-ensemble-v0-no-key
```

Scope:

- API key: none.
- Official Sugary score: no.
- Source candidates: six existing no-key Martian reviewer runs.
- Publisher: proof/evidence/refuter feature scoring, duplicate grouping, posterior policies, recall-at-budget, suppressed-TP/admitted-FP diagnostics, calibration, and leave-repo-out reporting.

Baseline:

| Metric | Value |
| --- | ---: |
| Baseline method | `pcrs-codex-repo-low-strict + team-ev-max-2` |
| F1 | 0.362 |
| UAF1 | 0.241 |
| Hits | 34 |
| Noise | 17 |
| Avg comments/PR | 1.020 |

Best publisher:

| Metric | Value |
| --- | ---: |
| Policy | `posterior-max1-plus-source5-qualified-triad-budget52` |
| F1 | 0.444 |
| UAF1 | 0.359 |
| Hits | 42 |
| Noise | 10 |
| Comments | 52 |
| Avg comments/PR | 1.040 |
| Candidate-pool oracle recall | 0.489 |
| Pool hits | 67/137 |

Gate result:

| Gate | Result |
| --- | --- |
| F1 >= 0.430 | pass |
| UAF1 >= 0.300 | pass |
| Hits >= 41 | pass |
| Noise <= 11 | pass |
| Avg comments/PR <= 1.05 | pass |
| Candidate-pool oracle recall >= 0.45 | pass |
| Recall@budget improves over baseline | pass |
| Nonnegative UAF1 delta on 4/5 repo groups | pass |

Repo group generalization:

| Repo | UAF1 delta | Hit delta | Noise delta | Pass |
| --- | ---: | ---: | ---: | --- |
| `cal.com` | -0.121 | -2 | +2 | false |
| `discourse` | +0.382 | +4 | -6 | true |
| `grafana` | +0.251 | +4 | -1 | true |
| `keycloak` | 0.000 | 0 | 0 | true |
| `sentry` | +0.125 | +2 | -2 | true |

Martian no-key export:

| Item | Count |
| --- | ---: |
| PRs with Sugary review entry | 50/50 |
| Sugary candidates awaiting Martian judge | 52 |
| Candidate/golden judge pairs | 148 |

Interpretation:

- The aggregate no-key proxy target is reachable with a calibrated publisher over the existing candidate pool.
- The promoted local proxy policy is still not an official Martian result and should not be described as benchmark superiority until Martian judges Sugary's candidates.
- The qualified-triad rule is a useful source-composition calibration, but it needs validation on fresh cases before it becomes a public default.
- The next valuable loop is not more threshold tuning. It is adding candidate generation or proof/refutation that specifically improves Cal.com without increasing the global false-positive rate.

## 2026-05-30: PCRS Ensemble Publisher v1 Frontier

Checkpoint:

```text
git tag: research/pcrs-ensemble-publisher-v0-local-pass
commit: 56fc260
checksum manifest: docs/artifact-checksums/pcrs-ensemble-publisher-v0-local-pass.sha256
checksum manifest sha256: 3dec579557b5f5227b45a6c027cc7616e3a21a4b7961bb67eb1d7b3b2842f173
```

Command sequence:

```sh
mix escript.build
./sugary pcrs ensemble publisher --id pcrs-ensemble-frontier-v1 --limit 50 --offset 0
./sugary martian parity export --source-run .sugary/research/pcrs-ensemble-publisher/20260530T164625Z-pcrs-ensemble-frontier-v1 --method posterior-max1-plus-source5-qualified-triad-budget52 --tool sugary-pcrs-trust-v1 --policy raw --martian-dir .sugary/research/benchmarks/martian-offline/offline --model-dir sugary_pcrs_trust_v1 --limit 50 --offset 0 --id pcrs-trust-v1-parity
./sugary martian parity export --source-run .sugary/research/pcrs-ensemble-publisher/20260530T164625Z-pcrs-ensemble-frontier-v1 --method frontier-aggressive-budget72-source1-qualified-triad --tool sugary-pcrs-frontier-f1-v1 --policy raw --martian-dir .sugary/research/benchmarks/martian-offline/offline --model-dir sugary_pcrs_frontier_f1_v1 --limit 50 --offset 0 --id pcrs-frontier-f1-v1-parity
```

Run artifacts:

```text
.sugary/research/pcrs-ensemble-publisher/20260530T164625Z-pcrs-ensemble-frontier-v1
.sugary/research/martian-parity/20260530T164652Z-pcrs-trust-v1-parity
.sugary/research/martian-parity/20260530T164652Z-pcrs-frontier-f1-v1-parity
.sugary/research/martian-no-key/20260530T164652Z-pcrs-trust-v1-no-key
.sugary/research/martian-no-key/20260530T164653Z-pcrs-frontier-f1-v1-no-key
```

Budget frontier:

| Budget | Max possible F1 | Best local proxy policy | F1 | Precision | Recall | Hits | Noise | Comments |
| ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| 52 | 0.550 | `posterior-max1-plus-source5-qualified-triad-budget52` | 0.444 | 0.808 | 0.307 | 42 | 10 | 52 |
| 62 | 0.623 | `frontier-balanced-budget62-source2-qualified-triad` | 0.452 | 0.726 | 0.328 | 45 | 17 | 62 |
| 72 | 0.689 | `frontier-aggressive-budget72-source1-qualified-triad` | 0.478 | 0.721 | 0.358 | 49 | 19 | 68 |
| 85 | 0.766 | `frontier-leaderboard-budget85-max-f1-diagnostic` | 0.493 | 0.679 | 0.387 | 53 | 25 | 78 |

Decision:

| Candidate | Decision | Reason |
| --- | --- | --- |
| Trust mode | keep | v0 remains the product-default policy: F1 0.444, precision 0.808, 52 comments. |
| Leaderboard precision-floor mode | promote locally | Budget72 improves F1 to 0.478 while staying above the 0.70 precision floor. |
| Budget85 max-F1 diagnostic | reject for promotion | F1 rises to 0.493, but precision falls below the 0.70 floor. |

Bootstrap:

| Candidate | UAF1 delta vs team-ev-max-2 | UAF1 delta vs v0 |
| --- | ---: | ---: |
| Trust mode | +0.118 [+0.028, +0.216] | 0.000 [0.000, 0.000] |
| Budget72 F1 mode | +0.102 [+0.019, +0.200] | -0.015 [-0.072, +0.039] |

Martian no-key exports:

| Tool | Candidates | PRs with candidates | Judge pairs | Official score |
| --- | ---: | ---: | ---: | --- |
| `sugary-pcrs-trust-v1` | 52 | 46/50 | 148 | unavailable without `MARTIAN_API_KEY` |
| `sugary-pcrs-frontier-f1-v1` | 68 | 48/50 | 200 | unavailable without `MARTIAN_API_KEY` |

Interpretation:

- The trust/default policy remains the best user-facing policy by UAF1 and precision.
- A separate F1-oriented candidate exists: budget72 adds seven more true positives than trust mode, but also admits nine more false positives.
- The F1-oriented candidate beats v0 on F1, but does not beat v0 on UAF1. This supports maintaining two modes instead of forcing one policy to optimize both product trust and benchmark F1.
- Budget85 currently exposes the candidate-pool/publisher limit: more budget can find more hits, but precision drops below the promotion floor. The next useful research should raise candidate quality or add a stronger refuter before spending that budget.

## 2026-05-30: PCRS Ensemble Publisher v2 Tail Verification

Checkpoint:

```text
branch: codex/pcrs-v2-tail-verification
baseline commit: 6a2df4b
status: local no-key proxy passed
official Martian score: not claimed
```

Command sequence:

```sh
mix escript.build
./sugary pcrs ensemble publisher --id pcrs-ensemble-tail-v2 --limit 50 --offset 0
./sugary martian parity export --source-run .sugary/research/pcrs-ensemble-publisher/20260530T171619Z-pcrs-ensemble-tail-v2 --method posterior-max1-plus-source5-qualified-triad-budget52 --tool sugary-pcrs-trust-v2 --policy raw --martian-dir .sugary/research/benchmarks/martian-offline/offline --model-dir sugary_pcrs_trust_v2 --limit 50 --offset 0 --id pcrs-trust-v2-parity
./sugary martian parity export --source-run .sugary/research/pcrs-ensemble-publisher/20260530T171619Z-pcrs-ensemble-tail-v2 --method qualified-f1-trust-plus-tail-team-xhigh-budget78 --tool sugary-pcrs-qualified-f1-v2 --policy raw --martian-dir .sugary/research/benchmarks/martian-offline/offline --model-dir sugary_pcrs_qualified_f1_v2 --limit 50 --offset 0 --id pcrs-qualified-f1-v2-parity
./sugary martian parity export --source-run .sugary/research/pcrs-ensemble-publisher/20260530T171619Z-pcrs-ensemble-tail-v2 --method raw-f1-tail-diagnostic-budget110 --tool sugary-pcrs-raw-f1-v2 --policy raw --martian-dir .sugary/research/benchmarks/martian-offline/offline --model-dir sugary_pcrs_raw_f1_v2 --limit 50 --offset 0 --id pcrs-raw-f1-v2-parity
```

Run artifacts:

```text
.sugary/research/pcrs-ensemble-publisher/20260530T171619Z-pcrs-ensemble-tail-v2
.sugary/research/martian-parity/20260530T171727Z-pcrs-trust-v2-parity
.sugary/research/martian-parity/20260530T171734Z-pcrs-qualified-f1-v2-parity
.sugary/research/martian-parity/20260530T171741Z-pcrs-raw-f1-v2-parity
.sugary/research/martian-no-key/20260530T171749Z-pcrs-trust-v2-no-key
.sugary/research/martian-no-key/20260530T171754Z-pcrs-qualified-f1-v2-no-key
.sugary/research/martian-no-key/20260530T171758Z-pcrs-raw-f1-v2-no-key
```

Core results:

| Policy | Mode | F1 | Precision | Recall | Hits | Noise | Comments |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `posterior-max1-plus-source5-qualified-triad-budget52` | trust/default | 0.455 | 0.827 | 0.314 | 43 | 9 | 52 |
| `qualified-f1-trust-plus-tail-team-xhigh-budget78` | qualified F1 | 0.521 | 0.718 | 0.409 | 56 | 22 | 78 |
| `raw-f1-tail-diagnostic-budget110` | raw F1 diagnostic | 0.494 | 0.555 | 0.445 | 61 | 49 | 110 |

V2 gate:

| Gate | Result |
| --- | --- |
| Trust/default F1 >= 0.444 | pass: 0.455 |
| Trust/default precision >= 0.800 | pass: 0.827 |
| Qualified F1 >= 0.520 | pass: 0.521 |
| Qualified precision >= 0.700 | pass: 0.718 |
| Qualified hits >= 56 | pass: 56 |
| Candidate-pool oracle recall >= 0.570 | pass: 79/137 = 0.577 |
| Repo groups nonnegative on at least 4/5 | pass: 4/5 |
| No official score claim | pass |

Design change:

- Keep trust/default on the legacy core ranker.
- Expand the candidate pool with historical non-oracle tail sources.
- Add a qualified-F1 publisher that preserves the trust set, then admits at most one team-backed or xhigh tail claim per PR after near-duplicate suppression.
- Keep raw-F1 as diagnostic only; it finds more hits but admits too much noise for promotion.

Martian no-key exports:

| Tool | Candidates | PRs with candidates | Judge pairs | Official score |
| --- | ---: | ---: | ---: | --- |
| `sugary-pcrs-trust-v2` | 52 | 46/50 | 148 | unavailable without `MARTIAN_API_KEY` |
| `sugary-pcrs-qualified-f1-v2` | 78 | 47/50 | 229 | unavailable without `MARTIAN_API_KEY` |
| `sugary-pcrs-raw-f1-v2` | 110 | 50/50 | 327 | unavailable without `MARTIAN_API_KEY` |

Interpretation:

- V2 clears the local no-key stretch target, but it is still a proxy result, not public benchmark validation.
- The useful product shape is now clearer: trust/default and qualified-F1 should be separate policies.
- Tail expansion without a publisher is harmful; the raw diagnostic has higher recall but much lower precision.
- The next loop should validate whether these exported candidates survive real Martian judging or reproduce on a fresh public slice before productizing the qualified-F1 mode.

## 2026-05-30: PCRS v3 No-Key Recall + Judge-Risk Gauntlet

Checkpoint:

```text
branch: codex/pcrs-v3-no-key-gauntlet
baseline commit: 6f1bf71
status: negative result against stretch target
official Martian score: not claimed
Martian API key used: no
```

Command sequence:

```sh
mix escript.build
./sugary experiment run experiments/martian-pcrs-v3-repo-xhigh-candidate.toml --replay-mode cache-first
./sugary experiment run experiments/martian-pcrs-v3-repo-grep-low-candidate.toml --replay-mode refresh
./sugary experiment run experiments/martian-pcrs-v3-repo-grep-raw-low-candidate.toml --replay-mode refresh
./sugary pcrs ensemble publisher --id pcrs-ensemble-v3-no-key-diagnostics --limit 50 --offset 0
./sugary martian parity export --source-run .sugary/research/pcrs-ensemble-publisher/20260530T215959Z-pcrs-ensemble-v3-no-key-diagnostics --method posterior-max1-plus-source5-qualified-triad-budget52 --tool sugary-pcrs-trust-v3 --policy raw --martian-dir .sugary/research/benchmarks/martian-offline/offline --model-dir sugary_pcrs_trust_v3 --limit 50 --offset 0 --id pcrs-trust-v3-parity
./sugary martian parity export --source-run .sugary/research/pcrs-ensemble-publisher/20260530T215959Z-pcrs-ensemble-v3-no-key-diagnostics --method qualified-f1-trust-plus-tail-team-xhigh-budget78 --tool sugary-pcrs-qualified-f1-v3 --policy raw --martian-dir .sugary/research/benchmarks/martian-offline/offline --model-dir sugary_pcrs_qualified_f1_v3 --limit 50 --offset 0 --id pcrs-qualified-f1-v3-parity
./sugary martian parity export --source-run .sugary/research/pcrs-ensemble-publisher/20260530T215959Z-pcrs-ensemble-v3-no-key-diagnostics --method raw-f1-tail-diagnostic-budget110 --tool sugary-pcrs-raw-f1-v3 --policy raw --martian-dir .sugary/research/benchmarks/martian-offline/offline --model-dir sugary_pcrs_raw_f1_v3 --limit 50 --offset 0 --id pcrs-raw-f1-v3-parity
./sugary martian no-key report --sugary-tool sugary-pcrs-trust-v3 --model-dir sugary_pcrs_trust_v3 --martian-dir .sugary/research/benchmarks/martian-offline/offline --id pcrs-trust-v3-no-key
./sugary martian no-key report --sugary-tool sugary-pcrs-qualified-f1-v3 --model-dir sugary_pcrs_qualified_f1_v3 --martian-dir .sugary/research/benchmarks/martian-offline/offline --id pcrs-qualified-f1-v3-no-key
./sugary martian no-key report --sugary-tool sugary-pcrs-raw-f1-v3 --model-dir sugary_pcrs_raw_f1_v3 --martian-dir .sugary/research/benchmarks/martian-offline/offline --id pcrs-raw-f1-v3-no-key
```

Run artifacts:

```text
.sugary/research/runs/20260530T174649Z-martian-pcrs-v3-repo-xhigh-candidate
.sugary/research/runs/20260530T201021Z-martian-pcrs-v3-repo-grep-low-candidate
.sugary/research/runs/20260530T210358Z-martian-pcrs-v3-repo-grep-raw-low-candidate
.sugary/research/pcrs-ensemble-publisher/20260530T215959Z-pcrs-ensemble-v3-no-key-diagnostics
.sugary/research/martian-parity/20260530T220136Z-pcrs-trust-v3-parity
.sugary/research/martian-parity/20260530T220140Z-pcrs-qualified-f1-v3-parity
.sugary/research/martian-parity/20260530T220145Z-pcrs-raw-f1-v3-parity
.sugary/research/martian-no-key/20260530T220147Z-pcrs-trust-v3-no-key
.sugary/research/martian-no-key/20260530T220150Z-pcrs-qualified-f1-v3-no-key
.sugary/research/martian-no-key/20260530T220153Z-pcrs-raw-f1-v3-no-key
```

V3 publisher result:

| Gate | Result |
| --- | --- |
| Trust/default F1 >= 0.455 | pass: 0.455 |
| Trust/default precision >= 0.820 | pass: 0.827 |
| Qualified F1 >= 0.545 | fail: 0.521 |
| Qualified precision >= 0.720 | fail: 0.718 |
| Qualified hits >= 61 | fail: 56 |
| Qualified noise <= 23 | pass: 22 |
| Candidate-pool hits >= 90 | fail: 79 |
| Candidate-pool oracle recall >= 90/137 | fail: 0.577 |
| Raw diagnostic hits >= 70 | fail: 61 |
| Repo groups passing or diagnosed | pass |

Candidate-generation variables:

| Variable | Hits | Noise | Claims/comments | Unique hits over v2 pool | Decision |
| --- | ---: | ---: | ---: | ---: | --- |
| `pcrs-codex-repo-xhigh` | 6 | 2 | 12 raw claims | 0 | reject: slow, sparse, usage-limit sensitive |
| `pcrs-codex-repo-grep-low` | 36 | 24 | 66 raw claims | 1 | reject as promoted source; useful diagnostic |
| `codex-repo-grep-low-raw` | 33 | 21 | 58 raw claims | 0 | reject: removes proof wrapper but does not add unique recall |

New diagnostics added:

- `missing-gold-analysis.json`
- `tail-verifier-analysis.json`
- `judge-risk-report.json`
- `repo-group-diagnostics.json`

Interpretation:

- The v3 stretch target was not met.
- The candidate-pool ceiling moved only from 79 to 80 when adding the best new repo-grep source, far short of the 90/137 target.
- Repo-grep compact context is a useful harness variable because it produces real claims after quota reset, but it mostly duplicates existing v2 hits on this slice.
- Xhigh reasoning is not a good no-key default in this setup: it is slow, timeout-prone, and added no unique local gold claims.
- The next high-value step is not another publisher tweak. It is a new candidate-generation approach that can find missing Sentry/Grafana/Keycloak categories, or a proper provider/API key so the loop can run larger model/tool sweeps without quota interruption.

## 2026-05-30: PCRS v3 Continuation - Symbol Search + Contract Specialist

Checkpoint:

```text
branch: codex/pcrs-v3-no-key-gauntlet
status: improved but still below stretch target
official Martian score: not claimed
Martian API key used: no
```

What changed:

- Corrected the v3 publisher source list so repo-grep, raw repo-grep, xhigh, symbol-search, and contract-specialist runs are actually included in the candidate pool.
- Added bounded repo-wide symbol search as a new harness variable.
- Added optional specialist prompt injection to the Codex repo reviewer.
- Added a contract/integration specialist candidate run.
- Added a deduped posterior strategy for judge-risk-aware qualified publishing.

Command sequence:

```sh
./sugary pcrs ensemble publisher --id pcrs-ensemble-v3-repo-grep-sources --limit 50 --offset 0
./sugary experiment run experiments/martian-pcrs-v3-repo-symbol-low-candidate.toml --replay-mode refresh
./sugary pcrs ensemble publisher --id pcrs-ensemble-v3-symbol-sources --limit 50 --offset 0
./sugary pcrs ensemble publisher --id pcrs-ensemble-v3-deduped-judge-risk --limit 50 --offset 0
./sugary experiment run experiments/martian-pcrs-v3-contract-specialist-low-candidate.toml --replay-mode refresh
./sugary pcrs ensemble publisher --id pcrs-ensemble-v3-contract-specialist-sources --limit 50 --offset 0
./sugary martian parity export --source-run .sugary/research/pcrs-ensemble-publisher/20260531T000037Z-pcrs-ensemble-v3-contract-specialist-sources --method posterior-max1-plus-source5-qualified-triad-budget52 --tool sugary-pcrs-trust-v3b --policy raw --martian-dir .sugary/research/benchmarks/martian-offline/offline --model-dir sugary_pcrs_trust_v3b --limit 50 --offset 0 --id pcrs-trust-v3b-parity
./sugary martian parity export --source-run .sugary/research/pcrs-ensemble-publisher/20260531T000037Z-pcrs-ensemble-v3-contract-specialist-sources --method qualified-f1-judge-risk-budget84-max3 --tool sugary-pcrs-qualified-f1-v3b --policy raw --martian-dir .sugary/research/benchmarks/martian-offline/offline --model-dir sugary_pcrs_qualified_f1_v3b --limit 50 --offset 0 --id pcrs-qualified-f1-v3b-parity
./sugary martian parity export --source-run .sugary/research/pcrs-ensemble-publisher/20260531T000037Z-pcrs-ensemble-v3-contract-specialist-sources --method raw-f1-tail-diagnostic-budget110 --tool sugary-pcrs-raw-f1-v3b --policy raw --martian-dir .sugary/research/benchmarks/martian-offline/offline --model-dir sugary_pcrs_raw_f1_v3b --limit 50 --offset 0 --id pcrs-raw-f1-v3b-parity
./sugary martian no-key report --sugary-tool sugary-pcrs-trust-v3b --model-dir sugary_pcrs_trust_v3b --martian-dir .sugary/research/benchmarks/martian-offline/offline --id pcrs-trust-v3b-no-key
./sugary martian no-key report --sugary-tool sugary-pcrs-qualified-f1-v3b --model-dir sugary_pcrs_qualified_f1_v3b --martian-dir .sugary/research/benchmarks/martian-offline/offline --id pcrs-qualified-f1-v3b-no-key
./sugary martian no-key report --sugary-tool sugary-pcrs-raw-f1-v3b --model-dir sugary_pcrs_raw_f1_v3b --martian-dir .sugary/research/benchmarks/martian-offline/offline --id pcrs-raw-f1-v3b-no-key
```

Run artifacts:

```text
.sugary/research/runs/20260530T220639Z-martian-pcrs-v3-repo-symbol-low-candidate
.sugary/research/runs/20260530T230843Z-martian-pcrs-v3-contract-specialist-low-candidate
.sugary/research/pcrs-ensemble-publisher/20260531T000037Z-pcrs-ensemble-v3-contract-specialist-sources
.sugary/research/martian-parity/20260531T000135Z-pcrs-trust-v3b-parity
.sugary/research/martian-parity/20260531T000140Z-pcrs-qualified-f1-v3b-parity
.sugary/research/martian-parity/20260531T000144Z-pcrs-raw-f1-v3b-parity
.sugary/research/martian-no-key/20260531T000149Z-pcrs-trust-v3b-no-key
.sugary/research/martian-no-key/20260531T000153Z-pcrs-qualified-f1-v3b-no-key
.sugary/research/martian-no-key/20260531T000157Z-pcrs-raw-f1-v3b-no-key
```

Final v3b publisher result:

| Gate | Result |
| --- | --- |
| Trust/default F1 >= 0.455 | pass: 0.466 |
| Trust/default precision >= 0.820 | pass: 0.846 |
| Qualified F1 >= 0.545 | fail: 0.528 |
| Qualified precision >= 0.720 | pass: 0.722 |
| Qualified hits >= 61 | fail: 57 |
| Qualified noise <= 23 | pass: 22 |
| Candidate-pool hits >= 90 | fail: 81 |
| Candidate-pool oracle recall >= 90/137 | fail: 0.591 |
| Raw diagnostic hits >= 70 | fail: 61 |
| Repo groups passing or diagnosed | pass |

Candidate-generation variables:

| Variable | Standalone hits | Noise | Unique hits over current pool | Decision |
| --- | ---: | ---: | ---: | --- |
| `pcrs-codex-repo-symbol-low` | 31 | 26 | 1 | reject as standalone; keep as low-prior tail source |
| `pcrs-codex-contract-specialist-low` | 36 | 38 | 2 | reject as standalone; keep as low-prior tail source |

Interpretation:

- Source-list correction showed repo-grep added raw volume but did not add scored pool recall.
- Symbol search was too slow/noisy as a standalone reviewer and added only one unique local-gold hit.
- Contract specialization added a Sentry miss and improved the trust/default publisher, but it was still noisy as a standalone reviewer.
- The deduped judge-risk publisher moved the qualified policy across the precision/noise gates, but not the F1/hit gates.
- The active bottleneck is still candidate generation, not publishing. We need roughly 9 more unique local-gold hits in the candidate pool before the 90/137 target is reachable.

## 2026-05-30: PCRS v3 Static Proof Patterns + Deduped Publisher Fix

Checkpoint:

```text
branch: codex/pcrs-v3-no-key-gauntlet
status: local no-key proxy gates cleared
official Martian score: not claimed
Martian API key used: no
```

What changed:

- Added deterministic static proof patterns v2 as a no-key candidate source.
- Kept the variable scoped: no new model, no external API, no official submission.
- Corrected static proof paths so tail verification can distinguish changed-file proof from loose text matches.
- Fixed a publisher materialization bug where `deduped_posterior` could globally select a candidate that was later dropped because only the local top `max_per_pr` candidates were materialized for scoring.
- Added a non-promotable wide raw diagnostic policy to measure recall ceiling separately from shippable review modes.

Command sequence:

```sh
./sugary experiment run experiments/martian-pcrs-v3-static-patterns-candidate.toml --replay-mode refresh
./sugary pcrs ensemble publisher --limit 50 --id pcrs-ensemble-v3-static-patterns-wide-raw
./sugary martian parity export --source-run .sugary/research/pcrs-ensemble-publisher/20260531T001945Z-pcrs-ensemble-v3-static-patterns-wide-raw --method posterior-max1-plus-source5-qualified-triad-budget52 --tool sugary-pcrs-v3-trust-static --model-dir sugary_pcrs_v3_trust_static --id pcrs-v3-trust-static-parity --policy raw
./sugary martian parity export --source-run .sugary/research/pcrs-ensemble-publisher/20260531T001945Z-pcrs-ensemble-v3-static-patterns-wide-raw --method qualified-f1-judge-risk-budget84-max3 --tool sugary-pcrs-v3-qualified-static --model-dir sugary_pcrs_v3_qualified_static --id pcrs-v3-qualified-static-parity --policy raw
./sugary martian parity export --source-run .sugary/research/pcrs-ensemble-publisher/20260531T001945Z-pcrs-ensemble-v3-static-patterns-wide-raw --method raw-recall-diagnostic-budget160-deduped-max6 --tool sugary-pcrs-v3-raw-static-diagnostic --model-dir sugary_pcrs_v3_raw_static_diagnostic --id pcrs-v3-raw-static-diagnostic-parity --policy raw
./sugary martian no-key report --sugary-tool sugary-pcrs-v3-trust-static --model-dir sugary_pcrs_v3_trust_static --id pcrs-v3-trust-static-no-key
./sugary martian no-key report --sugary-tool sugary-pcrs-v3-qualified-static --model-dir sugary_pcrs_v3_qualified_static --id pcrs-v3-qualified-static-no-key
./sugary martian no-key report --sugary-tool sugary-pcrs-v3-raw-static-diagnostic --model-dir sugary_pcrs_v3_raw_static_diagnostic --id pcrs-v3-raw-static-diagnostic-no-key
```

Run artifacts:

```text
.sugary/research/runs/20260531T001509Z-martian-pcrs-v3-static-patterns-candidate
.sugary/research/pcrs-ensemble-publisher/20260531T001945Z-pcrs-ensemble-v3-static-patterns-wide-raw
.sugary/research/martian-parity/20260531T002108Z-pcrs-v3-trust-static-parity
.sugary/research/martian-parity/20260531T002118Z-pcrs-v3-qualified-static-parity
.sugary/research/martian-parity/20260531T002127Z-pcrs-v3-raw-static-diagnostic-parity
.sugary/research/martian-no-key/20260531T002114Z-pcrs-v3-trust-static-no-key
.sugary/research/martian-no-key/20260531T002122Z-pcrs-v3-qualified-static-no-key
.sugary/research/martian-no-key/20260531T002131Z-pcrs-v3-raw-static-diagnostic-no-key
```

Final publisher result:

| Gate | Result |
| --- | --- |
| Trust/default F1 >= 0.455 | pass: 0.466 |
| Trust/default precision >= 0.820 | pass: 0.846 |
| Qualified F1 >= 0.545 | pass: 0.552 |
| Qualified precision >= 0.720 | pass: 0.726 |
| Qualified hits >= 61 | pass: 61 |
| Qualified noise <= 23 | pass: 23 |
| Candidate-pool hits >= 90 | pass: 101 |
| Candidate-pool oracle recall >= 90/137 | pass: 0.737 |
| Raw diagnostic hits >= 70 | pass: 86 |
| Repo groups passing or diagnosed | pass |

Key policy results:

| Policy | Hits | Noise | Precision | Recall | F1 | Comments |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| `posterior-max1-plus-source5-qualified-triad-budget52` | 44 | 8 | 0.846 | 0.321 | 0.466 | 52 |
| `qualified-f1-judge-risk-budget84-max3` | 61 | 23 | 0.726 | 0.445 | 0.552 | 84 |
| `raw-recall-diagnostic-budget160-deduped-max6` | 86 | 66 | 0.566 | 0.628 | 0.595 | 152 |

Static proof source result:

| Reviewer | Hits | Noise | Precision | F1 | Unique hits over v3b pool |
| --- | ---: | ---: | ---: | ---: | ---: |
| `public-static-proof-gate` v2 | 24 | 2 | 0.923 | 0.294 | 20 |

Interpretation:

- This clears the local no-key proxy target, not an official Martian score.
- The most important result is not the raw diagnostic score; that policy is intentionally non-promotable and noisy.
- The useful product-shaped result is the qualified policy crossing the F1/hits/precision/noise gates after the candidate pool gained static proof coverage and the deduped publisher bug was fixed.
- The next research question is generalization: these deterministic patterns helped the first 50 local Martian cases, so the next loop should test whether the same proof-pattern class transfers to a separate offset/holdout slice without adding benchmark-specific leakage.

## 2026-05-30: Locked PCRS v3 AACR Transfer Gate

Checkpoint:

```text
branch: codex/pcrs-v3-no-key-gauntlet
status: clean negative transfer result
official benchmark score: not claimed
Martian API key used: no
AACR API key used: no
```

What changed:

- Added an AACR-Bench local public adapter.
- Added a locked PCRS transfer gate that records the Martian-source PCRS v3 checkpoint, runs a frozen candidate on a separate public smoke suite, and reports the generalization gap.
- Kept the reviewer fixed: no AACR-specific static patterns, no prompt changes, no threshold changes.
- Model-backed PCRS ensemble transfer is explicitly skipped until equivalent candidate source artifacts exist for AACR.

Command sequence:

```sh
git clone --depth 1 https://github.com/alibaba/aacr-bench.git .sugary/research/benchmarks/aacr-bench
mix run -e 'IO.puts(Sugary.TransferGate.run!(%{"id" => "locked-pcrs-v3-aacr-transfer-v0-limit50", "suite" => "aacr-bench", "limit" => 50, "offset" => 0, "locked-commit" => "e66b567"}))'
```

Run artifacts:

```text
.sugary/research/transfer-gates/20260531T022219Z-locked-pcrs-v3-aacr-transfer-v0-limit50
.sugary/research/runs/20260531T022219Z-locked-pcrs-v3-aacr-transfer-v0-limit50-smoke
.sugary/research/public-smoke/20260531T022219Z-locked-pcrs-v3-aacr-transfer-v0-limit50-smoke
```

Transfer result on first 50 AACR cases:

| Method | Expected Claims | Hits | Noise | Precision | Recall | F1 | Comments |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `baseline-diff-only` | 467 | 0 | 0 | 0.000 | 0.000 | 0.000 | 0 |
| `public-static-proof-gate` | 467 | 0 | 0 | 0.000 | 0.000 | 0.000 | 0 |

Source checkpoint for comparison:

| Source | Hits | Noise | Precision | Recall | F1 | Comments |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Static proof on Martian source | 24 | 2 | 0.923 | 0.175 | 0.294 | 26 |
| Trust publisher on Martian source | 44 | 8 | 0.846 | 0.321 | 0.466 | 52 |
| Qualified publisher on Martian source | 61 | 23 | 0.726 | 0.445 | 0.552 | 84 |

Leakage checks:

| Check | Result |
| --- | --- |
| Input case-id leaks | pass: none |
| Oracle input files | pass: none |
| Official/API submission | pass: none |

Interpretation:

- The current deterministic static-proof source does not transfer to AACR. It emitted zero claims on 50 cases covering 467 scorer-only reference comments.
- This is useful negative evidence, not a product failure. It means the prior win was dominated by Martian-specific candidate-source coverage.
- The next high-value loop should not tune AACR-specific patterns. It should introduce one benchmark-agnostic variable at a time: repo-aware retrieval, a real model-backed candidate generator, or a small proof tool that can produce claims across projects.
- The transfer gate itself is now useful infrastructure: it prevents us from mistaking local benchmark optimization for general review capability.

## 2026-05-31: PCRS v4 Portable Candidate Generator Transfer Gate

Checkpoint:

```text
branch: codex/pcrs-v3-no-key-gauntlet
status: mixed/negative transfer result
official benchmark score: not claimed
Martian API key used: no
AACR API key used: no
model boundary: Codex CLI command reviewer
```

What changed:

- Added `sugary pcrs portable transfer gate`.
- Added a benchmark-agnostic portable Codex repo reviewer variable:
  `pcrs-v4-portable-codex-repo-low`.
- The reviewer receives only sanitized `ReviewInputBundle` JSON.
- If a local base/head checkout exists, Sugary passes blinded workspace paths.
- Added candidate-pool metrics, published metrics, static-proof ablation, leakage reporting, workspace reporting, and Martian publisher guardrails.
- Added first-class experiment manifests for Martian and AACR portable transfer runs.

Command:

```sh
mix run -e 'IO.puts(Sugary.PortableTransferGate.run!(%{"id" => "pcrs-v4-portable-transfer-first50", "suites" => "martian-offline,aacr-bench", "limit" => 50, "replay-mode" => "cache-first"}))'
```

Run artifacts:

```text
.sugary/research/transfer-gates/20260531T153346Z-pcrs-v4-portable-transfer-first50
.sugary/research/runs/20260531T153346Z-pcrs-v4-portable-transfer-first50-martian-offline
.sugary/research/runs/20260531T161920Z-pcrs-v4-portable-transfer-first50-aacr-bench
.sugary/research/pcrs-ensemble-publisher/20260531T163040Z-pcrs-v4-portable-transfer-first50-martian-publisher
```

Standalone first-50 transfer result:

| Suite | Method | Workspace Inputs | Expected | Pool Hits | Pool Claims | Published Hits | Noise | Precision | Recall | F1 | Comments |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Martian | `public-static-proof-gate` | 50 / 50 | 137 | 24 | 26 | 24 | 2 | 0.923 | 0.175 | 0.294 | 26 |
| Martian | `pcrs-v4-portable-codex-repo-low` | 50 / 50 | 137 | 36 | 63 | 36 | 27 | 0.571 | 0.263 | 0.360 | 63 |
| AACR | `public-static-proof-gate` | 0 / 50 | 467 | 0 | 0 | 0 | 0 | 0.000 | 0.000 | 0.000 | 0 |
| AACR | `pcrs-v4-portable-codex-repo-low` | 0 / 50 | 467 | 7 | 41 | 7 | 35 | 0.171 | 0.015 | 0.028 | 41 |

Martian publisher guardrail with the portable source added as a tail source:

| Policy | Hits | Noise | Precision | Recall | F1 | Comments | Gate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `posterior-max1-plus-source5-qualified-triad-budget52` | 44 | 8 | 0.846 | 0.321 | 0.466 | 52 | miss exact F1 floor by 0.0004 |
| `qualified-f1-judge-risk-budget84-max3` | 62 | 22 | 0.738 | 0.453 | 0.561 | 84 | pass |

Leakage checks:

| Check | Martian | AACR |
| --- | --- | --- |
| Input case-id leaks | pass | pass |
| Oracle input files | pass | pass |
| Official/API submission | pass | pass |

Interpretation:

- The portable model-backed source is useful on Martian as a candidate generator: it increases standalone hits from 24 to 36 and F1 from 0.294 to 0.360.
- Raw portable publication is too noisy for product defaults: Martian precision drops from 0.923 to 0.571.
- The existing Martian qualified publisher can absorb the portable source and improve over the previous qualified checkpoint: 62 hits / 22 noise / 0.561 F1.
- The trust/default guard is effectively flat but misses the strict exact F1 floor by 0.0004 because the target was rounded to 0.466.
- AACR transfer fails. The portable source finds only 7 of 467 scorer-only reference claims and publishes at 0.171 precision. This does not meet the target of 10 candidate-pool hits and 0.500 published precision.
- The most likely cause is missing repo context plus weak cross-benchmark claim matching. AACR first-50 had 0 materialized workspaces; Martian had 50.

Next research implication:

- Do not tune AACR-specific static patterns.
- The next variable should be benchmark-agnostic repo context for AACR, probably partial/sparse repository materialization or changed-file/callsite retrieval that avoids full huge-repo checkout.
- After AACR has comparable repo context, rerun the same portable reviewer before changing model, prompt, or publisher.

## 2026-05-31: PCRS v5 AACR Sparse Repo Context Gate

Checkpoint:

```text
branch: codex/pcrs-v3-no-key-gauntlet
status: negative transfer result with successful sparse-context infrastructure
official benchmark score: not claimed
Martian API key used: no
AACR API key used: no
model boundary: unchanged Codex CLI command reviewer
```

What changed:

- Added `sugary repo sparse-context`.
- Added `Sugary.SparseRepoContext` to build benchmark-agnostic sparse base/head workspaces from public GitHub commit SHAs.
- Added reviewer-visible context files for changed files, selected related files, and cheap identifier context.
- Kept oracle comments, expected claims, known non-issues, scorer labels, benchmark case IDs, and source PR URLs out of reviewer-visible workspaces.
- Reused the existing `pcrs-v4-portable-codex-repo-low` reviewer, model, prompt, and publisher.

Commands:

```sh
mix run -e 'IO.puts(Sugary.SparseRepoContext.run!(%{"suite" => "aacr-bench", "limit" => 50, "id" => "pcrs-v5-aacr-sparse-context-first50"}))'

mix run -e 'IO.puts(Sugary.PortableTransferGate.run!(%{"id" => "pcrs-v5-aacr-sparse-transfer-first50", "suites" => "martian-offline,aacr-bench", "limit" => 50, "replay-mode" => "cache-first", "martian-run" => ".sugary/research/runs/20260531T153346Z-pcrs-v4-portable-transfer-first50-martian-offline"}))'
```

Run artifacts:

```text
.sugary/research/sparse-repo-context/20260531T174225Z-pcrs-v5-aacr-sparse-context-first50
.sugary/research/sparse-repo-context/20260531T183359Z-pcrs-v5-aacr-sparse-context-first50-sanitized
.sugary/research/transfer-gates/20260531T174709Z-pcrs-v5-aacr-sparse-transfer-first50
.sugary/research/runs/20260531T174710Z-pcrs-v5-aacr-sparse-transfer-first50-aacr-bench
.sugary/research/pcrs-ensemble-publisher/20260531T182940Z-pcrs-v5-aacr-sparse-transfer-first50-martian-publisher
```

The transfer score below was measured on the first sparse-context artifact. After scoring, the sparse workspace manifests were hardened and regenerated in the sanitized artifact above so future reviewer-visible workspaces also omit benchmark case IDs and PR URLs. This hardening does not change the reported score.

Sparse context readiness:

| Metric | Result |
| --- | ---: |
| AACR cases | 50 |
| Sparse workspaces ready | 50 |
| Failed cases | 0 |
| Changed files written | 457 |
| Related files written | 12 |
| Grep/identifier context files | 48 |

Transfer result:

| Suite | Method | Workspace Inputs | Expected | Pool Hits | Pool Claims | Published Hits | Noise | Precision | Recall | F1 | Comments |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| Martian | `pcrs-v4-portable-codex-repo-low` | 50 / 50 | 137 | 36 | 63 | 36 | 27 | 0.571 | 0.263 | 0.360 | 63 |
| AACR | `pcrs-v4-portable-codex-repo-low` with sparse context | 50 / 50 | 467 | 8 | 44 | 8 | 39 | 0.182 | 0.017 | 0.031 | 44 |

Martian publisher guardrail:

| Policy | Hits | Noise | Precision | Recall | F1 | Comments | Gate |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| `posterior-max1-plus-source5-qualified-triad-budget52` | 44 | 8 | 0.846 | 0.321 | 0.466 | 52 | miss exact configured trust/default gate |
| `qualified-f1-judge-risk-budget84-max3` | 62 | 22 | 0.738 | 0.453 | 0.561 | 84 | pass |

Interpretation:

- Sparse context successfully made AACR reviewer inputs repo-aware: 50 / 50 workspace inputs versus 0 / 50 in the prior portable AACR run.
- That did not materially improve transfer. AACR F1 moved only from 0.028 to 0.031, pool hits moved from 7 to 8, and precision moved from 0.171 to 0.182.
- The run misses the v5 stretch target: pool hits >= 20, precision >= 0.300, and a material F1 lift over 0.028.
- Martian qualified guardrail did not regress below the local floor: F1 0.561, precision 0.738.
- The best current explanation is that simple changed-file sparse context is not enough. The bottleneck is now candidate generation quality, evidence construction, or cross-benchmark claim matching.

Next research implication:

- Do not spend another loop on context plumbing alone.
- Test a single higher-leverage variable next: repo search/tool use inside the reviewer, proof-specific refutation, or a calibrated publisher trained to reject AACR-style noise.
- Keep AACR-specific static patterns out of the system.

## 2026-06-01: PCRS v6 AACR Claim-Space + Evidence-Pack Gate

Checkpoint:

```text
branch: codex/pcrs-v3-no-key-gauntlet
status: guarded negative result
official benchmark score: not claimed
Martian API key used: no
AACR API key used: no
model boundary: Codex CLI command reviewer through Sugary protocol
```

What changed:

- Added explicit score-accounting reconciliation so precision denominators, matched comments, noisy/trap comments, duplicate-hit events, and hit/trap overlaps are reported separately.
- Added benchmark/reviewer category synonym normalization for claim matching.
- Added benchmark-agnostic evidence packs from changed hunks, sparse base/head snippets, and cheap related-file context.
- Added a v6 AACR gate that compares defect-focused, broad-actionable, and evidence-pack Codex reviewer variants.
- Expanded the v6 report with generated-claim distributions, unmatched/missed summaries, near-match risk, context-use citations, adapter modes, and reviewer errors.

Commands:

```sh
mix run -e 'IO.puts(Sugary.AACRV6Gate.run!(%{"id" => "pcrs-v6-aacr-claim-space-evidence-pack-first50-final", "limit" => 50, "replay-mode" => "cache-first", "ensure-sparse-context" => "true"}))'
```

Run artifacts:

```text
.sugary/research/aacr-v6-gates/20260601T050703Z-pcrs-v6-aacr-claim-space-evidence-pack-first50-final
.sugary/research/runs/20260601T051057Z-pcrs-v6-aacr-claim-space-evidence-pack-first50-final-aacr-bench
.sugary/research/transfer-gates/20260601T051107Z-pcrs-v6-aacr-claim-space-evidence-pack-first50-final-martian-guardrail
```

Note: an earlier v6 run failed because the Codex structured-output schema added `evidence_pack_sections_cited` to `properties` but not to `required`. That run produced no useful reviewer claims and is not used for the result below.

AACR first-50 claim space:

| Claim Type | Expected Claims |
| --- | ---: |
| maintainability | 205 |
| defect | 150 |
| performance | 51 |
| contract | 25 |
| security | 15 |
| runtime | 13 |
| test_gap | 8 |

Final result:

| Method | Hits | Precision | Recall | F1 | Comments | Noise Events | Evidence Citations |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `pcrs-v4-portable-codex-repo-low` | 15 | 0.313 | 0.032 | 0.058 | 48 | 35 | 0 |
| `pcrs-v6-broad-actionable-codex-low` | 14 | 0.233 | 0.030 | 0.053 | 60 | 47 | 0 |
| `pcrs-v6-evidence-pack-codex-low` | 14 | 0.233 | 0.030 | 0.053 | 60 | 48 | 160 |

Martian guardrail:

| Metric | Result |
| --- | ---: |
| Qualified F1 | 0.561 |
| Qualified precision | 0.738 |
| Guardrail | pass |

Decision:

```text
reject_aacr_claim_generation_transfer
```

Interpretation:

- The accounting and matcher audit matters: the existing portable reviewer moved from the prior sparse-context result of 8 hits / 0.182 precision / 0.031 F1 to 15 hits / 0.313 precision / 0.058 F1.
- The v6 candidate-generation target was still missed because candidate-pool hits remained 15 against a target of 20.
- Broad actionable review and evidence-pack review both produced more comments but worse precision than the simpler portable reviewer.
- Evidence-pack review cited 160 evidence sections, so the model consumed the evidence-pack context, but citation/use alone did not create transfer lift.
- The largest uncovered mass is maintainability and performance/reference-comment style findings; the current defect-oriented objective is not searching that claim space effectively.

Next research implication:

- Do not treat more context as a default win.
- The next loop should test a different generation/search procedure with a locked target, not another context wrapper.
- The promising variable is multi-pass claim-type targeting over the public benchmark claim-space distribution, while keeping oracle labels and AACR-specific static patterns out of reviewer prompts.

## 2026-06-06: h5i-Compatible Agent Bus Martian Gate

```text
branch: codex/pcrs-v3-no-key-gauntlet
status: transport validated, no review-quality lift
official benchmark score: not claimed
Martian API key used: no
h5i installed: no
effective agent-bus backend: local-jsonl
```

What changed:

- Added an append-only `Sugary.AgentBus` with local JSONL as source of truth.
- Added optional h5i mirroring for `REVIEW_REQUEST` messages when `h5i` is installed.
- Added a Martian-only orchestration gate that emits blind review/refute/publish messages around the existing Sugary experiment runner.
- Added agent-bus leakage checks so messages do not expose benchmark oracle data or original case IDs.

Command:

```sh
./sugary orchestrator martian gate --limit 3 --replay-mode cache-first --agent-bus auto
```

Run artifacts:

```text
.sugary/research/orchestrator-gates/20260606T162510Z-martian-orchestrator-h5i-v0
```

Result:

| Method | Recall | Usefulness | SNR | F1 | Avg Comments | Published | Noise |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `baseline-diff-only` | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0 | 0 |
| `public-static-proof-gate` | 0.444 | 0.800 | 4.000 | 0.571 | 1.667 | 5 | 1 |
| `orchestrated-public-pcrs-static-codex-low-team` | 0.444 | 0.444 | 0.800 | 0.444 | 3.000 | 9 | 5 |

Agent bus:

| Metric | Result |
| --- | ---: |
| Messages | 23 |
| h5i events | 0 |
| Reviewer input leakage fatal | false |
| Agent-bus leakage fatal | false |

Decision:

```text
transport_validated_no_quality_lift
```

Interpretation:

- The h5i-shaped orchestration substrate works without requiring h5i as a dependency.
- Because h5i was not installed, this run used the local JSONL backend and does not test live h5i behavior.
- The current team did not beat the best single static proof reviewer on this Martian smoke: same recall, lower usefulness, lower SNR, and more comments.
- This is not evidence against persistent subagents yet. It is evidence that routing messages alone does not improve quality when reviewer prompts/tools are unchanged.

Next research implication:

- Keep the agent bus as a measurement substrate, not as a product dependency.
- The next h5i/persistent-agent test must change exactly one variable: persistent memory or cross-agent handoff influencing candidate generation.
- Do not promote a persistent subagent architecture unless it beats the best single reviewer on Martian smoke without SNR/comment-count regression.

## 2026-06-06: h5i Install and Live Mirror Verification

```text
branch: codex/pcrs-v3-no-key-gauntlet
h5i version: 0.1.6
install path: /Users/eric/.local/bin/h5i
repo initialized: yes
h5i refs pushed: no
status: live mirror works after sender-identity fix
```

What happened:

- Installed h5i v0.1.6 into `~/.local/bin`.
- Ran `h5i init`, which initialized `.git/.h5i` and created local instruction files.
- The first live h5i Martian gate exposed an adapter bug: `h5i msg review` rejected messages without a sender identity.
- Patched Sugary’s h5i mirror to pass `--from sugary-orchestrator` and capture h5i stderr/stdout into event artifacts.
- Reran a 1-case Martian gate with `--agent-bus h5i`.

Command:

```sh
./sugary orchestrator martian gate --limit 1 --replay-mode cache-first --agent-bus h5i
```

Run artifacts:

```text
.sugary/research/orchestrator-gates/20260606T163756Z-martian-orchestrator-h5i-v0
```

Result:

| Method | Recall | Usefulness | SNR | F1 | Avg Comments | Published | Noise |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `baseline-diff-only` | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0 | 0 |
| `public-static-proof-gate` | 0.667 | 1.000 | 2.000 | 0.800 | 2.000 | 2 | 0 |
| `orchestrated-public-pcrs-static-codex-low-team` | 0.667 | 0.667 | 2.000 | 0.667 | 3.000 | 3 | 1 |

Agent bus:

| Metric | Result |
| --- | ---: |
| Messages | 9 |
| h5i mirror events | 2 |
| h5i mirror failures | 0 |
| Reviewer input leakage fatal | false |
| Agent-bus leakage fatal | false |

h5i message history:

```text
sugary-orchestrator -> static-proof-sentinel REVIEW_REQUEST
sugary-orchestrator -> codex-review-sentinel REVIEW_REQUEST
```

Decision:

```text
transport_validated_no_quality_lift
```

Interpretation:

- h5i now works as a live optional message backend for Sugary orchestration.
- The review-quality result is still negative for the current team: best single static proof reviewer beats the orchestrated team.
- h5i should remain a transport/memory experiment until persistent memory or handoff changes produce measurable Martian lift without SNR/comment-count regression.

## 2026-06-06: h5i Repo Integration Finalization

```text
branch: codex/pcrs-v3-no-key-gauntlet
status: repo integration complete, h5i refs still local-only
h5i version: 0.1.6
context branch: codex/pcrs-v3-no-key-gauntlet
context commits: 1
live claims: 1
h5i refs pushed: no
```

What changed:

- Replaced generated h5i agent instructions with concise Sugary-specific instructions in `AGENTS.md`.
- Kept `CLAUDE.md` as a thin import of `.claude/h5i.md`.
- Initialized the h5i context workspace with the Sugary project goal.
- Recorded one live claim about the h5i backend.
- Added local `remote.origin.fetch` refspecs for `refs/h5i/*` with `h5i share setup-remote`.
- Verified `h5i codex prelude` restores context and live claims.
- Reran the h5i-backed Martian gate after setup.

Verification:

```sh
h5i context init --goal "Build Sugary into a benchmark-driven proof-carrying AI code review system."
h5i capture claim "Sugary h5i backend mirrors REVIEW_REQUEST via h5i msg review; local JSONL remains source of truth." --path lib/sugary/agent_bus.ex
h5i context commit "Initialize Sugary h5i integration" --detail "Installed h5i, initialized context workspace, verified h5i message backend, and added concise repo agent instructions."
h5i share setup-remote
h5i codex prelude
./sugary orchestrator martian gate --limit 1 --replay-mode cache-first --agent-bus h5i
```

Latest gate artifacts:

```text
.sugary/research/orchestrator-gates/20260606T165043Z-martian-orchestrator-h5i-v0
```

Latest h5i-backed gate result:

| Method | Recall | Usefulness | SNR | F1 | Avg Comments | Published | Noise |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `baseline-diff-only` | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0 | 0 |
| `public-static-proof-gate` | 0.667 | 1.000 | 2.000 | 0.800 | 2.000 | 2 | 0 |
| `orchestrated-public-pcrs-static-codex-low-team` | 0.667 | 0.667 | 2.000 | 0.667 | 3.000 | 3 | 1 |

Interpretation:

- h5i is now set up enough for persistent context and live cross-agent messages in this clone.
- h5i refs remain local because publishing `refs/h5i/*` should be a deliberate public-project decision.
- The next controlled experiment should test h5i memory as the single changed variable, not transport alone.

## 2026-06-06: h5i Persistent Memory Gauntlet v0

```text
branch: codex/pcrs-v3-no-key-gauntlet
status: controlled negative result
h5i version: 0.1.6
h5i refs pushed: no
official benchmark score: not claimed
```

Question:

```text
Does h5i-backed persistent specialist memory improve Martian review quality
over the same stateless candidate pool?
```

What changed:

- Added `./sugary h5i memory gauntlet`.
- Added a train/eval Martian memory loop.
- Added `stateless-normalized-team` so memory and no-memory variants publish from the same candidate pool and comment budget.
- Added `shuffled-memory-control-team` as a negative control.
- Added memory leakage checks for eval source case IDs and oracle markers.
- Mirrored the memory lesson summary into h5i context.

Command:

```sh
./sugary h5i memory gauntlet \
  --train-limit 3 \
  --eval-limit 3 \
  --train-offset 0 \
  --eval-offset 3 \
  --replay-mode cache-first \
  --h5i true
```

Run artifacts:

```text
.sugary/research/persistent-memory-gauntlets/20260606T170634Z-h5i-persistent-memory-gauntlet-v0
```

Result:

| Method | Recall | Usefulness | SNR | F1 | Avg Comments | Published | Noise |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `stateless-team` | 0.300 | 1.000 | 3.000 | 0.462 | 1.000 | 3 | 0 |
| `stateless-normalized-team` | 0.300 | 1.000 | 3.000 | 0.462 | 1.000 | 3 | 0 |
| `h5i-persistent-memory-team` | 0.200 | 1.000 | 2.000 | 0.333 | 0.667 | 2 | 0 |
| `shuffled-memory-control-team` | 0.300 | 1.000 | 3.000 | 0.462 | 1.000 | 3 | 0 |
| `public-static-proof-gate` | 0.200 | 1.000 | 2.000 | 0.333 | 0.667 | 2 | 0 |
| `baseline-diff-only` | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0 | 0 |

Memory:

| Metric | Result |
| --- | ---: |
| Positive lessons | 5 |
| Negative lessons | 4 |
| Memory unique hits over stateless-normalized | 0 |
| Added noise over stateless-normalized | 0 |
| Fatal leakage | false |

Decision:

```text
invalidate_h5i_memory_lift
```

Interpretation:

- h5i-backed memory persistence and message routing worked.
- The first ranking/refutation memory policy hurt recall by suppressing one useful published claim.
- The shuffled-memory control matched stateless-normalized, so the memory policy did not show robust lift.
- This invalidates the current memory-as-refuter/ranker policy on this Martian subset, not the broader persistent-subagent thesis.

Next research implication:

- Do not use train-derived negative memory as a hard suppression rule.
- The next test should separate memory-assisted candidate generation from memory-assisted refutation.
- A better h5i memory policy should retrieve positive repo conventions and prior missed categories, then require proof construction before changing publish decisions.

## 2026-06-06: Repo/History Tool Gauntlet v1

```text
branch: codex/pcrs-v3-no-key-gauntlet
status: controlled negative result
suite: Martian offline local smoke, cases 1-10
official benchmark score: not claimed
model calls: none
```

Question:

```text
Do read-only full-repo and git-history evidence tools improve publishing
when applied to a fixed public-static-proof-gate Martian claim pool?
```

What changed:

- Added `Sugary.RepoTools` with structured evidence for:
  - `read_changed_file`
  - `repo_grep`
  - `git_history`
  - `git_grep_history`
- Added repo/history tool support to the existing replay-based tool gauntlet.
- Added `--materialize true` to `./sugary tool gauntlet`.
- Added a reproducible 10-case Martian source manifest.
- Added CI-safe tests using a local bare git repo.

Commands:

```sh
mix escript.build

./sugary experiment run experiments/tool-repo-history-martian-smoke-v0.toml

./sugary tool gauntlet \
  --source-run .sugary/research/runs/20260606T173620Z-tool-repo-history-martian-smoke-v0 \
  --method public-static-proof-gate \
  --baseline baseline-diff-only \
  --suite martian-offline \
  --limit 10 \
  --offset 0 \
  --tools read_changed_file,repo_grep,git_history,git_grep_history \
  --materialize true \
  --max-published 2 \
  --min-score 2.0 \
  --id repo-history-tool-gauntlet-v1-martian-smoke-10
```

Run artifacts:

```text
.sugary/research/runs/20260606T173620Z-tool-repo-history-martian-smoke-v0
.sugary/research/tool-gauntlets/20260606T173722Z-repo-history-tool-gauntlet-v1-martian-smoke-10
.sugary/research/repo-materializations/20260606T173700Z-repo-history-tool-gauntlet-v1-martian-smoke-10-repo-materialization
```

Materialization:

| Metric | Result |
| --- | ---: |
| Cases | 10 |
| Workspace ready | 10 |
| Git metadata resolved | 10 |
| Exact diff parity | 10 |
| Tool-ready cases | 10 |
| Failed | 0 |

Tool evidence availability:

| Tool | Support | Counterargument | Unavailable |
| --- | ---: | ---: | ---: |
| `read_changed_file` | 7 | 0 | 0 |
| `repo_grep` | 3 | 4 | 0 |
| `git_history` | 7 | 0 | 0 |
| `git_grep_history` | 1 | 6 | 0 |

Result:

| Variant | F1 | Usefulness | SNR | Hits | Noise | Avg comments/PR |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| Source method: `public-static-proof-gate` | 0.343 | 0.857 | 6.000 | 6 | 1 | 0.700 |
| Raw baseline: `baseline-diff-only` | 0.000 | 0.000 | 0.000 | 0 | 0 | 0.000 |
| Control no-tool ranker | 0.343 | 0.857 | 6.000 | 6 | 1 | 0.700 |
| `read_changed_file` | 0.343 | 0.857 | 6.000 | 6 | 1 | 0.700 |
| `repo_grep` | 0.343 | 0.857 | 6.000 | 6 | 1 | 0.700 |
| `git_history` | 0.343 | 0.857 | 6.000 | 6 | 1 | 0.700 |
| `git_grep_history` | 0.343 | 0.857 | 6.000 | 6 | 1 | 0.700 |

Decision:

```text
Kept capabilities: none
```

Interpretation:

- The repo and history tools are now real on this slice: all 10 cases had materialized workspaces, exact diff parity, and local git cache access.
- The tools produced structured citations, so the implementation is usable for future agent/tool experiments.
- No tool improved F1, usefulness, SNR, hits, noise, or comment count in replay mode.
- This does not invalidate repo tools. It invalidates using these naive post-hoc evidence bonuses as a publisher improvement over this fixed static candidate pool.
- The likely bottleneck is candidate generation: the fixed pool had only 7 published/static claims, so tools could not discover missing issues.

Next research implication:

- Treat repo grep/history as candidate-generation and refutation tools, not just replay-time score boosts.
- The next live/tool loop should let an agent ask a small number of repo/history questions before proposing claims.
- Do not add bash/test execution until repo/history tool use has a live, locked comparison against a no-tool agent.

## 2026-06-06: Fixed Repo-Tools Packet Live Codex Smoke v0

```text
branch: codex/pcrs-v3-no-key-gauntlet
status: controlled negative result
suite: Martian offline local smoke, cases 1-3
official benchmark score: not claimed
model: Codex CLI, gpt-5.5 low
```

Question:

```text
Does giving the same Codex diff-only reviewer a bounded repo/history evidence
packet improve candidate generation over no repo-tools packet?
```

What changed:

- Added `Sugary.RepoToolPack`.
- Added `include_repo_tools = true` as an explicit reviewer/method flag.
- Updated `codex_exec_reviewer.exs` to mention `metadata.repo_tools` when present.
- Added the A/B manifest `experiments/codex-repo-tools-packet-martian-smoke-v0.toml`.

Tool-safety correction:

- First live attempt stalled before the repo-tools arm wrote its first input bundle.
- Cause: the packet builder used unbounded repo/history commands; `rg --max-count` capped matches per file, not total matches.
- Fix: added hard command timeouts and a total match cap per identifier.
- Direct packet build after the fix completed in about 5 seconds on the first Martian case and produced a bounded packet around 21 KB.

Commands:

```sh
./sugary repo materialize \
  --suite martian-offline \
  --limit 3 \
  --offset 0 \
  --mode fetch \
  --id codex-repo-tools-packet-smoke-materialization

./sugary experiment run experiments/codex-repo-tools-packet-martian-smoke-v0.toml
```

Run artifacts:

```text
.sugary/research/repo-materializations/20260606T190325Z-codex-repo-tools-packet-smoke-materialization
.sugary/research/runs/20260606T191616Z-codex-repo-tools-packet-martian-smoke-v0
```

Result:

| Method | F1 | Recall | Precision | Usefulness | SNR | Hits | Noise | Published | Latency ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `codex-gpt-5.5-low-no-tools` | 0.500 | 0.444 | 0.571 | 0.571 | 1.333 | 4 | 3 | 7 | 69,901 |
| `codex-gpt-5.5-low-repo-tools` | 0.286 | 0.222 | 0.400 | 0.400 | 0.667 | 2 | 3 | 5 | 59,037 |

Packet availability:

| Case | Changed file reads | Repo grep matches | Git history entries | Git grep history entries |
| --- | ---: | ---: | ---: | ---: |
| Martian 1 | 3 | 60 | 9 | 6 |
| Martian 2 | 12 | 60 | 12 | 6 |
| Martian 3 | 12 | 60 | 15 | 8 |

Decision:

```text
Do not promote fixed repo-tools packets for the reviewer path.
```

Interpretation:

- The fixed packet provided real repository context, but it hurt candidate selection on this smoke slice.
- It reduced comments from 7 to 5, but dropped hits from 4 to 2 and did not reduce noise.
- This suggests the packet adds distracting context unless the reviewer has a stronger policy for when to use or ignore tool evidence.
- The negative result is stronger than the previous replay-only result because the model saw the packet before generating claims.

Next research implication:

- Repo/history tools should not be dumped into the prompt as passive context.
- The next tooling test should be interactive or staged: generate a hypothesis, ask one targeted repo/history question, then prove/refute that specific hypothesis.
- Every tool must have hard resource budgets before it enters a long-running loop.

## 2026-06-06: Bounded Codex Tool-Loop Smoke v0

```text
branch: codex/pcrs-v3-no-key-gauntlet
status: controlled negative result
suite: Martian offline local smoke, cases 1-3
official benchmark score: not claimed
model: Codex CLI, gpt-5.5 low
```

Question:

```text
If Codex can request bounded repository tools during review, does it use them
when useful, and does that improve review outcomes versus the same no-tool
reviewer?
```

What changed:

- Added `scripts/reviewers/codex_tool_loop_reviewer.exs`.
- The wrapper exposes bounded `changed_files`, `repo_grep`, and `read_file` tools.
- The model does not receive target workspace paths. It sees sanitized PR input and tool observations only.
- Added fake-mode tests for the wrapper contract and bounded file-read path.
- Added `experiments/codex-tool-loop-martian-smoke-v0.toml`.
- Added compact preservation of self-reported command-reviewer artifacts so tool-loop transcripts survive redaction.

Important correction:

- The first live attempt was invalid because the structured-output schema for tool `args` was too loose and Codex exited before any tool call.
- The schema now has fixed nullable args fields: `query`, `path`, `start_line`, and `end_line`.
- The corrected optional-tool run showed zero tool calls. Codex chose to finalize from the diff on all three cases.
- A third arm required at least one repository tool observation before publishing non-empty claims.

Commands:

```sh
./sugary repo materialize \
  --suite martian-offline \
  --limit 3 \
  --offset 0 \
  --mode fetch \
  --id codex-tool-loop-smoke-materialization

./sugary experiment run \
  experiments/codex-tool-loop-martian-smoke-v0.toml \
  --replay-mode refresh

./sugary experiment run \
  experiments/codex-tool-loop-martian-smoke-v0.toml \
  --replay-mode cache-first
```

Run artifacts:

```text
.sugary/research/repo-materializations/20260606T220544Z-codex-tool-loop-smoke-materialization
.sugary/research/runs/20260606T220825Z-codex-tool-loop-martian-smoke-v0
.sugary/research/runs/20260606T221237Z-codex-tool-loop-martian-smoke-v0
```

Result:

| Method | Tool policy | F1 | Recall | Precision | Usefulness | SNR | Hits | Noise | Published | Avg comments/PR |
| --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `codex-gpt-5.5-low-no-tools` | no repo tools | 0.250 | 0.222 | 0.286 | 0.286 | 0.400 | 2 | 5 | 7 | 2.333 |
| `codex-gpt-5.5-low-tool-loop` | optional tools | 0.133 | 0.111 | 0.167 | 0.167 | 0.200 | 1 | 5 | 6 | 2.000 |
| `codex-gpt-5.5-low-tool-loop-required` | tool evidence required before claims | 0.154 | 0.111 | 0.250 | 0.250 | 0.333 | 1 | 3 | 4 | 1.333 |

Tool-use observations:

| Method | Observed behavior |
| --- | --- |
| `codex-gpt-5.5-low-tool-loop` | Used zero tools on all three cases; rationale said the diff was sufficient. |
| `codex-gpt-5.5-low-tool-loop-required` | Used repo tools on all three cases, mainly `read_file`; one first-turn `read_file` had a null path and failed before the model recovered with a valid file read. |

Decision:

```text
Do not promote the current bounded tool-loop reviewer.
Keep the wrapper and artifact plumbing as experimental infrastructure.
```

Interpretation:

- Merely exposing repo tools does not make the model use them.
- Requiring tool evidence reduced comments and noise relative to optional tool-loop, but did not recover recall and still trailed the no-tool baseline.
- The current tool policy is too weak: the model needs a staged hypothesis → targeted tool query → refutation/finalization protocol, not just free-form optional tools.
- The result supports a bitter-pilled direction, but not this implementation: tools should be part of candidate generation and proof/refutation, with measurable promotion gates.

Next research implication:

- Test a staged reviewer that first generates candidate hypotheses, then forces one targeted repo read/grep per hypothesis, then runs a separate refuter before publishing.
- Add tool-quality metrics: invalid tool calls, useful tool calls, claims with cited tool observations, and claims contradicted by tool observations.
- Do not add bash/test execution until simple read/grep tools show a positive lift under a staged protocol.

## 2026-06-07: Claude-Style Staged Codex Review Smoke v0

```text
branch: codex/pcrs-v3-no-key-gauntlet
status: mixed/negative result
suite: Martian offline local smoke, cases 1-3
official benchmark score: not claimed
model: Codex CLI, gpt-5.5 low
```

Question:

```text
Does a Claude-Code-style staged architecture improve review quality:
specialist candidate agents -> independent repo-evidence validators -> dedupe/rank/publish?
```

Why this was tested:

- Claude Code Review publicly describes a staged shape: multiple specialist reviewers, validation, dedupe, severity ranking, and repo-specific policy.
- Our previous bounded tool-loop showed that merely exposing tools is not enough: the model often chose not to use them.
- This experiment moves repo tools into a validation stage instead of relying on optional free-form tool calls.

What changed:

- Added `scripts/reviewers/codex_staged_review_reviewer.exs`.
- Added three specialist candidate roles:
  - `diff-bug`
  - `changed-code-security`
  - `contract-regression`
- Added bounded validation evidence per candidate:
  - `changed_files`
  - `read_file`
  - optional `repo_grep`
- Added independent validator calls that return `validated | rejected | uncertain`.
- Added validated-claim dedupe before final publishing.
- Added `experiments/codex-staged-review-martian-smoke-v0.toml`.
- Added fake-mode wrapper tests.

Important correction:

- First staged run was invalid: the wrapper crashed with `KeyError :reasoning_effort` before candidate generation.
- Fixed the config propagation and reran with `--replay-mode refresh`.
- Rebuilt the escript before the final post-dedupe run so command-reviewer artifacts preserve compact self-reported staged artifacts.

Commands:

```sh
./sugary experiment run \
  experiments/codex-staged-review-martian-smoke-v0.toml \
  --replay-mode refresh
```

Run artifacts:

```text
.sugary/research/runs/20260607T152305Z-codex-staged-review-martian-smoke-v0
.sugary/research/runs/20260607T153222Z-codex-staged-review-martian-smoke-v0
```

Pre-dedupe corrected run:

| Method | F1 | Recall | Precision | Usefulness | SNR | Hits | Noise | Published | Latency ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `codex-gpt-5.5-low-no-tools` | 0.308 | 0.222 | 0.500 | 0.500 | 1.000 | 2 | 2 | 4 | 75,882 |
| `codex-gpt-5.5-low-tool-loop-required` | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0 | 4 | 4 | 64,834 |
| `codex-gpt-5.5-low-staged-validated` | 0.333 | 0.333 | 0.333 | 0.333 | 0.500 | 3 | 6 | 9 | 314,581 |

Final post-dedupe run:

| Method | F1 | Recall | Precision | Usefulness | SNR | Hits | Noise | Published | Latency ms |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| `codex-gpt-5.5-low-no-tools` | 0.267 | 0.222 | 0.333 | 0.333 | 0.500 | 2 | 4 | 6 | 61,750 |
| `codex-gpt-5.5-low-tool-loop-required` | 0.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0 | 4 | 4 | 74,365 |
| `codex-gpt-5.5-low-staged-validated` | 0.222 | 0.222 | 0.222 | 0.222 | 0.286 | 2 | 7 | 9 | 329,178 |

Observed staged behavior:

| Case | Candidates | Validations | Validated | Published |
| --- | ---: | ---: | ---: | ---: |
| Martian 1 | 6 | 4 | 3 | 3 |
| Martian 2 | 6 | 4 | 3 | 3 |
| Martian 3 | 6 | 4 | 3 | 3 |

Decision:

```text
Do not promote staged review v0.
Keep staged candidate generation and validator artifacts as experimental infrastructure.
```

Interpretation:

- Staged candidate generation increased breadth: it found additional plausible true positives in the pre-dedupe run.
- The validator was too permissive. It validated many plausible claims that did not match benchmark defects, so precision/usefulness dropped.
- Dedupe v0 was not strong enough; final published comments still hit the max comment budget on every case.
- Latency is material: roughly 5.5 minutes for 3 cases versus about 1 minute for the no-tool baseline.
- The staged architecture is directionally aligned with PCRS/Claude-style review, but our publisher/refuter is the current bottleneck.

Next research implication:

- Do not add more candidate agents yet.
- Add a stricter proof/refutation gate after validation:
  - reject duplicate same-root-cause claims
  - require explicit introduced-by-PR proof
  - require expected-failure evidence, not just plausible evidence
  - cap publication by value, not just count
- Add validator calibration metrics:
  - validator false-accept rate
  - duplicate validated claims
  - validated-but-unmatched claims
  - validation latency per accepted claim
- Consider parallel candidate/validator execution only after the quality gate improves; parallelism solves latency, not noise.

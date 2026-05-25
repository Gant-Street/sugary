# sugary

Open, BYOK code review.

See [docs/vision.md](docs/vision.md) for the product vision, system design, and initial implementation plan.

See [docs/pcrs.md](docs/pcrs.md) for the Proof-Carrying Review Search thesis.

See [docs/autoresearch-loop.md](docs/autoresearch-loop.md) for the `/goal`-ready autoresearch implementation plan.

See [docs/command-reviewer-adapter.md](docs/command-reviewer-adapter.md) for the external command reviewer contract.

See [docs/review-teams.md](docs/review-teams.md) for Review Team manifests, merge behavior, and contribution scorecards.

See [docs/complementarity.md](docs/complementarity.md) for reviewer packs, team search, and promotion policy.

See [docs/hard-fixtures.md](docs/hard-fixtures.md) for split-aware hard fixtures, blind holdout mode, saturation diagnostics, and anti-overfitting checks.

See [docs/promotion-workflow.md](docs/promotion-workflow.md) for locked dev-to-holdout promotion, leakage checks, holdout ledger, bootstrap intervals, and generalization reports.

See [docs/external-real-reviewers.md](docs/external-real-reviewers.md) and [docs/replay-cache.md](docs/replay-cache.md) for opt-in external reviewer wrappers, replay modes, and unofficial smoke comparisons.

See [docs/public-benchmark-bridge.md](docs/public-benchmark-bridge.md), [docs/martian-offline-smoke.md](docs/martian-offline-smoke.md), and [docs/cr-bench-smoke.md](docs/cr-bench-smoke.md) for local-only public benchmark smoke adapters and unofficial transfer reports.

See [docs/research-scorecard.md](docs/research-scorecard.md) for the reporting-only research utility scorecard and next-ablation recommendation layer.

See [docs/evidence-refutation-ablation.md](docs/evidence-refutation-ablation.md) for the first narrow PCRS mechanism test.

## Autoresearch Lab

Sugary currently starts as an Elixir-first local research harness for proof-carrying code review experiments.

```sh
mix test
mix escript.build
./sugary research init
./sugary bench list
./sugary bench run --suite local-fixtures --method golden-perfect-reviewer
./sugary experiment run experiments/pcrs-first-ablation.toml
./sugary experiment run experiments/pcrs-agent-pr-first-proof.toml
./sugary experiment run experiments/sample-command-reviewer.toml
./sugary experiment run experiments/review-team-v0.toml
./sugary team search --pack reviewer-packs/baseline-pack-v0.toml --suite agent-written-fixtures --max-team-size 3
./sugary experiment run experiments/pcrs-hard-fixtures-v0.toml
./sugary bench run --suite agent-written-hard-fixtures --split holdout --method baseline-diff-only
./sugary team search --pack reviewer-packs/baseline-pack-v0.toml --suite agent-written-hard-fixtures --split holdout --max-team-size 3
./sugary promotion lock --candidate teams/hard-specialist-team.toml --baseline-method baseline-diff-only --baseline-method symbol-graph-reflexion --baseline-team teams/proof-carrying-team.toml --suite agent-written-hard-fixtures --dev-run .sugary/research/runs/<dev-run-id> --out promotions/hard-specialist-v0.toml
./sugary promotion run promotions/hard-specialist-v0.toml --split holdout
./sugary reviewers check --pack reviewer-packs/external-real-pack-v0.toml
./sugary experiment run experiments/external-real-pack-local-smoke.toml --replay-mode cache-first
./sugary experiment run experiments/external-real-pack-hard-holdout.toml --replay-mode cache-first
./sugary bench public list
./sugary experiment run experiments/public-martian-smoke-v0.toml --replay-mode cache-first
./sugary experiment run experiments/public-cr-bench-smoke-v0.toml --replay-mode cache-first
./sugary experiment run experiments/evidence-refutation-ablation-v0.toml
./sugary bench compare --run .sugary/research/runs/<local-run> --run .sugary/research/public-smoke/<public-run>
```

Every experiment writes `research-scorecard.json` and `research-scorecard.md` under its run directory. Use those artifacts to choose the next small ablation before adding new model providers or product surfaces.

Public benchmark smoke runs are local-only and unofficial. Set `MARTIAN_BENCH_DIR` or `CR_BENCH_DIR`, or place datasets at `.sugary/research/benchmarks/martian-offline` and `.sugary/research/benchmarks/cr-bench`, then run:

```sh
./sugary bench fetch martian-offline --local-only
./sugary bench run --suite martian-offline --method a-diff-only-single-shot --limit 3 --local-only
./sugary bench fetch cr-bench --local-only
./sugary bench run --suite cr-bench --method a-diff-only-single-shot --limit 3 --local-only
```

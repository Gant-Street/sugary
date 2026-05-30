# Martian Offline Parity

Sugary's public benchmark bridge is intentionally unofficial. The parity export is the next local step: it makes a Sugary run look like a tool inside Martian's official offline artifact layout, without submitting anything or making leaderboard claims.

## What It Does

The export command:

- reads fixed Sugary claim artifacts from an existing run
- optionally applies a budget ranking policy such as `team-ev-max-2`
- inserts one local Sugary review entry per Martian PR into `offline/results/benchmark_data.json`
- writes Martian-style `candidates.json`
- writes singleton `dedup_groups.json` as a no-LLM local fallback
- writes a parity report under `.sugary/research/martian-parity/`

The singleton dedup file is not Martian's official LLM dedup. It exists so the local judge command has a complete file shape before credentials are configured.

## Command

```sh
./sugary martian parity export \
  --source-run .sugary/research/runs/<run-id> \
  --method pcrs-codex-repo-low-strict \
  --tool sugary-pcrs-repo-budget-max2 \
  --policy team-ev-max-2 \
  --martian-dir .sugary/research/benchmarks/martian-offline/offline \
  --model-dir sugary_local_parity_v0 \
  --limit 50 \
  --offset 0
```

## Official Local Pipeline

After export, run these from the Martian `offline` directory when `MARTIAN_API_KEY` and `MARTIAN_MODEL` are configured:

```sh
uv run python -m code_review_benchmark.step2_extract_comments --tool sugary-pcrs-repo-budget-max2 --force
uv run python -m code_review_benchmark.step2_5_dedup_candidates --tool sugary-pcrs-repo-budget-max2 --force
uv run python -m code_review_benchmark.step3_judge_comments --tool sugary-pcrs-repo-budget-max2 --dedup-groups results/sugary_local_parity_v0/dedup_groups.json --force
uv run python analysis/benchmark_dashboard.py
```

If credentials are missing, Sugary should report that as a setup block, not as benchmark success or failure.

## Rules

- Do not submit benchmark results from this command.
- Do not call the output an official Martian score until the Martian judge has run locally.
- Do not tune on the judged output without a fresh lock and evaluation split.
- Keep Sugary's review comments as claims only; Martian remains the local scoring harness for this step.

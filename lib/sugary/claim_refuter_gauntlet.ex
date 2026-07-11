defmodule Sugary.ClaimRefuterGauntlet do
  alias Sugary.Protocol.ReviewClaim

  @root ".sugary/research/claim-refuter-gauntlets"
  @workspace_root ".sugary/research/refuter-workspaces"
  @default_policy "online-qualified-max2-t70"
  @default_base_policy "online-qualified-max1-t55"

  def run!(opts) when is_map(opts) do
    opts
    |> Enum.map(fn {key, value} ->
      {key |> to_string() |> String.replace("-", "_") |> String.to_atom(), value}
    end)
    |> run!()
  end

  def run!(opts) when is_list(opts) do
    source_run = Keyword.fetch!(opts, :source_run)
    materialization_run = Keyword.fetch!(opts, :materialization_run)
    suite = Keyword.get(opts, :suite, "martian-offline")
    limit = opts |> Keyword.get(:limit, 50) |> int()
    offset = opts |> Keyword.get(:offset, 0) |> int()
    policy_id = Keyword.get(opts, :policy, @default_policy)
    base_policy_id = Keyword.get(opts, :base_policy, @default_base_policy)
    claim_offset = opts |> Keyword.get(:claim_offset, 0) |> int()
    claim_limit = opts |> Keyword.get(:claim_limit, 10_000) |> int()
    concurrency = opts |> Keyword.get(:concurrency, 2) |> int()
    replay_mode = Keyword.get(opts, :replay_mode, "cache-first")
    model = Keyword.get(opts, :model, "gpt-5.5")
    reasoning_effort = Keyword.get(opts, :reasoning_effort, "low")
    refuter_mode = Keyword.get(opts, :refuter_mode, "single_claim")

    band =
      Keyword.get(
        opts,
        :band,
        if(refuter_mode == "novelty_gate", do: "after_first", else: "policy_difference")
      )

    id = Keyword.get(opts, :id, "claim-refuter-v0")
    output_root = Keyword.get(opts, :output_root, @root)

    cases = Sugary.PublicBenchmarks.load_cases!(suite, limit: limit, offset: offset)
    materializations = load_materializations!(materialization_run)
    all_rows = marginal_rows(source_run, policy_id, base_policy_id, cases, band)
    selected_rows = all_rows |> Enum.drop(claim_offset) |> Enum.take(claim_limit)
    out_dir = make_out_dir(output_root, id)
    File.mkdir_p!(out_dir)

    workspaces =
      selected_rows
      |> Enum.map(& &1.case.id)
      |> Enum.uniq()
      |> Map.new(fn case_id ->
        materialization = Map.fetch!(materializations, case_id)
        {case_id, prepare_worktree!(case_id, materialization)}
      end)

    config = %{
      version: "claim-refuter-gauntlet-v0",
      source_run: Path.expand(source_run),
      materialization_run: Path.expand(materialization_run),
      suite: suite,
      limit: limit,
      offset: offset,
      policy: policy_id,
      base_policy: base_policy_id,
      marginal_claims: length(all_rows),
      selected_claims: length(selected_rows),
      claim_offset: claim_offset,
      claim_limit: claim_limit,
      concurrency: concurrency,
      replay_mode: replay_mode,
      model: model,
      reasoning_effort: reasoning_effort,
      refuter_mode: refuter_mode,
      band: band,
      oracle_exposed_to_refuter: false,
      official_score_claim: false
    }

    Sugary.Json.write!(Path.join(out_dir, "config.json"), config)

    verdicts =
      selected_rows
      |> Task.async_stream(
        fn row ->
          workspace = Map.fetch!(workspaces, row.case.id)

          verdict =
            refute_claim(row, workspace,
              replay_mode: replay_mode,
              model: model,
              reasoning_effort: reasoning_effort,
              refuter_mode: refuter_mode
            )

          write_verdict!(out_dir, row, verdict)
          IO.puts("[claim-refuter] #{row.position}/#{length(all_rows)} #{verdict.verdict}")
          {row.claim["id"], verdict}
        end,
        max_concurrency: concurrency,
        ordered: false,
        timeout: :infinity
      )
      |> Enum.map(fn
        {:ok, pair} -> pair
        {:exit, reason} -> raise "claim refuter task failed: #{inspect(reason)}"
      end)
      |> Map.new()

    reports =
      [
        %{id: "refute-only-t60", mode: :refute_only, threshold: 0.60},
        %{id: "refute-only-t70", mode: :refute_only, threshold: 0.70},
        %{id: "refute-only-t80", mode: :refute_only, threshold: 0.80},
        %{id: "support-only-t60", mode: :support_only, threshold: 0.60},
        %{id: "support-only-t70", mode: :support_only, threshold: 0.70},
        %{id: "support-only-t80", mode: :support_only, threshold: 0.80}
      ]
      |> Enum.map(&score_policy(&1, source_run, policy_id, cases, all_rows, verdicts))

    baseline = source_score!(source_run, policy_id)
    base_floor = source_score!(source_run, base_policy_id)
    quality = refuter_quality(selected_rows, verdicts, source_run, policy_id)
    decision = decision(reports, baseline, quality, length(selected_rows), length(all_rows))

    Sugary.Json.write!(Path.join(out_dir, "baseline-scorecard.json"), baseline)
    Sugary.Json.write!(Path.join(out_dir, "base-floor-scorecard.json"), base_floor)
    Sugary.Json.write!(Path.join(out_dir, "policy-scorecards.json"), reports)
    Sugary.Json.write!(Path.join(out_dir, "refuter-quality.json"), quality)
    Sugary.Json.write!(Path.join(out_dir, "decision.json"), decision)

    File.write!(
      Path.join(out_dir, "report.md"),
      render_report(config, baseline, reports, quality, decision)
    )

    out_dir
  end

  defp marginal_rows(source_run, policy_id, _base_policy_id, cases, "after_first") do
    cases
    |> Enum.flat_map(fn bench_case ->
      full = published_claims(source_run, policy_id, bench_case.id)

      full
      |> Enum.with_index()
      |> Enum.drop(1)
      |> Enum.map(fn {claim, index} ->
        %{
          case: bench_case,
          claim: claim,
          source_run: source_run,
          prior_claims: Enum.take(full, index)
        }
      end)
    end)
    |> with_positions()
  end

  defp marginal_rows(source_run, policy_id, base_policy_id, cases, _policy_difference) do
    cases
    |> Enum.flat_map(fn bench_case ->
      full = published_claims(source_run, policy_id, bench_case.id)
      base = published_claims(source_run, base_policy_id, bench_case.id)
      base_ids = MapSet.new(Enum.map(base, & &1["id"]))

      full
      |> Enum.reject(&MapSet.member?(base_ids, &1["id"]))
      |> Enum.map(
        &%{
          case: bench_case,
          claim: &1,
          source_run: source_run,
          prior_claims: base
        }
      )
    end)
    |> with_positions()
  end

  defp with_positions(rows) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {row, position} -> Map.put(row, :position, position) end)
  end

  defp published_claims(source_run, policy_id, case_id) do
    path = Path.join([source_run, policy_id, "claims", "#{case_id}.json"])

    path
    |> Sugary.Json.read!()
    |> Enum.filter(&(&1["publish_decision"] == "publish"))
  end

  defp load_materializations!(run_dir) do
    run_dir
    |> Path.join("cases/*.json")
    |> Path.wildcard()
    |> Map.new(fn path ->
      row = Sugary.Json.read!(path)
      {row["case_id"], row}
    end)
  end

  defp prepare_worktree!(case_id, materialization) do
    cache = materialization["repo_cache_path"] |> Path.expand()
    head_sha = get_in(materialization, ["refs", "head_sha"])
    base_sha = get_in(materialization, ["refs", "base_sha"])
    root = Path.expand(Path.join(@workspace_root, short_hash(case_id)))
    head = Path.join(root, "head")

    ready? =
      File.exists?(Path.join(head, ".git")) and
        case System.cmd("git", ["-C", head, "rev-parse", "HEAD"], stderr_to_stdout: true) do
          {sha, 0} -> String.trim(sha) == head_sha
          _ -> false
        end

    unless ready? do
      File.rm_rf!(root)
      File.mkdir_p!(root)
      System.cmd("git", ["--git-dir", cache, "worktree", "prune"], stderr_to_stdout: true)

      case System.cmd(
             "git",
             ["--git-dir", cache, "worktree", "add", "--detach", head, head_sha],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, status} -> raise "failed to prepare refuter worktree (#{status}): #{output}"
      end
    end

    %{head: head, base_sha: base_sha, head_sha: head_sha, repo_cache: cache}
  end

  defp refute_claim(row, workspace, opts) do
    bundle = %{
      case_id: "claim-#{short_hash(row.claim["id"])}",
      suite: "claim-refutation",
      pr: sanitized_pr(row.case.pr),
      diff: "",
      context: %{changed_files: get_in(row.case.context, [:allowed, :changed_files]) || []},
      method: %{id: "codex-claim-refuter"},
      metadata: %{
        candidate_claim: sanitize_claim(row.claim),
        existing_claims: Enum.map(row.prior_claims, &sanitize_claim/1),
        workspace: workspace
      }
    }

    method = %{
      id:
        "codex-claim-refuter-#{Keyword.fetch!(opts, :refuter_mode)}-#{Keyword.fetch!(opts, :model)}-#{Keyword.fetch!(opts, :reasoning_effort)}",
      type: "command",
      command: System.find_executable("elixir") || "elixir",
      args: ["scripts/reviewers/codex_claim_refuter.exs"],
      cwd: File.cwd!(),
      timeout_ms: 210_000,
      stdout_limit: 524_288,
      stderr_limit: 524_288,
      env: %{
        "SUGARY_CODEX_MODEL" => Keyword.fetch!(opts, :model),
        "SUGARY_CODEX_REASONING_EFFORT" => Keyword.fetch!(opts, :reasoning_effort),
        "SUGARY_CLAIM_REFUTER_MODE" => Keyword.fetch!(opts, :refuter_mode),
        "SUGARY_CODEX_INNER_TIMEOUT_MS" => "180000"
      },
      replay_mode: Keyword.fetch!(opts, :replay_mode),
      requires_network: true,
      cost_model: "codex_account",
      tool_version: codex_version()
    }

    result = Sugary.CommandReviewer.run(method, bundle)
    verdict = extract_verdict(result)

    Map.merge(verdict, %{
      latency_ms: result.latency_ms || 0,
      cost: result.cost || 0.0,
      errors: result.errors || [],
      execution_mode: execution_mode(result)
    })
  end

  defp extract_verdict(result) do
    command_artifact = result.artifacts |> List.wrap() |> List.first() || %{}

    reviewer_artifact =
      field(command_artifact, :reviewer_artifacts, []) |> List.wrap() |> List.first()

    if is_map(reviewer_artifact) do
      %{
        verdict: field(reviewer_artifact, :verdict, "abstain"),
        confidence: float(field(reviewer_artifact, :confidence, 0.0)),
        introduced_by_pr: field(reviewer_artifact, :introduced_by_pr),
        proof_type: field(reviewer_artifact, :proof_type, "none"),
        failure_reproduced: field(reviewer_artifact, :failure_reproduced, false),
        evidence: field(reviewer_artifact, :evidence, []),
        strongest_counterargument: field(reviewer_artifact, :strongest_counterargument, ""),
        reason: field(reviewer_artifact, :reason, ""),
        residual_uncertainty: field(reviewer_artifact, :residual_uncertainty, "")
      }
    else
      %{
        verdict: "abstain",
        confidence: 0.0,
        introduced_by_pr: nil,
        proof_type: "none",
        failure_reproduced: false,
        evidence: [],
        strongest_counterargument: "",
        reason: "No structured refuter artifact was returned.",
        residual_uncertainty: "Execution or adapter failure."
      }
    end
  end

  defp score_policy(policy, source_run, source_policy_id, cases, rows, verdicts) do
    rows_by_case = Enum.group_by(rows, & &1.case.id)

    case_results =
      Enum.map(cases, fn bench_case ->
        marginal = Map.get(rows_by_case, bench_case.id, [])

        source_claims = published_claims(source_run, source_policy_id, bench_case.id)
        marginal_ids = MapSet.new(Enum.map(marginal, & &1.claim["id"]))
        fixed = Enum.reject(source_claims, &MapSet.member?(marginal_ids, &1["id"]))

        kept =
          Enum.filter(marginal, fn row ->
            case Map.get(verdicts, row.claim["id"]) do
              nil -> true
              verdict -> keep?(verdict, policy)
            end
          end)
          |> Enum.map(& &1.claim)

        final = Enum.map(fixed ++ kept, &claim_struct(&1, "publish"))
        candidates = Enum.map(source_claims, &claim_struct(&1, "candidate"))

        %{
          case: bench_case,
          final_claims: final,
          candidate_claims: candidates,
          reviewer_result: %{cost: 0.0, latency_ms: 0}
        }
      end)

    score = Sugary.Scorer.score(policy.id, case_results)
    %{policy_id: policy.id, policy: policy, score: score}
  end

  defp keep?(%{errors: errors}, _policy) when errors != [], do: true

  defp keep?(verdict, %{mode: :refute_only, threshold: threshold}) do
    not (verdict.verdict in ["refute", "duplicate"] and verdict.confidence >= threshold)
  end

  defp keep?(verdict, %{mode: :support_only, threshold: threshold}) do
    verdict.verdict == "support" and verdict.confidence >= threshold
  end

  defp refuter_quality(rows, verdicts, source_run, policy_id) do
    evaluated = Enum.filter(rows, &Map.has_key?(verdicts, &1.claim["id"]))
    evaluated_verdicts = Enum.map(evaluated, &verdicts[&1.claim["id"]])

    totals =
      Enum.reduce(
        evaluated,
        %{
          essential_hit: 0,
          removable_noise: 0,
          neutral: 0,
          essential_hit_refuted: 0,
          removable_noise_refuted: 0,
          neutral_refuted: 0,
          support: 0,
          refute: 0,
          duplicate: 0,
          abstain: 0
        },
        fn row, acc ->
          verdict = verdicts[row.claim["id"]]
          effect = claim_effect(row, source_run, policy_id)
          class = effect.classification
          refuted_key = String.to_atom("#{class}_refuted")

          acc
          |> Map.update!(class, &(&1 + 1))
          |> Map.update!(String.to_existing_atom(verdict.verdict), &(&1 + 1))
          |> then(fn counts ->
            if verdict.verdict in ["refute", "duplicate"],
              do: Map.update!(counts, refuted_key, &(&1 + 1)),
              else: counts
          end)
        end
      )

    Map.merge(totals, %{
      evaluated: length(evaluated),
      removable_noise_refutation_rate:
        ratio(totals.removable_noise_refuted, totals.removable_noise),
      essential_hit_harm_rate: ratio(totals.essential_hit_refuted, totals.essential_hit),
      total_latency_ms: Enum.sum(Enum.map(evaluated_verdicts, & &1.latency_ms)),
      avg_latency_ms:
        ratio(Enum.sum(Enum.map(evaluated_verdicts, & &1.latency_ms)), length(evaluated_verdicts)),
      live_results: Enum.count(evaluated_verdicts, &(&1.execution_mode == "live")),
      replayed_results: Enum.count(evaluated_verdicts, &(&1.execution_mode == "replay")),
      reviewer_errors: evaluated_verdicts |> Enum.flat_map(&List.wrap(&1.errors)) |> length()
    })
  end

  defp claim_effect(row, source_run, policy_id) do
    all = published_claims(source_run, policy_id, row.case.id)
    without = Enum.reject(all, &(&1["id"] == row.claim["id"]))

    all_accounting =
      Sugary.ScoreAccounting.claim_accounting(
        row.case,
        Enum.map(all, &claim_struct(&1, "publish"))
      )

    without_accounting =
      Sugary.ScoreAccounting.claim_accounting(
        row.case,
        Enum.map(without, &claim_struct(&1, "publish"))
      )

    hit_loss = all_accounting.unique_hits - without_accounting.unique_hits
    noise_reduction = all_accounting.noise_events - without_accounting.noise_events

    classification =
      cond do
        hit_loss > 0 -> :essential_hit
        noise_reduction > 0 -> :removable_noise
        true -> :neutral
      end

    %{classification: classification, hit_loss: hit_loss, noise_reduction: noise_reduction}
  end

  defp decision(reports, baseline, quality, selected, total) do
    winner =
      reports
      |> Enum.filter(&(&1.score.precision >= baseline["precision"]))
      |> Enum.max_by(&{&1.score.f1, &1.score.hits, -&1.score.noise}, fn -> nil end)

    complete = selected == total

    execution_valid = quality.reviewer_errors == 0

    qualifies =
      complete and execution_valid and winner != nil and winner.score.f1 >= baseline["f1"] + 0.01 and
        winner.score.recall >= baseline["recall"] - 0.02 and
        winner.score.noise < baseline["noise"] and
        quality.essential_hit_harm_rate <= 0.15

    %{
      decision:
        cond do
          not complete -> "pilot_only"
          not execution_valid -> "invalid_due_to_reviewer_failures"
          qualifies -> "qualify_for_fresh_slice"
          true -> "reject_refuter_v0"
        end,
      winner: if(winner, do: winner.policy_id, else: nil),
      complete_marginal_band: complete,
      selected_claims: selected,
      total_marginal_claims: total,
      checks: %{
        f1_gain: winner != nil and winner.score.f1 >= baseline["f1"] + 0.01,
        precision: winner != nil and winner.score.precision >= baseline["precision"],
        recall: winner != nil and winner.score.recall >= baseline["recall"] - 0.02,
        noise: winner != nil and winner.score.noise < baseline["noise"],
        harm: quality.essential_hit_harm_rate <= 0.15,
        execution: execution_valid
      },
      next_step:
        cond do
          not execution_valid -> "Rerun failed claims before evaluating the hypothesis."
          qualifies -> "Lock this policy and run it on a fresh PR slice."
          true -> "Do not promote. Inspect refuter errors and verdict calibration."
        end
    }
  end

  defp source_score!(source_run, policy_id) do
    source_run
    |> Path.join("policy-scorecards.json")
    |> Sugary.Json.read!()
    |> Enum.find(&(&1["id"] == policy_id))
    |> case do
      nil -> raise "source run missing policy #{policy_id}"
      report -> report["score"]
    end
  end

  defp sanitize_claim(claim) do
    Map.take(claim, [
      "id",
      "claim",
      "category",
      "severity",
      "path",
      "start_line",
      "end_line",
      "introduced_by_pr",
      "evidence",
      "failure_path",
      "suggested_test"
    ])
  end

  defp sanitized_pr(pr) do
    %{title: field(pr, :title, ""), body: field(pr, :body, "")}
  end

  defp claim_struct(claim, decision) do
    claim
    |> Map.take([
      "id",
      "claim",
      "category",
      "severity",
      "confidence",
      "path",
      "start_line",
      "end_line",
      "introduced_by_pr",
      "evidence",
      "failure_path",
      "suggested_fix",
      "suggested_test",
      "dedupe_key",
      "source",
      "counterarguments",
      "suppressed_reason"
    ])
    |> Map.put("publish_decision", decision)
    |> ReviewClaim.new()
  end

  defp write_verdict!(out_dir, row, verdict) do
    path = Path.join([out_dir, "refutations", short_hash(row.case.id), "#{row.claim["id"]}.json"])

    Sugary.Json.write!(path, %{
      case_id: row.case.id,
      claim_id: row.claim["id"],
      claim: sanitize_claim(row.claim),
      verdict: verdict
    })
  end

  defp execution_mode(result) do
    result.artifacts
    |> List.wrap()
    |> List.first()
    |> field(:execution_mode, "unknown")
  end

  defp codex_version do
    case System.cmd("codex", ["--version"], stderr_to_stdout: true) do
      {version, 0} -> String.trim(version)
      _ -> "unknown"
    end
  end

  defp render_report(config, baseline, reports, quality, decision) do
    rows =
      Enum.map_join(reports, "\n", fn report ->
        score = report.score

        "| `#{report.policy_id}` | #{fmt(score.f1)} | #{fmt(score.precision)} | #{fmt(score.recall)} | #{fmt(score.snr)} | #{score.hits} | #{score.noise} | #{score.published_claims} |"
      end)

    """
    # Claim-Specific Refuter Gauntlet

    > Unofficial local Martian proxy. No official benchmark claim.

    Refuted #{config.selected_claims} of #{config.marginal_claims} marginal second comments with
    `#{config.model}` at `#{config.reasoning_effort}` reasoning.

    Baseline: F1 #{fmt(baseline["f1"])}, precision #{fmt(baseline["precision"])}, recall #{fmt(baseline["recall"])}, #{baseline["hits"]} hits, #{baseline["noise"]} noise.

    | Policy | F1 | Precision | Recall | SNR | Hits | Noise | Published |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    #{rows}

    ## Refuter Quality

    - Evaluated: #{quality.evaluated}
    - Essential hits / removable noise / neutral: #{quality.essential_hit} / #{quality.removable_noise} / #{quality.neutral}
    - Verdicts support / refute / duplicate / abstain: #{quality.support} / #{quality.refute} / #{quality.duplicate} / #{quality.abstain}
    - Removable-noise refutation rate: #{fmt(quality.removable_noise_refutation_rate)}
    - Essential-hit harm rate: #{fmt(quality.essential_hit_harm_rate)}
    - Average refuter latency: #{fmt(quality.avg_latency_ms / 1000)} seconds per claim
    - Live / replayed results: #{quality.live_results} / #{quality.replayed_results}
    - Reviewer errors: #{quality.reviewer_errors}

    ## Decision

    `#{decision.decision}`

    #{decision.next_step}
    """
  end

  defp make_out_dir(root, id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(root, "#{timestamp}-#{id}")
  end

  defp short_hash(text) do
    :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> String.slice(0, 12)
  end

  defp field(value, key, default \\ nil)
  defp field(nil, _key, default), do: default
  defp field(map, key, default), do: Map.get(map, key, Map.get(map, to_string(key), default))
  defp int(value) when is_integer(value), do: value
  defp int(value) when is_binary(value), do: String.to_integer(value)
  defp float(value) when is_float(value), do: value
  defp float(value) when is_integer(value), do: value / 1
  defp float(value) when is_binary(value), do: String.to_float(value)
  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den
  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)
end

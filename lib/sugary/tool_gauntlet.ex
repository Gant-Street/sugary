defmodule Sugary.ToolGauntlet do
  @root ".sugary/research/tool-gauntlets"
  @version "tool-gauntlet-v0"
  @attention_cost -0.1

  def default_capabilities,
    do: ["read_changed_files", "base_preexisting_check", "repo_rg"]

  def run!(opts) do
    source_run = Keyword.fetch!(opts, :source_run)
    method_id = Keyword.fetch!(opts, :method_id)
    baseline_id = Keyword.fetch!(opts, :baseline_id)
    suite = Keyword.get(opts, :suite, "martian-offline")
    limit = Keyword.get(opts, :limit, 25)
    offset = Keyword.get(opts, :offset, 0)
    split = Keyword.get(opts, :split)
    id = Keyword.get(opts, :id, "tool-gauntlet-v0")
    max_published = Keyword.get(opts, :max_published, 2)
    min_score = Keyword.get(opts, :min_score, 2.0)
    capabilities = Keyword.get(opts, :capabilities, default_capabilities())
    materialize? = Keyword.get(opts, :materialize, false)

    materialization_run =
      if materialize? do
        maybe_materialize!(suite, split, limit, offset, "#{id}-repo-materialization")
      else
        nil
      end

    cases = load_cases!(suite, limit: limit, offset: offset, split: split)
    out_dir = make_run_dir(id)
    File.mkdir_p!(out_dir)

    config = %{
      version: @version,
      source_run: source_run,
      method_id: method_id,
      baseline_id: baseline_id,
      suite: suite,
      split: split,
      limit: limit,
      offset: offset,
      max_published: max_published,
      min_score: min_score,
      capabilities: capabilities,
      materialize: materialize?,
      materialization_run: materialization_run
    }

    source_report = score_source(source_run, method_id, cases, method_id)
    baseline_report = score_source(source_run, baseline_id, cases, baseline_id)

    control =
      score_tool_policy(
        "control-no-tool",
        source_run,
        method_id,
        cases,
        [],
        max_published,
        min_score
      )

    {steps, kept_capabilities, final_incumbent} =
      Enum.reduce(capabilities, {[], [], control}, fn capability, {steps, kept, incumbent} ->
        candidate_capabilities = kept ++ [capability]

        candidate =
          score_tool_policy(
            "tool-#{slug(Enum.join(candidate_capabilities, "-"))}",
            source_run,
            method_id,
            cases,
            candidate_capabilities,
            max_published,
            min_score
          )

        decision = decide(candidate, incumbent)

        step =
          %{
            capability: capability,
            tested_capabilities: candidate_capabilities,
            incumbent_policy_id: incumbent.policy_id,
            candidate_policy_id: candidate.policy_id,
            decision: decision,
            candidate: summarize_report(candidate),
            incumbent: summarize_report(incumbent)
          }

        if decision.decision == "keep" do
          {steps ++ [step], candidate_capabilities, candidate}
        else
          {steps ++ [step], kept, incumbent}
        end
      end)

    final = %{
      config: config,
      source_method: summarize_report(source_report),
      raw_baseline: summarize_report(baseline_report),
      control: summarize_report(control),
      final_incumbent: summarize_report(final_incumbent),
      kept_capabilities: kept_capabilities,
      steps: steps,
      interpretation: interpretation(steps)
    }

    Sugary.Json.write!(Path.join(out_dir, "config.json"), config)
    Sugary.Json.write!(Path.join(out_dir, "source-method-scorecard.json"), source_report)
    Sugary.Json.write!(Path.join(out_dir, "baseline-scorecard.json"), baseline_report)
    Sugary.Json.write!(Path.join(out_dir, "control-scorecard.json"), control)
    Sugary.Json.write!(Path.join(out_dir, "step-scorecards.json"), steps)
    Sugary.Json.write!(Path.join(out_dir, "decision.json"), final)

    write_transcripts!(out_dir, [
      control | reports_from_steps(steps, source_run, method_id, cases, max_published, min_score)
    ])

    File.write!(Path.join(out_dir, "tool-gauntlet-report.md"), render_report(final))

    out_dir
  end

  defp reports_from_steps(steps, source_run, method_id, cases, max_published, min_score) do
    Enum.map(steps, fn step ->
      score_tool_policy(
        step.candidate_policy_id,
        source_run,
        method_id,
        cases,
        step.tested_capabilities,
        max_published,
        min_score
      )
    end)
  end

  defp maybe_materialize!(suite, split, limit, offset, id)
       when suite in ["martian-offline", "cr-bench", "aacr-bench"] do
    Sugary.RepoMaterializer.run!(
      suite: suite,
      split: split,
      limit: limit,
      offset: offset,
      mode: "fetch",
      id: id
    )
  end

  defp maybe_materialize!(_suite, _split, _limit, _offset, _id), do: nil

  defp score_source(source_run, method_id, cases, policy_id) do
    results =
      Enum.map(cases, fn bench_case ->
        claims =
          source_run
          |> claims_path(method_id, bench_case.id)
          |> Sugary.Json.read!()
          |> atomize()
          |> Enum.map(&ensure_publish_decision/1)

        %{
          case: bench_case,
          reviewer_result: %{cost: 0.0, latency_ms: 0},
          candidate_claims: claims,
          final_claims: claims
        }
      end)

    build_report(policy_id, [], results)
  end

  defp score_tool_policy(
         policy_id,
         source_run,
         method_id,
         cases,
         capabilities,
         max_published,
         min_score
       ) do
    results =
      Enum.map(cases, fn bench_case ->
        candidates =
          source_run
          |> claims_path(method_id, bench_case.id)
          |> Sugary.Json.read!()
          |> atomize()
          |> Enum.map(&reset_claim/1)

        final_claims =
          candidates
          |> Enum.map(&score_claim(&1, bench_case, capabilities))
          |> Enum.sort_by(
            &{Map.fetch!(&1, :publish_score), Map.get(&1, :confidence) || 0.0},
            :desc
          )
          |> Enum.with_index()
          |> Enum.map(fn {claim, index} ->
            if index < max_published and claim.publish_score >= min_score do
              claim
              |> Map.put(:publish_decision, "publish")
              |> Map.delete(:suppressed_reason)
            else
              claim
              |> Map.put(:publish_decision, "suppress")
              |> Map.put(:suppressed_reason, "tool_gauntlet_threshold")
            end
          end)

        %{
          case: bench_case,
          reviewer_result: %{cost: 0.0, latency_ms: 0},
          candidate_claims: candidates,
          final_claims: final_claims
        }
      end)

    build_report(policy_id, capabilities, results)
  end

  defp build_report(policy_id, capabilities, results) do
    score = Sugary.Scorer.score(policy_id, results)
    per_case = Enum.map(results, &case_stats/1)

    %{
      policy_id: policy_id,
      version: @version,
      capabilities: capabilities,
      score: score,
      per_case: per_case,
      research_utility: research_utility(per_case),
      tool_transcripts: Enum.flat_map(results, &tool_transcripts(policy_id, &1))
    }
  end

  defp score_claim(claim, bench_case, capabilities) do
    signals = Enum.map(capabilities, &tool_signal(&1, claim, bench_case))
    base_score = base_score(claim)

    bonus =
      signals |> Enum.map(&(Map.get(&1, :bonus, 0.0) - Map.get(&1, :penalty, 0.0))) |> Enum.sum()

    publish_score = base_score + bonus

    claim
    |> Map.put(:tool_signals, signals)
    |> Map.put(:base_publish_score, Float.round(base_score, 4))
    |> Map.put(:publish_score, Float.round(publish_score, 4))
  end

  defp tool_signal("read_changed_files", claim, bench_case),
    do: normalize_repo_tool_signal("read_changed_files", claim, bench_case)

  defp tool_signal("read_changed_file", claim, bench_case),
    do: normalize_repo_tool_signal("read_changed_file", claim, bench_case)

  defp tool_signal("base_preexisting_check", claim, bench_case) do
    text = claim_text(claim)

    cond do
      Map.get(claim, :introduced_by_pr) == false ->
        signal(
          "base_preexisting_check",
          "counterargument",
          "Claim says the issue was not introduced by this PR.",
          0.0,
          1.6
        )

      String.contains?(text, "preexisting") ->
        signal(
          "base_preexisting_check",
          "counterargument",
          "Claim text points to preexisting behavior.",
          0.0,
          1.1
        )

      has_before_after?(bench_case) ->
        signal(
          "base_preexisting_check",
          "neutral",
          "Before/after context was available but did not refute introducedness.",
          0.15,
          0.0
        )

      true ->
        signal(
          "base_preexisting_check",
          "unavailable",
          "No base version context was available.",
          0.0,
          0.0
        )
    end
  end

  defp tool_signal("repo_rg", claim, bench_case),
    do: normalize_repo_tool_signal("repo_rg", claim, bench_case)

  defp tool_signal("repo_grep", claim, bench_case),
    do: normalize_repo_tool_signal("repo_grep", claim, bench_case)

  defp tool_signal("git_history", claim, bench_case),
    do: normalize_repo_tool_signal("git_history", claim, bench_case)

  defp tool_signal("git_grep_history", claim, bench_case),
    do: normalize_repo_tool_signal("git_grep_history", claim, bench_case)

  defp tool_signal(name, _claim, _bench_case),
    do: signal(name, "unknown", "Unknown tool capability.", 0.0, 0.0)

  defp normalize_repo_tool_signal(capability, claim, bench_case) do
    bench_case
    |> Sugary.RepoTools.evidence_for_claim(claim, capability)
    |> Map.put(:tool, capability)
    |> Map.update(:bonus, 0.0, &(&1 || 0.0))
    |> Map.update(:penalty, 0.0, &(&1 || 0.0))
  end

  defp signal(tool, status, summary, bonus, penalty) do
    %{
      tool: tool,
      status: status,
      summary: summary,
      bonus: bonus,
      penalty: penalty
    }
  end

  defp decide(candidate, incumbent) do
    unique_hits = unique_hits(candidate, incumbent)
    paired = paired_comparison(candidate, incumbent)

    checks = %{
      f1: candidate.score.f1 > incumbent.score.f1,
      usefulness: candidate.score.usefulness >= incumbent.score.usefulness,
      snr: candidate.score.snr >= incumbent.score.snr,
      noise: candidate.score.noise <= incumbent.score.noise,
      comments: candidate.score.avg_comments_per_pr <= incumbent.score.avg_comments_per_pr,
      unique_or_noise_reduction:
        unique_hits >= 1 or candidate.score.noise < incumbent.score.noise,
      paired: paired.wins > paired.losses
    }

    decision =
      cond do
        Enum.all?(Map.values(checks)) ->
          "keep"

        unique_hits > 0 or candidate.score.hits > incumbent.score.hits ->
          "quarantine"

        true ->
          "discard"
      end

    reason =
      case decision do
        "keep" ->
          "Tool improved the fixed incumbent while passing all guardrails."

        "quarantine" ->
          "Tool found extra signal but failed one or more noise/usefulness guardrails."

        "discard" ->
          "Tool did not add measurable value over the fixed incumbent."
      end

    %{
      decision: decision,
      reason: reason,
      checks: checks,
      unique_hits_over_incumbent: unique_hits,
      paired_vs_incumbent: paired,
      score_delta: score_delta(candidate.score, incumbent.score)
    }
  end

  defp case_stats(result) do
    published = Enum.filter(result.final_claims, &(&1.publish_decision == "publish"))

    {hit_ids, noise} =
      Enum.reduce(published, {MapSet.new(), 0}, fn claim, {hits, noise} ->
        case Sugary.ClaimMatcher.expected_claim(result.case, claim) do
          nil ->
            {hits, noise + 1}

          expected ->
            expected_id = field(expected, :id)

            if MapSet.member?(hits, expected_id) do
              {hits, noise + 1}
            else
              {MapSet.put(hits, expected_id), noise}
            end
        end
      end)

    %{
      case_id: result.case.id,
      expected: Sugary.ClaimMatcher.expected_ids(result.case) |> MapSet.size(),
      comments: length(published),
      hits: MapSet.size(hit_ids),
      noise: noise,
      hit_ids: MapSet.to_list(hit_ids)
    }
  end

  defp tool_transcripts(policy_id, result) do
    result.final_claims
    |> Enum.flat_map(fn claim ->
      claim
      |> Map.get(:tool_signals, [])
      |> Enum.map(fn signal ->
        %{
          policy_id: policy_id,
          case_id: result.case.id,
          claim_id: Map.get(claim, :id),
          dedupe_key: Map.get(claim, :dedupe_key),
          publish_decision: Map.get(claim, :publish_decision),
          publish_score: Map.get(claim, :publish_score),
          signal: signal
        }
      end)
    end)
  end

  defp paired_comparison(left, right) do
    right_by_case = Map.new(right.per_case, &{&1.case_id, &1})

    rows =
      Enum.map(left.per_case, fn left_case ->
        right_case = Map.fetch!(right_by_case, left_case.case_id)
        paired_outcome(left_case, right_case)
      end)

    total = max(length(rows), 1)
    wins = Enum.count(rows, &(&1 == :win))
    losses = Enum.count(rows, &(&1 == :loss))
    ties = Enum.count(rows, &(&1 == :tie))

    %{
      wins: wins,
      losses: losses,
      ties: ties,
      win_rate: wins / total,
      non_loss_rate: (wins + ties) / total
    }
  end

  defp paired_outcome(left, right) do
    cond do
      left.hits > right.hits and left.noise <= right.noise ->
        :win

      left.hits == right.hits and left.noise < right.noise ->
        :win

      left.hits == right.hits and left.noise == right.noise and left.comments < right.comments ->
        :win

      right.hits > left.hits and right.noise <= left.noise ->
        :loss

      right.hits == left.hits and right.noise < left.noise ->
        :loss

      right.hits == left.hits and right.noise == left.noise and right.comments < left.comments ->
        :loss

      true ->
        :tie
    end
  end

  defp unique_hits(left, right) do
    right_hits =
      right.per_case
      |> Enum.flat_map(&Enum.map(&1.hit_ids, fn hit -> {&1.case_id, hit} end))
      |> MapSet.new()

    left.per_case
    |> Enum.flat_map(&Enum.map(&1.hit_ids, fn hit -> {&1.case_id, hit} end))
    |> MapSet.new()
    |> MapSet.difference(right_hits)
    |> MapSet.size()
  end

  defp score_delta(left, right) do
    %{
      f1: left.f1 - right.f1,
      usefulness: left.usefulness - right.usefulness,
      snr: left.snr - right.snr,
      hits: left.hits - right.hits,
      noise: left.noise - right.noise,
      avg_comments_per_pr: left.avg_comments_per_pr - right.avg_comments_per_pr
    }
  end

  defp research_utility(per_case) do
    Enum.reduce(per_case, 0.0, fn row, total ->
      total + row.hits - row.noise + row.comments * @attention_cost
    end)
  end

  defp base_score(claim) do
    confidence = Map.get(claim, :confidence) || 0.0

    confidence * 1.2 +
      severity_score(Map.get(claim, :severity)) * 0.75 +
      evidence_score(Map.get(claim, :evidence, [])) * 0.85 +
      min(length(List.wrap(Map.get(claim, :failure_path, []))), 4) / 4 * 0.5
  end

  defp severity_score(severity) do
    %{"critical" => 1.0, "high" => 0.82, "medium" => 0.55, "low" => 0.2}
    |> Map.get(severity |> to_string() |> String.downcase(), 0.45)
  end

  defp evidence_score(evidence) do
    tier =
      evidence
      |> List.wrap()
      |> Enum.map(&(field(&1, :tier, 5) || 5))
      |> Enum.min(fn -> 5 end)

    max(6 - tier, 1) / 5
  end

  defp has_before_after?(bench_case),
    do: is_binary(bench_case.code_before) or is_binary(bench_case.code_after)

  defp claim_text(claim) do
    [
      Map.get(claim, :claim),
      Map.get(claim, :category),
      Map.get(claim, :failure_path, []) |> List.wrap() |> Enum.join(" "),
      claim
      |> Map.get(:evidence, [])
      |> List.wrap()
      |> Enum.map(&field(&1, :summary, ""))
      |> Enum.join(" ")
    ]
    |> Enum.join(" ")
    |> String.downcase()
  end

  defp ensure_publish_decision(claim),
    do: Map.put(claim, :publish_decision, Map.get(claim, :publish_decision) || "publish")

  defp reset_claim(claim) do
    claim
    |> Map.put(:publish_decision, "candidate")
    |> Map.delete(:suppressed_reason)
  end

  defp summarize_report(report) do
    %{
      policy_id: report.policy_id,
      capabilities: report.capabilities,
      score: report.score,
      research_utility: report.research_utility,
      per_case: report.per_case
    }
  end

  defp interpretation([]), do: "No capabilities were tested."

  defp interpretation(steps) do
    kept = Enum.filter(steps, &(get_in(&1, [:decision, :decision]) == "keep"))
    quarantined = Enum.filter(steps, &(get_in(&1, [:decision, :decision]) == "quarantine"))

    cond do
      kept != [] ->
        "At least one tool capability passed the fixed-incumbent guardrails. Keep only the listed capabilities for the next locked evaluation."

      quarantined != [] ->
        "Some tool capabilities found extra signal but failed guardrails. Use them only for candidate generation until a proof/refutation gate controls their noise."

      true ->
        "No tested tool capability improved the fixed incumbent. Do not add these tools to the reviewer path yet."
    end
  end

  defp write_transcripts!(out_dir, reports) do
    lines =
      reports
      |> Enum.flat_map(& &1.tool_transcripts)
      |> Enum.map(&(Sugary.Json.encode!(&1) <> "\n"))
      |> Enum.join()

    File.write!(Path.join(out_dir, "tool-transcripts.jsonl"), lines)
  end

  defp render_report(final) do
    step_rows =
      final.steps
      |> Enum.map(fn step ->
        decision = step.decision
        score = step.candidate.score

        "| `#{step.capability}` | #{decision.decision} | #{fmt(score.f1)} | #{fmt(score.usefulness)} | #{fmt(score.snr)} | #{score.hits} | #{score.noise} | #{fmt(score.avg_comments_per_pr)} | #{decision.unique_hits_over_incumbent} | #{decision.reason} |"
      end)
      |> Enum.join("\n")

    """
    # Tool Gauntlet v0

    This is a local, replay-based tool-capability ablation. It does not prove product or public benchmark superiority.

    ## Setup

    - Source run: `#{final.config.source_run}`
    - Candidate pool: `#{final.config.method_id}`
    - Baseline: `#{final.config.baseline_id}`
    - Suite: `#{final.config.suite}` offset #{final.config.offset}, limit #{final.config.limit}
    - Fixed max published claims: #{final.config.max_published}
    - Fixed min publish score: #{final.config.min_score}
    - Repo materialization run: `#{final.config.materialization_run || "not requested"}`

    ## Baselines

    | Variant | F1 | Usefulness | SNR | Hits | Noise | Avg comments/PR |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: |
    | Source method | #{fmt(final.source_method.score.f1)} | #{fmt(final.source_method.score.usefulness)} | #{fmt(final.source_method.score.snr)} | #{final.source_method.score.hits} | #{final.source_method.score.noise} | #{fmt(final.source_method.score.avg_comments_per_pr)} |
    | Raw baseline | #{fmt(final.raw_baseline.score.f1)} | #{fmt(final.raw_baseline.score.usefulness)} | #{fmt(final.raw_baseline.score.snr)} | #{final.raw_baseline.score.hits} | #{final.raw_baseline.score.noise} | #{fmt(final.raw_baseline.score.avg_comments_per_pr)} |
    | Control no-tool ranker | #{fmt(final.control.score.f1)} | #{fmt(final.control.score.usefulness)} | #{fmt(final.control.score.snr)} | #{final.control.score.hits} | #{final.control.score.noise} | #{fmt(final.control.score.avg_comments_per_pr)} |
    | Final kept incumbent | #{fmt(final.final_incumbent.score.f1)} | #{fmt(final.final_incumbent.score.usefulness)} | #{fmt(final.final_incumbent.score.snr)} | #{final.final_incumbent.score.hits} | #{final.final_incumbent.score.noise} | #{fmt(final.final_incumbent.score.avg_comments_per_pr)} |

    ## Tool Steps

    | Tool | Decision | F1 | Usefulness | SNR | Hits | Noise | Avg comments/PR | Unique hits | Reason |
    | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
    #{if step_rows == "", do: "| none | discard | 0 | 0 | 0 | 0 | 0 | 0 | 0 | No tools tested. |", else: step_rows}

    ## Decision

    Kept capabilities: #{Enum.map_join(final.kept_capabilities, ", ", &"`#{&1}`")}

    #{final.interpretation}

    ## Research Discipline

    Each step adds exactly one tool capability to the current kept incumbent. Repository tools return structured local citations when a materialized workspace or bare git cache exists; unavailable tools do not count as success. A quarantined tool may be useful for candidate generation, but should not influence publication until a later proof/refutation gate shows it can control noise.
    """
  end

  defp load_cases!(suite, opts) when suite in ["martian-offline", "cr-bench"],
    do: Sugary.PublicBenchmarks.load_cases!(suite, opts)

  defp load_cases!(suite, opts) do
    limit = Keyword.get(opts, :limit)
    offset = Keyword.get(opts, :offset) || 0

    suite
    |> Sugary.Fixtures.load_suite!(opts)
    |> Enum.drop(offset)
    |> maybe_limit(limit)
  end

  defp claims_path(source_run, method_id, case_id),
    do: Path.join([source_run, method_id, "claims", "#{case_id}.json"])

  defp make_run_dir(id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(@root, "#{timestamp}-#{id}")
  end

  defp maybe_limit(cases, nil), do: cases
  defp maybe_limit(cases, ""), do: cases
  defp maybe_limit(cases, limit) when is_integer(limit), do: Enum.take(cases, limit)
  defp maybe_limit(cases, limit), do: maybe_limit(cases, String.to_integer(to_string(limit)))

  defp atomize(%{} = map),
    do: Map.new(map, fn {key, value} -> {atom_key(key), atomize(value)} end)

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value

  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(%_module{} = struct, key, default),
    do: struct |> Map.from_struct() |> field(key, default)

  defp field(%{} = map, key, default), do: map[key] || map[to_string(key)] || default
  defp field(_value, _key, default), do: default

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value) when is_integer(value), do: to_string(value)
  defp fmt(nil), do: "0.000"
  defp fmt(value), do: to_string(value)
end

defmodule Sugary.RankingPolicyAblation do
  @attention_cost -0.1
  @bootstrap_iterations 200

  def run!(opts) do
    source_run = Keyword.fetch!(opts, :source_run)
    method_id = Keyword.fetch!(opts, :method_id)
    suite = Keyword.get(opts, :suite, "martian-offline")
    limit = Keyword.get(opts, :limit, 25)
    offset = Keyword.get(opts, :offset, 0)
    baselines = Keyword.get(opts, :baselines, ["codex-gpt-5.5-xhigh"])
    id = Keyword.get(opts, :id, "ranking-policy-ablation-v1")

    cases = Sugary.PublicBenchmarks.load_cases!(suite, limit: limit, offset: offset)
    out_dir = make_run_dir(id)
    File.mkdir_p!(out_dir)

    policies = default_policies()
    policy_reports = Enum.map(policies, &score_policy(&1, source_run, method_id, cases))
    baseline_reports = Enum.map(baselines, &score_baseline(&1, source_run, cases))
    current = Enum.find(policy_reports, &(&1.policy_id == "team-ev-max-3"))
    raw_best = Enum.max_by(baseline_reports, & &1.score.f1, fn -> nil end)

    policy_reports =
      Enum.map(policy_reports, fn report ->
        report
        |> Map.put(:paired_vs_current, paired_comparison(report, current))
        |> Map.put(:paired_vs_raw_best, paired_comparison(report, raw_best))
        |> Map.put(:promotion_guardrails, guardrails(report, raw_best))
      end)

    winner = choose_winner(policy_reports, raw_best)

    write_artifacts!(
      out_dir,
      source_run,
      method_id,
      suite,
      limit,
      offset,
      policy_reports,
      baseline_reports,
      winner
    )

    out_dir
  end

  def default_policies do
    [
      %{id: "team-ev-max-1", strategy: "team_ev", max_published: 1, min_score: 1.4},
      %{id: "team-ev-max-2", strategy: "team_ev", max_published: 2, min_score: 1.4},
      %{id: "team-ev-max-3", strategy: "team_ev", max_published: 3, min_score: 1.4},
      %{
        id: "evidence-agreement-max-2",
        strategy: "evidence_agreement",
        max_published: 2,
        min_score: 3.0
      },
      %{
        id: "evidence-agreement-max-3",
        strategy: "evidence_agreement",
        max_published: 3,
        min_score: 3.0
      }
    ]
  end

  defp score_policy(policy, source_run, method_id, cases) do
    results =
      Enum.map(cases, fn bench_case ->
        candidates =
          source_run
          |> claims_path(method_id, bench_case.id)
          |> Sugary.Json.read!()
          |> atomize()
          |> Enum.map(&reset_claim/1)

        final_claims = publish_claims(candidates, policy)

        %{
          case: bench_case,
          reviewer_result: %{cost: 0.0, latency_ms: 0},
          candidate_claims: candidates,
          final_claims: final_claims
        }
      end)

    score = Sugary.Scorer.score(policy.id, results)
    per_case = Enum.map(results, &case_stats/1)

    %{
      policy_id: policy.id,
      policy: policy,
      type: "policy",
      score: score,
      per_case: per_case,
      research_utility: research_utility(per_case),
      critical_high_recall: critical_high_recall(results),
      bootstrap: bootstrap(per_case)
    }
  end

  defp score_baseline(method_id, source_run, cases) do
    results =
      Enum.map(cases, fn bench_case ->
        final_claims =
          source_run
          |> claims_path(method_id, bench_case.id)
          |> Sugary.Json.read!()
          |> atomize()

        %{
          case: bench_case,
          reviewer_result: %{cost: 0.0, latency_ms: 0},
          candidate_claims: final_claims,
          final_claims: final_claims
        }
      end)

    score = Sugary.Scorer.score(method_id, results)
    per_case = Enum.map(results, &case_stats/1)

    %{
      policy_id: method_id,
      type: "baseline",
      score: score,
      per_case: per_case,
      research_utility: research_utility(per_case),
      critical_high_recall: critical_high_recall(results),
      bootstrap: bootstrap(per_case)
    }
  end

  defp publish_claims(candidates, policy) do
    candidates
    |> Enum.sort_by(&rank_score(&1, policy), :desc)
    |> Enum.with_index()
    |> Enum.map(fn {claim, index} ->
      score = rank_score(claim, policy)

      cond do
        index < policy.max_published and score >= policy.min_score ->
          claim
          |> Map.put(:publish_decision, "publish")
          |> Map.delete(:suppressed_reason)

        true ->
          claim
          |> Map.put(:publish_decision, "suppress")
          |> Map.put(:suppressed_reason, "ranking_policy_threshold")
      end
    end)
  end

  defp rank_score(claim, %{strategy: "evidence_agreement"}) do
    team_ev_score(claim) * max(6 - strongest_evidence_tier(claim), 1)
  end

  defp rank_score(claim, _policy), do: team_ev_score(claim)

  defp team_ev_score(claim) do
    confidence = Map.get(claim, :confidence) || 0.0
    confidence * severity_weight(Map.get(claim, :severity)) * agreement_count(claim)
  end

  defp severity_weight(severity) do
    %{"critical" => 4, "high" => 3, "medium" => 2, "low" => 1}
    |> Map.get(severity |> to_string() |> String.downcase(), 1)
  end

  defp high_or_critical?(severity) do
    severity
    |> to_string()
    |> String.downcase()
    |> Kernel.in(["critical", "high"])
  end

  defp agreement_count(claim), do: get_in(claim, [:source, :agreement_count]) || 1

  defp strongest_evidence_tier(claim) do
    claim
    |> Map.get(:evidence, [])
    |> List.wrap()
    |> Enum.map(&(Map.get(&1, :tier) || 5))
    |> Enum.min(fn -> 5 end)
  end

  defp case_stats(result) do
    published = Enum.filter(result.final_claims, &(&1.publish_decision == "publish"))

    {hit_ids, noise, high_critical_hits} =
      Enum.reduce(published, {MapSet.new(), 0, MapSet.new()}, fn claim, {hits, noise, severe} ->
        case Sugary.ClaimMatcher.expected_claim(result.case, claim) do
          nil ->
            {hits, noise + 1, severe}

          expected ->
            expected_id = field(expected, :id)

            if MapSet.member?(hits, expected_id) do
              {hits, noise + 1, severe}
            else
              severe =
                if high_or_critical?(field(expected, :severity, "medium")) do
                  MapSet.put(severe, expected_id)
                else
                  severe
                end

              {MapSet.put(hits, expected_id), noise, severe}
            end
        end
      end)

    %{
      case_id: result.case.id,
      expected: Sugary.ClaimMatcher.expected_ids(result.case) |> MapSet.size(),
      high_critical_expected: high_critical_expected(result.case),
      comments: length(published),
      hits: MapSet.size(hit_ids),
      high_critical_hits: MapSet.size(high_critical_hits),
      noise: noise
    }
  end

  defp high_critical_expected(bench_case) do
    bench_case.oracle
    |> Map.get(:expectedClaims, [])
    |> Enum.count(&(field(&1, :severity, "medium") |> high_or_critical?()))
  end

  defp research_utility(per_case) do
    per_case
    |> Enum.reduce(0.0, fn row, total ->
      total + row.hits - row.noise + row.comments * @attention_cost
    end)
  end

  defp critical_high_recall(results) do
    totals =
      results
      |> Enum.map(&case_stats/1)
      |> Enum.reduce(%{expected: 0, hits: 0}, fn row, acc ->
        %{
          expected: acc.expected + row.high_critical_expected,
          hits: acc.hits + row.high_critical_hits
        }
      end)

    ratio(totals.hits, totals.expected)
  end

  defp paired_comparison(_left, nil), do: nil

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
      baseline: right.policy_id,
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

      left.high_critical_hits > right.high_critical_hits and left.noise <= right.noise ->
        :win

      right.hits > left.hits and right.noise <= left.noise ->
        :loss

      right.hits == left.hits and right.noise < left.noise ->
        :loss

      right.hits == left.hits and right.noise == left.noise and right.comments < left.comments ->
        :loss

      right.high_critical_hits > left.high_critical_hits and right.noise <= left.noise ->
        :loss

      true ->
        :tie
    end
  end

  defp guardrails(_report, nil), do: %{passes: false, reason: "missing_raw_baseline"}

  defp guardrails(report, raw_best) do
    score = report.score
    baseline = raw_best.score

    checks = %{
      beats_f1: score.f1 > baseline.f1,
      usefulness: score.usefulness >= baseline.usefulness,
      snr: score.snr >= baseline.snr,
      noise: score.noise <= baseline.noise,
      comments: score.avg_comments_per_pr <= baseline.avg_comments_per_pr,
      critical_high_recall: report.critical_high_recall + 0.05 >= raw_best.critical_high_recall
    }

    %{passes: Enum.all?(Map.values(checks)), checks: checks}
  end

  defp choose_winner(policy_reports, raw_best) do
    policy_reports
    |> Enum.filter(&(guardrails(&1, raw_best).passes == true))
    |> Enum.max_by(&{&1.research_utility, &1.score.f1, &1.score.snr}, fn -> nil end)
  end

  defp bootstrap(per_case) do
    :rand.seed(:exsplus, {101, 102, 103})

    samples =
      for _ <- 1..@bootstrap_iterations do
        rows = for _ <- per_case, do: Enum.random(per_case)
        aggregate(rows)
      end

    %{
      f1: interval(samples, :f1),
      usefulness: interval(samples, :usefulness),
      snr: interval(samples, :snr),
      recall: interval(samples, :recall)
    }
  end

  defp aggregate(rows) do
    totals =
      Enum.reduce(rows, %{comments: 0, hits: 0, noise: 0, expected: 0}, fn row, acc ->
        %{
          comments: acc.comments + row.comments,
          hits: acc.hits + row.hits,
          noise: acc.noise + row.noise,
          expected: acc.expected + row.expected
        }
      end)

    precision = ratio(totals.hits, totals.comments)
    recall = ratio(totals.hits, totals.expected)

    %{
      f1:
        if(precision + recall == 0, do: 0.0, else: 2 * precision * recall / (precision + recall)),
      usefulness: precision,
      snr: if(totals.noise == 0, do: totals.hits * 1.0, else: totals.hits / totals.noise),
      recall: recall
    }
  end

  defp interval(samples, key) do
    values = samples |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sort()

    %{
      low: percentile(values, 0.05),
      high: percentile(values, 0.95)
    }
  end

  defp percentile([], _p), do: 0.0

  defp percentile(values, p) do
    index = floor((length(values) - 1) * p)
    Enum.at(values, index)
  end

  defp write_artifacts!(
         out_dir,
         source_run,
         method_id,
         suite,
         limit,
         offset,
         policy_reports,
         baseline_reports,
         winner
       ) do
    Sugary.Json.write!(Path.join(out_dir, "ablation-config.json"), %{
      source_run: source_run,
      method_id: method_id,
      suite: suite,
      limit: limit,
      offset: offset,
      policies: Enum.map(policy_reports, & &1.policy)
    })

    Sugary.Json.write!(
      Path.join(out_dir, "policy-scorecards.json"),
      Enum.map(policy_reports, &json_report/1)
    )

    Sugary.Json.write!(
      Path.join(out_dir, "baseline-scorecards.json"),
      Enum.map(baseline_reports, &json_report/1)
    )

    Sugary.Json.write!(Path.join(out_dir, "decision.json"), decision(winner))

    File.write!(
      Path.join(out_dir, "report.md"),
      render_report(policy_reports, baseline_reports, winner, suite, limit, offset)
    )
  end

  defp json_report(report) do
    report
    |> Map.drop([:per_case])
    |> Map.put(:score, Map.from_struct(report.score))
  end

  defp decision(nil), do: %{decision: "no_policy_promoted"}
  defp decision(winner), do: %{decision: "promote", policy_id: winner.policy_id}

  defp render_report(policy_reports, baseline_reports, winner, suite, limit, offset) do
    baseline_rows =
      baseline_reports
      |> Enum.map(&score_row(&1, false))
      |> Enum.join("\n")

    policy_rows =
      policy_reports
      |> Enum.map(&score_row(&1, true))
      |> Enum.join("\n")

    """
    # Ranking Policy Ablation v1

    Unofficial local smoke run. Not an official benchmark score.

    ## Scope

    - Suite: `#{suite}`
    - Offset: #{offset}
    - Limit: #{limit}
    - Candidate pool: fixed claims from prior run artifacts.
    - Decision metric: research utility with F1/usefulness/SNR/noise/comment guardrails.

    ## Baselines

    | Method | Utility | F1 | Recall | Usefulness | SNR | Hits | Noise | Comments | Avg Comments/PR | Critical/High Recall |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    #{baseline_rows}

    ## Policies

    | Policy | Utility | F1 | Recall | Usefulness | SNR | Hits | Noise | Comments | Avg Comments/PR | Critical/High Recall | Paired Win vs Current | Paired Win vs Raw |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    #{policy_rows}

    ## Decision

    #{decision_text(winner)}
    """
  end

  defp score_row(report, include_paired?) do
    score = report.score
    paired_current = if include_paired?, do: win_rate(report.paired_vs_current), else: ""
    paired_raw = if include_paired?, do: win_rate(report.paired_vs_raw_best), else: ""

    "| #{report.policy_id} | #{fmt(report.research_utility)} | #{fmt(score.f1)} | #{fmt(score.recall)} | #{fmt(score.usefulness)} | #{fmt(score.snr)} | #{score.hits} | #{score.noise} | #{score.published_claims} | #{fmt(score.avg_comments_per_pr)} | #{fmt(report.critical_high_recall)} | #{paired_current} | #{paired_raw} |"
  end

  defp win_rate(nil), do: ""
  defp win_rate(comparison), do: fmt(comparison.win_rate)

  defp decision_text(nil) do
    "No policy promoted. No policy cleared all raw-baseline guardrails."
  end

  defp decision_text(winner) do
    "Promote `#{winner.policy_id}` for the next locked public-smoke ranking check."
  end

  defp claims_path(run_dir, method_id, case_id),
    do: Path.join([run_dir, method_id, "claims", "#{case_id}.json"])

  defp reset_claim(claim) do
    claim
    |> Map.put(:publish_decision, "candidate")
    |> Map.delete(:suppressed_reason)
  end

  defp make_run_dir(id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(".sugary/research/runs", "#{timestamp}-#{id}")
  end

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)

  defp atomize(%{} = map),
    do: Map.new(map, fn {key, value} -> {atom_key(key), atomize(value)} end)

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value
  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default
  defp field(%{} = map, key, default), do: map[key] || map[to_string(key)] || default
  defp field(_other, _key, default), do: default
end

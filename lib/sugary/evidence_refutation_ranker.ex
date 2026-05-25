defmodule Sugary.EvidenceRefutationRanker do
  @attention_cost -0.1
  @version "evidence-refutation-ranker-v1"

  def tune_and_lock!(opts) do
    source_run = Keyword.fetch!(opts, :source_run)
    method_id = Keyword.fetch!(opts, :method_id)
    baseline_id = Keyword.get(opts, :baseline_id, "codex-gpt-5.5-xhigh")
    suite = Keyword.get(opts, :suite, "martian-offline")
    limit = Keyword.get(opts, :limit, 25)
    offset = Keyword.get(opts, :offset, 0)
    id = Keyword.get(opts, :id, "evidence-refutation-ranker-v1-dev")

    cases = Sugary.PublicBenchmarks.load_cases!(suite, limit: limit, offset: offset)
    out_dir = make_run_dir(id)
    File.mkdir_p!(out_dir)

    policy_reports =
      default_policy_grid()
      |> Enum.map(&score_policy(&1, source_run, method_id, cases))

    baseline_report = score_baseline(baseline_id, source_run, cases)

    policy_reports =
      Enum.map(policy_reports, fn report ->
        report
        |> Map.put(:paired_vs_raw_best, paired_comparison(report, baseline_report))
        |> then(&Map.put(&1, :promotion_guardrails, guardrails(&1, baseline_report)))
      end)

    winner = choose_winner(policy_reports)
    lock = lock_artifact(winner, source_run, method_id, baseline_id, suite, limit, offset)

    write_tuning_artifacts!(
      out_dir,
      source_run,
      method_id,
      baseline_id,
      suite,
      limit,
      offset,
      policy_reports,
      baseline_report,
      winner,
      lock
    )

    out_dir
  end

  def evaluate!(opts) do
    lock_path = Keyword.fetch!(opts, :lock_path)
    source_run = Keyword.fetch!(opts, :source_run)
    baseline_id = Keyword.get(opts, :baseline_id, "codex-gpt-5.5-xhigh")
    suite = Keyword.get(opts, :suite, "martian-offline")
    limit = Keyword.get(opts, :limit, 25)
    offset = Keyword.get(opts, :offset, 0)
    id = Keyword.get(opts, :id, "evidence-refutation-ranker-v1-eval")

    lock = Sugary.Json.read!(lock_path) |> atomize()
    policy = Map.fetch!(lock, :policy)
    method_id = Map.fetch!(lock, :method_id)
    cases = Sugary.PublicBenchmarks.load_cases!(suite, limit: limit, offset: offset)
    out_dir = make_run_dir(id)
    File.mkdir_p!(out_dir)

    policy_report = score_policy(policy, source_run, method_id, cases)
    baseline_report = score_baseline(baseline_id, source_run, cases)

    policy_report =
      policy_report
      |> Map.put(:paired_vs_raw_best, paired_comparison(policy_report, baseline_report))
      |> then(&Map.put(&1, :promotion_guardrails, guardrails(&1, baseline_report)))

    decision = evaluation_decision(policy_report, baseline_report)

    write_evaluation_artifacts!(
      out_dir,
      lock,
      lock_path,
      source_run,
      baseline_id,
      suite,
      limit,
      offset,
      policy_report,
      baseline_report,
      decision
    )

    out_dir
  end

  def aggregate!(opts) do
    evaluation_dirs = Keyword.fetch!(opts, :evaluation_dirs)
    id = Keyword.get(opts, :id, "evidence-refutation-ranker-v1-aggregate")
    out_dir = make_run_dir(id)
    File.mkdir_p!(out_dir)

    evaluations =
      Enum.map(evaluation_dirs, fn dir ->
        %{
          dir: dir,
          policy: Sugary.Json.read!(Path.join(dir, "policy-scorecard.json")) |> atomize(),
          baseline: Sugary.Json.read!(Path.join(dir, "baseline-scorecard.json")) |> atomize(),
          decision: Sugary.Json.read!(Path.join(dir, "decision.json")) |> atomize()
        }
      end)

    aggregate = aggregate_reports(evaluations)
    Sugary.Json.write!(Path.join(out_dir, "aggregate-scorecard.json"), aggregate)
    File.write!(Path.join(out_dir, "aggregate-report.md"), render_aggregate_report(aggregate))
    out_dir
  end

  def default_policy_grid do
    profiles = [
      %{
        id: "balanced",
        weights: %{
          confidence: 1.0,
          severity: 0.75,
          evidence_tier: 1.15,
          failure_path: 0.9,
          grounding: 1.0,
          introducedness: 0.75,
          agreement: 0.45,
          fix_test: 0.25,
          specificity: 0.35,
          static_proof: 0.35,
          refutation: 1.0
        }
      },
      %{
        id: "precision",
        weights: %{
          confidence: 0.9,
          severity: 0.65,
          evidence_tier: 1.35,
          failure_path: 1.05,
          grounding: 1.25,
          introducedness: 0.9,
          agreement: 0.55,
          fix_test: 0.3,
          specificity: 0.4,
          static_proof: 0.45,
          refutation: 1.35
        }
      },
      %{
        id: "recall_guarded",
        weights: %{
          confidence: 1.1,
          severity: 0.8,
          evidence_tier: 0.9,
          failure_path: 0.75,
          grounding: 0.8,
          introducedness: 0.65,
          agreement: 0.35,
          fix_test: 0.2,
          specificity: 0.25,
          static_proof: 0.25,
          refutation: 0.85
        }
      }
    ]

    for profile <- profiles,
        max_published <- [1, 2, 3],
        threshold <- [2.3, 2.7, 3.1, 3.5, 3.9] do
      %{
        id: "#{profile.id}-top#{max_published}-t#{threshold}",
        version: @version,
        profile: profile.id,
        max_published: max_published,
        threshold: threshold,
        weights: profile.weights
      }
    end
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

        final_claims = rank_and_publish(candidates, bench_case, policy)

        %{
          case: bench_case,
          reviewer_result: %{cost: 0.0, latency_ms: 0},
          candidate_claims: final_claims,
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
      unique_hits_over_baseline: 0,
      failure_analysis: failure_analysis(results),
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
          |> Enum.map(
            &Map.put(&1, :publish_decision, Map.get(&1, :publish_decision) || "publish")
          )

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
      bootstrap: bootstrap(per_case)
    }
  end

  defp rank_and_publish(candidates, bench_case, policy) do
    candidates
    |> Enum.map(&score_claim(&1, bench_case, policy))
    |> Enum.sort_by(&{Map.fetch!(&1, :publish_score), Map.get(&1, :confidence) || 0.0}, :desc)
    |> Enum.with_index()
    |> Enum.map(fn {claim, index} ->
      if index < policy.max_published and claim.publish_score >= policy.threshold do
        claim
        |> Map.put(:publish_decision, "publish")
        |> Map.delete(:suppressed_reason)
      else
        claim
        |> Map.put(:publish_decision, "suppress")
        |> Map.put(:suppressed_reason, "evidence_refutation_ranker")
      end
    end)
  end

  defp score_claim(claim, bench_case, policy) do
    features = ranker_features(claim, bench_case)
    weights = policy.weights

    positive =
      weights.confidence * features.confidence +
        weights.severity * features.severity +
        weights.evidence_tier * features.evidence_tier +
        weights.failure_path * features.failure_path +
        weights.grounding * features.grounding +
        weights.introducedness * features.introducedness +
        weights.agreement * features.agreement +
        weights.fix_test * features.fix_test +
        weights.specificity * features.specificity +
        weights.static_proof * features.static_proof

    refutation = weights.refutation * features.refutation
    publish_score = positive - refutation

    claim
    |> Map.put(:ranker_features, features)
    |> Map.put(:evidence_score, Float.round(positive, 4))
    |> Map.put(:refutation_score, Float.round(refutation, 4))
    |> Map.put(:publish_score, Float.round(publish_score, 4))
    |> Map.put(:ranker_reason, ranker_reason(features, publish_score, policy.threshold))
  end

  defp ranker_features(claim, bench_case) do
    evidence = Map.get(claim, :evidence, []) |> List.wrap()
    failure_path = Map.get(claim, :failure_path, []) |> List.wrap()
    summary_text = evidence |> Enum.map(&field(&1, :summary, "")) |> Enum.join(" ")

    %{
      confidence: clamp(Map.get(claim, :confidence) || 0.0),
      severity: severity_score(Map.get(claim, :severity)),
      evidence_tier: evidence_tier_score(evidence),
      failure_path: min(length(failure_path), 5) / 5,
      grounding: grounding_score(claim, bench_case),
      introducedness: introducedness_score(Map.get(claim, :introduced_by_pr)),
      agreement: min(agreement_count(claim), 3) / 3,
      fix_test: fix_test_score(claim),
      specificity: specificity_score([Map.get(claim, :claim), summary_text, failure_path]),
      static_proof: static_proof_score(claim),
      refutation: refutation_score(claim, bench_case)
    }
  end

  defp severity_score(severity) do
    %{"critical" => 1.0, "high" => 0.82, "medium" => 0.55, "low" => 0.2}
    |> Map.get(severity |> to_string() |> String.downcase(), 0.45)
  end

  defp evidence_tier_score(evidence) do
    tier =
      evidence
      |> Enum.map(&(field(&1, :tier, 5) |> int_value(5)))
      |> Enum.min(fn -> 5 end)

    (6 - tier) / 5
  end

  defp grounding_score(claim, bench_case) do
    path = Map.get(claim, :path) |> to_string()

    cond do
      path in ["", "unknown", "nil"] ->
        0.0

      changed_file?(path, bench_case) and line_known?(claim) ->
        1.0

      changed_file?(path, bench_case) ->
        0.85

      String.contains?(bench_case.diff || "", path) ->
        0.7

      line_known?(claim) ->
        0.45

      true ->
        0.25
    end
  end

  defp changed_file?(path, bench_case) do
    normalized = normalize_path(path)

    changed_files =
      bench_case.context
      |> field(:changed_files, [])
      |> List.wrap()
      |> Enum.map(&normalize_path/1)

    Enum.any?(changed_files, fn changed ->
      changed == normalized or String.ends_with?(changed, normalized) or
        String.ends_with?(normalized, changed)
    end)
  end

  defp line_known?(claim) do
    start_line = Map.get(claim, :start_line) || Map.get(claim, :line)
    is_integer(start_line) and start_line > 0
  end

  defp introducedness_score(true), do: 1.0
  defp introducedness_score(false), do: -1.0
  defp introducedness_score(_), do: 0.0

  defp fix_test_score(claim) do
    fix = present?(Map.get(claim, :suggested_fix))
    test = present?(Map.get(claim, :suggested_test))

    cond do
      fix and test -> 1.0
      fix or test -> 0.55
      true -> 0.0
    end
  end

  defp specificity_score(parts) do
    tokens =
      parts
      |> List.wrap()
      |> Enum.join(" ")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]+/, " ")
      |> String.split()
      |> Enum.reject(&(String.length(&1) < 4))
      |> Enum.uniq()
      |> length()

    min(tokens / 36, 1.0)
  end

  defp static_proof_score(claim) do
    source = Map.get(claim, :source, %{})
    evidence = Map.get(claim, :evidence, []) |> List.wrap()

    cond do
      field(source, :proof_gate, false) == true ->
        1.0

      Enum.any?(evidence, &(field(&1, :type, "") |> to_string() |> String.contains?("static"))) ->
        0.75

      true ->
        0.0
    end
  end

  defp refutation_score(claim, bench_case) do
    path = Map.get(claim, :path) |> to_string()
    text = claim_text(claim)

    [
      if(path in ["", "unknown", "nil"], do: 0.8, else: 0.0),
      if(not line_known?(claim), do: 0.25, else: 0.0),
      if(Map.get(claim, :introduced_by_pr) == false, do: 1.2, else: 0.0),
      if(Map.get(claim, :failure_path, []) in [nil, []], do: 0.45, else: 0.0),
      if(Map.get(claim, :evidence, []) in [nil, []], do: 0.85, else: 0.0),
      if(low_signal_category?(claim), do: 0.55, else: 0.0),
      speculative_penalty(text),
      preexisting_penalty(text),
      generated_vendor_penalty(path),
      if(changed_file?(path, bench_case), do: 0.0, else: 0.2)
    ]
    |> Enum.sum()
    |> min(3.0)
  end

  defp low_signal_category?(claim) do
    category = Map.get(claim, :category) |> to_string() |> String.downcase()
    severity = Map.get(claim, :severity) |> to_string() |> String.downcase()
    category in ["style", "nit", "maintainability"] or severity == "low"
  end

  defp speculative_penalty(text) do
    markers = ~w(might maybe could perhaps seems possibly unclear consider probably likely)

    count =
      text
      |> String.downcase()
      |> String.split(~r/[^a-z0-9_]+/, trim: true)
      |> Enum.count(&(&1 in markers))

    min(count * 0.18, 0.72)
  end

  defp preexisting_penalty(text) do
    if String.contains?(String.downcase(text), ["preexisting", "already existed", "unrelated"]) do
      0.75
    else
      0.0
    end
  end

  defp generated_vendor_penalty(path) do
    path = String.downcase(path)

    if String.contains?(path, ["/vendor/", "node_modules", ".generated.", "/generated/"]) do
      0.8
    else
      0.0
    end
  end

  defp claim_text(claim) do
    [
      Map.get(claim, :claim),
      Map.get(claim, :category),
      Map.get(claim, :failure_path) |> List.wrap() |> Enum.join(" "),
      claim
      |> Map.get(:evidence, [])
      |> List.wrap()
      |> Enum.map(&field(&1, :summary, ""))
      |> Enum.join(" ")
    ]
    |> Enum.join(" ")
  end

  defp ranker_reason(features, publish_score, threshold) do
    reasons =
      []
      |> maybe_reason(features.evidence_tier >= 0.6, "strong evidence tier")
      |> maybe_reason(features.failure_path >= 0.6, "specific failure path")
      |> maybe_reason(features.grounding >= 0.85, "grounded in changed file/line")
      |> maybe_reason(features.agreement >= 0.66, "multi-reviewer agreement")
      |> maybe_reason(features.refutation >= 0.8, "refutation penalties present")

    decision = if publish_score >= threshold, do: "above threshold", else: "below threshold"
    Enum.reverse([decision | reasons])
  end

  defp maybe_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_reason(reasons, false, _reason), do: reasons

  defp case_stats(result) do
    published = Enum.filter(result.final_claims, &(&1.publish_decision == "publish"))
    candidates = result.candidate_claims

    {hit_ids, noise_claim_ids} = hit_and_noise_ids(result.case, published)
    {candidate_hit_ids, _candidate_noise} = hit_and_noise_ids(result.case, candidates)

    %{
      case_id: result.case.id,
      expected: Sugary.ClaimMatcher.expected_ids(result.case) |> MapSet.size(),
      comments: length(published),
      hits: MapSet.size(hit_ids),
      hit_ids: Enum.sort(hit_ids),
      candidate_hit_ids: Enum.sort(candidate_hit_ids),
      suppressed_hit_ids: candidate_hit_ids |> MapSet.difference(hit_ids) |> Enum.sort(),
      noise: MapSet.size(noise_claim_ids),
      noise_claim_ids: Enum.sort(noise_claim_ids)
    }
  end

  defp hit_and_noise_ids(bench_case, claims) do
    Enum.reduce(claims, {MapSet.new(), MapSet.new()}, fn claim, {hits, noise} ->
      claim_id = Map.get(claim, :dedupe_key) || Map.get(claim, :id)

      case Sugary.ClaimMatcher.expected_claim(bench_case, claim) do
        nil ->
          {hits, MapSet.put(noise, claim_id)}

        expected ->
          expected_id = field(expected, :id)

          if MapSet.member?(hits, expected_id) do
            {hits, MapSet.put(noise, claim_id)}
          else
            {MapSet.put(hits, expected_id), noise}
          end
      end
    end)
  end

  defp research_utility(per_case) do
    Enum.reduce(per_case, 0.0, fn row, total ->
      total + row.hits - row.noise + row.comments * @attention_cost
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

  defp guardrails(report, baseline) do
    score = report.score
    baseline_score = baseline.score

    checks = %{
      beats_f1: score.f1 > baseline_score.f1,
      usefulness: score.usefulness >= baseline_score.usefulness,
      snr: score.snr >= baseline_score.snr,
      noise: score.noise <= baseline_score.noise,
      comments: score.avg_comments_per_pr <= baseline_score.avg_comments_per_pr,
      unique_true_positive: unique_hits(report, baseline) >= 1,
      paired_wins:
        report.paired_vs_raw_best == nil or
          report.paired_vs_raw_best.wins >= report.paired_vs_raw_best.losses
    }

    %{passes: Enum.all?(Map.values(checks)), checks: checks}
  end

  defp choose_winner(policy_reports) do
    promotable = Enum.filter(policy_reports, &(&1.promotion_guardrails.passes == true))
    pool = if promotable == [], do: policy_reports, else: promotable

    Enum.max_by(pool, fn report ->
      {
        report.promotion_guardrails.passes,
        report.research_utility,
        report.score.f1,
        report.score.snr
      }
    end)
  end

  defp evaluation_decision(policy_report, baseline_report) do
    guardrails = guardrails(policy_report, baseline_report)

    %{
      decision: if(guardrails.passes, do: "promote", else: "reject"),
      reason:
        if(guardrails.passes,
          do: "Locked ranker cleared all raw-baseline guardrails.",
          else: "Locked ranker failed one or more raw-baseline guardrails."
        ),
      guardrails: guardrails.checks,
      unique_hits_over_baseline: unique_hits(policy_report, baseline_report),
      paired_vs_raw_best: policy_report.paired_vs_raw_best
    }
  end

  defp unique_hits(report, baseline) do
    baseline_by_case = Map.new(baseline.per_case, &{&1.case_id, MapSet.new(&1.hit_ids)})

    report.per_case
    |> Enum.reduce(MapSet.new(), fn row, acc ->
      baseline_hits = Map.get(baseline_by_case, row.case_id, MapSet.new())

      row.hit_ids
      |> MapSet.new()
      |> MapSet.difference(baseline_hits)
      |> Enum.reduce(acc, &MapSet.put(&2, "#{row.case_id}:#{&1}"))
    end)
    |> MapSet.size()
  end

  defp failure_analysis(results) do
    admitted_false_positives =
      results
      |> Enum.flat_map(fn result ->
        result.final_claims
        |> Enum.filter(&(&1.publish_decision == "publish"))
        |> Enum.reject(&Sugary.ClaimMatcher.expected_claim(result.case, &1))
        |> Enum.map(&failure_claim_record(result.case.id, &1, "admitted_false_positive"))
      end)

    suppressed_true_positives =
      results
      |> Enum.flat_map(fn result ->
        result.final_claims
        |> Enum.filter(&(&1.publish_decision != "publish"))
        |> Enum.filter(&Sugary.ClaimMatcher.expected_claim(result.case, &1))
        |> Enum.map(&failure_claim_record(result.case.id, &1, "suppressed_true_positive"))
      end)

    %{
      admitted_false_positives: admitted_false_positives,
      suppressed_true_positives: suppressed_true_positives,
      summary: %{
        admitted_false_positives: length(admitted_false_positives),
        suppressed_true_positives: length(suppressed_true_positives),
        average_false_positive_score: average_score(admitted_false_positives),
        average_suppressed_true_score: average_score(suppressed_true_positives)
      }
    }
  end

  defp failure_claim_record(case_id, claim, type) do
    %{
      case_id: case_id,
      type: type,
      claim_id: Map.get(claim, :id),
      dedupe_key: Map.get(claim, :dedupe_key),
      summary: Map.get(claim, :claim),
      publish_score: Map.get(claim, :publish_score),
      evidence_score: Map.get(claim, :evidence_score),
      refutation_score: Map.get(claim, :refutation_score),
      ranker_reason: Map.get(claim, :ranker_reason),
      features: Map.get(claim, :ranker_features)
    }
  end

  defp average_score([]), do: 0.0

  defp average_score(records) do
    records
    |> Enum.map(&(Map.get(&1, :publish_score) || 0.0))
    |> Enum.sum()
    |> Kernel./(length(records))
  end

  defp bootstrap(per_case) do
    :rand.seed(:exsplus, {211, 212, 213})

    samples =
      for _ <- 1..200 do
        rows = for _ <- per_case, do: Enum.random(per_case)
        aggregate_rows(rows)
      end

    %{
      f1: interval(samples, :f1),
      usefulness: interval(samples, :usefulness),
      snr: interval(samples, :snr),
      recall: interval(samples, :recall)
    }
  end

  defp aggregate_rows(rows) do
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

  defp lock_artifact(winner, source_run, method_id, baseline_id, suite, limit, offset) do
    %{
      version: @version,
      locked_at: timestamp(),
      git_sha: git_sha(),
      source_run: source_run,
      method_id: method_id,
      baseline_id: baseline_id,
      suite: suite,
      dev_limit: limit,
      dev_offset: offset,
      no_tune_slices: [%{suite: suite, offset: 25, limit: 75}],
      policy: winner.policy,
      dev_decision:
        if(winner.promotion_guardrails.passes,
          do: "promoted_on_dev_for_fresh_check",
          else: "best_available_policy_failed_dev_guardrails"
        )
    }
  end

  defp write_tuning_artifacts!(
         out_dir,
         source_run,
         method_id,
         baseline_id,
         suite,
         limit,
         offset,
         policy_reports,
         baseline_report,
         winner,
         lock
       ) do
    Sugary.Json.write!(Path.join(out_dir, "ranker-lock.json"), lock)

    Sugary.Json.write!(Path.join(out_dir, "tuning-config.json"), %{
      source_run: source_run,
      method_id: method_id,
      baseline_id: baseline_id,
      suite: suite,
      limit: limit,
      offset: offset,
      version: @version
    })

    Sugary.Json.write!(
      Path.join(out_dir, "policy-scorecards.json"),
      Enum.map(policy_reports, &json_report/1)
    )

    Sugary.Json.write!(
      Path.join(out_dir, "baseline-scorecard.json"),
      json_report(baseline_report)
    )

    Sugary.Json.write!(Path.join(out_dir, "decision.json"), tuning_decision(winner))
    Sugary.Json.write!(Path.join(out_dir, "failure-analysis.json"), winner.failure_analysis)

    File.write!(
      Path.join(out_dir, "report.md"),
      render_tuning_report(policy_reports, baseline_report, winner, suite, limit, offset)
    )
  end

  defp write_evaluation_artifacts!(
         out_dir,
         lock,
         lock_path,
         source_run,
         baseline_id,
         suite,
         limit,
         offset,
         policy_report,
         baseline_report,
         decision
       ) do
    Sugary.Json.write!(Path.join(out_dir, "ranker-lock.json"), lock)

    Sugary.Json.write!(Path.join(out_dir, "evaluation-config.json"), %{
      lock_path: lock_path,
      source_run: source_run,
      baseline_id: baseline_id,
      suite: suite,
      limit: limit,
      offset: offset,
      version: @version
    })

    Sugary.Json.write!(Path.join(out_dir, "policy-scorecard.json"), json_report(policy_report))

    Sugary.Json.write!(
      Path.join(out_dir, "baseline-scorecard.json"),
      json_report(baseline_report)
    )

    Sugary.Json.write!(
      Path.join(out_dir, "failure-analysis.json"),
      policy_report.failure_analysis
    )

    Sugary.Json.write!(Path.join(out_dir, "decision.json"), decision)

    File.write!(
      Path.join(out_dir, "report.md"),
      render_evaluation_report(policy_report, baseline_report, decision, suite, limit, offset)
    )
  end

  defp json_report(report) do
    report
    |> Map.update!(:score, &Map.from_struct/1)
  end

  defp tuning_decision(winner) do
    %{
      decision:
        if(winner.promotion_guardrails.passes,
          do: "lock_for_fresh_evaluation",
          else: "lock_best_available_for_fresh_evaluation"
        ),
      policy_id: winner.policy_id,
      guardrails: winner.promotion_guardrails.checks,
      research_utility: winner.research_utility
    }
  end

  defp aggregate_reports(evaluations) do
    policy_rows = Enum.flat_map(evaluations, & &1.policy.per_case)
    baseline_rows = Enum.flat_map(evaluations, & &1.baseline.per_case)
    policy_score = rows_to_score("evidence-refutation-ranker-v1", policy_rows)
    baseline_score = rows_to_score("codex-gpt-5.5-xhigh", baseline_rows)

    policy_report = %{
      policy_id: "evidence-refutation-ranker-v1",
      score: policy_score,
      per_case: policy_rows
    }

    baseline_report = %{
      policy_id: "codex-gpt-5.5-xhigh",
      score: baseline_score,
      per_case: baseline_rows
    }

    paired = paired_comparison(policy_report, baseline_report)
    unique = unique_hits(policy_report, baseline_report)

    guardrails = %{
      beats_f1: policy_score.f1 > baseline_score.f1,
      usefulness: policy_score.usefulness >= baseline_score.usefulness,
      snr: policy_score.snr >= baseline_score.snr,
      noise: policy_score.noise <= baseline_score.noise,
      comments: policy_score.avg_comments_per_pr <= baseline_score.avg_comments_per_pr,
      unique_true_positives: unique >= 2,
      paired_wins: paired.wins > paired.losses
    }

    %{
      version: @version,
      evaluations: Enum.map(evaluations, &Map.take(&1, [:dir, :decision])),
      policy_score: Map.from_struct(policy_score),
      baseline_score: Map.from_struct(baseline_score),
      paired_vs_raw_best: paired,
      unique_hits_over_baseline: unique,
      guardrails: guardrails,
      decision:
        if(Enum.all?(Map.values(guardrails)),
          do: "stretch_target_met",
          else: "stretch_target_failed"
        )
    }
  end

  defp rows_to_score(method_id, rows) do
    totals =
      Enum.reduce(
        rows,
        %{cases: 0, expected_claims: 0, published_claims: 0, hits: 0, noise: 0},
        fn row, acc ->
          %{
            cases: acc.cases + 1,
            expected_claims: acc.expected_claims + row.expected,
            published_claims: acc.published_claims + row.comments,
            hits: acc.hits + row.hits,
            noise: acc.noise + row.noise
          }
        end
      )

    precision = ratio(totals.hits, totals.published_claims)
    recall = ratio(totals.hits, totals.expected_claims)

    Sugary.Protocol.Scorecard.new(%{
      method_id: method_id,
      cases: totals.cases,
      expected_claims: totals.expected_claims,
      published_claims: totals.published_claims,
      hits: totals.hits,
      valid_suggestions: 0,
      noise: totals.noise,
      suppressed_true_claims: 0,
      precision: precision,
      recall: recall,
      f1:
        if(precision + recall == 0, do: 0.0, else: 2 * precision * recall / (precision + recall)),
      usefulness: precision,
      snr: if(totals.noise == 0, do: totals.hits * 1.0, else: totals.hits / totals.noise),
      avg_comments_per_pr: ratio(totals.published_claims, max(totals.cases, 1)),
      cost: 0.0,
      latency_ms: 0
    })
  end

  defp render_tuning_report(policy_reports, baseline_report, winner, suite, limit, offset) do
    rows =
      policy_reports
      |> Enum.sort_by(& &1.research_utility, :desc)
      |> Enum.map(&score_row/1)
      |> Enum.join("\n")

    """
    # Evidence/Refutation Ranker v1 Tuning

    Unofficial local smoke run. Not an official benchmark score.

    ## Scope

    - Suite: `#{suite}`
    - Offset: #{offset}
    - Limit: #{limit}
    - Tuning source: existing dev artifacts only.
    - Baseline: `#{baseline_report.policy_id}`

    ## Baseline

    #{summary_line(baseline_report)}

    ## Policies

    | Policy | Utility | F1 | Recall | Usefulness | SNR | Hits | Noise | Comments | Avg Comments/PR | Guardrails |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
    #{rows}

    ## Decision

    Locked `#{winner.policy_id}` for fresh evaluation.
    """
  end

  defp render_evaluation_report(policy_report, baseline_report, decision, suite, limit, offset) do
    """
    # Evidence/Refutation Ranker v1 Evaluation

    Unofficial local smoke run. Not an official benchmark score.

    ## Scope

    - Suite: `#{suite}`
    - Offset: #{offset}
    - Limit: #{limit}
    - Policy: `#{policy_report.policy_id}`
    - Baseline: `#{baseline_report.policy_id}`

    ## Result

    | Method | F1 | Recall | Usefulness | SNR | Hits | Noise | Comments | Avg Comments/PR | Utility |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    | `#{baseline_report.policy_id}` | #{fmt(baseline_report.score.f1)} | #{fmt(baseline_report.score.recall)} | #{fmt(baseline_report.score.usefulness)} | #{fmt(baseline_report.score.snr)} | #{baseline_report.score.hits} | #{baseline_report.score.noise} | #{baseline_report.score.published_claims} | #{fmt(baseline_report.score.avg_comments_per_pr)} | #{fmt(baseline_report.research_utility)} |
    | `#{policy_report.policy_id}` | #{fmt(policy_report.score.f1)} | #{fmt(policy_report.score.recall)} | #{fmt(policy_report.score.usefulness)} | #{fmt(policy_report.score.snr)} | #{policy_report.score.hits} | #{policy_report.score.noise} | #{policy_report.score.published_claims} | #{fmt(policy_report.score.avg_comments_per_pr)} | #{fmt(policy_report.research_utility)} |

    ## Decision

    #{decision.decision}: #{decision.reason}

    Unique true positives over baseline: #{decision.unique_hits_over_baseline}
    Paired wins/losses/ties: #{decision.paired_vs_raw_best.wins}/#{decision.paired_vs_raw_best.losses}/#{decision.paired_vs_raw_best.ties}
    """
  end

  defp render_aggregate_report(aggregate) do
    policy = aggregate.policy_score
    baseline = aggregate.baseline_score
    paired = aggregate.paired_vs_raw_best

    """
    # Evidence/Refutation Ranker v1 Aggregate

    Unofficial local smoke run. Not an official benchmark score.

    ## Result

    | Method | F1 | Recall | Usefulness | SNR | Hits | Noise | Comments | Avg Comments/PR |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    | `codex-gpt-5.5-xhigh` | #{fmt(baseline.f1)} | #{fmt(baseline.recall)} | #{fmt(baseline.usefulness)} | #{fmt(baseline.snr)} | #{baseline.hits} | #{baseline.noise} | #{baseline.published_claims} | #{fmt(baseline.avg_comments_per_pr)} |
    | `evidence-refutation-ranker-v1` | #{fmt(policy.f1)} | #{fmt(policy.recall)} | #{fmt(policy.usefulness)} | #{fmt(policy.snr)} | #{policy.hits} | #{policy.noise} | #{policy.published_claims} | #{fmt(policy.avg_comments_per_pr)} |

    ## Stretch Target

    Decision: `#{aggregate.decision}`

    Unique true positives over baseline: #{aggregate.unique_hits_over_baseline}
    Paired wins/losses/ties: #{paired.wins}/#{paired.losses}/#{paired.ties}
    """
  end

  defp summary_line(report) do
    score = report.score

    "`#{report.policy_id}`: F1 #{fmt(score.f1)}, usefulness #{fmt(score.usefulness)}, SNR #{fmt(score.snr)}, hits #{score.hits}, noise #{score.noise}, avg comments/PR #{fmt(score.avg_comments_per_pr)}."
  end

  defp score_row(report) do
    score = report.score

    "| #{report.policy_id} | #{fmt(report.research_utility)} | #{fmt(score.f1)} | #{fmt(score.recall)} | #{fmt(score.usefulness)} | #{fmt(score.snr)} | #{score.hits} | #{score.noise} | #{score.published_claims} | #{fmt(score.avg_comments_per_pr)} | #{report.promotion_guardrails.passes} |"
  end

  defp claims_path(run_dir, method_id, case_id),
    do: Path.join([run_dir, method_id, "claims", "#{case_id}.json"])

  defp reset_claim(claim) do
    claim
    |> Map.put(:publish_decision, "candidate")
    |> Map.delete(:suppressed_reason)
  end

  defp make_run_dir(id) do
    Path.join(".sugary/research/runs", "#{timestamp()}-#{id}")
  end

  defp timestamp, do: DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den
  defp clamp(value), do: value |> max(0.0) |> min(1.0)

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)

  defp normalize_path(path), do: path |> to_string() |> String.downcase() |> String.trim()
  defp present?(value), do: value |> to_string() |> String.trim() |> Kernel.!=("")

  defp agreement_count(claim),
    do: field(Map.get(claim, :source, %{}), :agreement_count, 1) |> int_value(1)

  defp int_value(value, _default) when is_integer(value), do: value

  defp int_value(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {parsed, _rest} -> parsed
      :error -> default
    end
  end

  defp int_value(_value, default), do: default

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default
  defp field(%{} = map, key, default), do: map[key] || map[to_string(key)] || default
  defp field(_other, _key, default), do: default

  defp atomize(%{} = map),
    do: Map.new(map, fn {key, value} -> {atom_key(key), atomize(value)} end)

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value
  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)
end

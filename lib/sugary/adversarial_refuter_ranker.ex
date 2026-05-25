defmodule Sugary.AdversarialRefuterRanker do
  @version "adversarial-refuter-ranker-v1"
  @attention_cost -0.1

  def tune_and_lock!(opts) do
    source_run = Keyword.fetch!(opts, :source_run)
    method_id = Keyword.fetch!(opts, :method_id)
    baseline_id = Keyword.get(opts, :baseline_id, "codex-gpt-5.5-xhigh")
    refuter_ids = Keyword.get(opts, :refuter_ids, [baseline_id])
    suite = Keyword.get(opts, :suite, "martian-offline")
    limit = Keyword.get(opts, :limit, 25)
    offset = Keyword.get(opts, :offset, 0)
    id = Keyword.get(opts, :id, "adversarial-refuter-ranker-v1-dev")

    cases = Sugary.PublicBenchmarks.load_cases!(suite, limit: limit, offset: offset)
    out_dir = make_run_dir(id)
    File.mkdir_p!(out_dir)

    baseline = score_baseline(baseline_id, source_run, cases)

    reports =
      default_policy_grid()
      |> Enum.map(&score_policy(&1, source_run, method_id, refuter_ids, cases))
      |> Enum.map(fn report ->
        report
        |> Map.put(:paired_vs_raw_best, paired_comparison(report, baseline))
        |> then(&Map.put(&1, :promotion_guardrails, guardrails(&1, baseline)))
      end)

    winner = choose_winner(reports, baseline)

    lock =
      lock_artifact(winner, source_run, method_id, baseline_id, refuter_ids, suite, limit, offset)

    write_tuning_artifacts!(
      out_dir,
      source_run,
      method_id,
      baseline_id,
      refuter_ids,
      suite,
      limit,
      offset,
      reports,
      baseline,
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
    id = Keyword.get(opts, :id, "adversarial-refuter-ranker-v1-eval")

    lock = Sugary.Json.read!(lock_path) |> atomize()
    method_id = Map.fetch!(lock, :method_id)
    refuter_ids = Map.fetch!(lock, :refuter_ids)
    policy = Map.fetch!(lock, :policy)
    cases = Sugary.PublicBenchmarks.load_cases!(suite, limit: limit, offset: offset)
    out_dir = make_run_dir(id)
    File.mkdir_p!(out_dir)

    baseline = score_baseline(baseline_id, source_run, cases)

    report =
      policy
      |> score_policy(source_run, method_id, refuter_ids, cases)
      |> Map.put(:paired_vs_raw_best, nil)
      |> then(fn report ->
        report
        |> Map.put(:paired_vs_raw_best, paired_comparison(report, baseline))
        |> then(&Map.put(&1, :promotion_guardrails, guardrails(&1, baseline)))
      end)

    decision = evaluation_decision(report, baseline)

    write_evaluation_artifacts!(
      out_dir,
      lock,
      lock_path,
      source_run,
      baseline_id,
      suite,
      limit,
      offset,
      report,
      baseline,
      decision
    )

    out_dir
  end

  def default_policy_grid do
    profiles = [
      %{
        id: "refuter_precision",
        weights: %{
          confidence: 0.9,
          severity: 0.55,
          evidence_tier: 1.0,
          failure_path: 0.75,
          grounding: 0.9,
          introducedness: 0.7,
          agreement: 0.3,
          fix_test: 0.2,
          specificity: 0.25,
          static_proof: 0.45,
          independent_support: 0.8,
          counterargument: 1.35
        },
        false_positive_cost: 3.0
      },
      %{
        id: "refuter_balanced",
        weights: %{
          confidence: 1.0,
          severity: 0.7,
          evidence_tier: 0.9,
          failure_path: 0.8,
          grounding: 0.85,
          introducedness: 0.65,
          agreement: 0.35,
          fix_test: 0.2,
          specificity: 0.25,
          static_proof: 0.35,
          independent_support: 0.55,
          counterargument: 1.0
        },
        false_positive_cost: 2.4
      },
      %{
        id: "refuter_unique_guarded",
        weights: %{
          confidence: 1.05,
          severity: 0.75,
          evidence_tier: 0.8,
          failure_path: 0.7,
          grounding: 0.8,
          introducedness: 0.6,
          agreement: 0.25,
          fix_test: 0.15,
          specificity: 0.2,
          static_proof: 0.25,
          independent_support: 0.3,
          counterargument: 0.8
        },
        false_positive_cost: 2.1
      }
    ]

    for profile <- profiles,
        max_published <- [1, 2],
        threshold <- [2.4, 2.8, 3.2, 3.6, 4.0] do
      %{
        id: "#{profile.id}-top#{max_published}-t#{threshold}",
        version: @version,
        profile: profile.id,
        max_published: max_published,
        threshold: threshold,
        weights: profile.weights,
        false_positive_cost: profile.false_positive_cost
      }
    end
  end

  defp score_policy(policy, source_run, method_id, refuter_ids, cases) do
    results =
      Enum.map(cases, fn bench_case ->
        candidates = load_claims(source_run, method_id, bench_case.id) |> Enum.map(&reset_claim/1)
        refuter_claims = Enum.flat_map(refuter_ids, &load_claims(source_run, &1, bench_case.id))
        final_claims = rank_and_publish(candidates, refuter_claims, bench_case, policy)

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
      score: score,
      per_case: per_case,
      research_utility: research_utility(per_case, policy.false_positive_cost),
      failure_analysis: failure_analysis(results)
    }
  end

  defp score_baseline(method_id, source_run, cases) do
    results =
      Enum.map(cases, fn bench_case ->
        claims =
          source_run
          |> load_claims(method_id, bench_case.id)
          |> Enum.map(
            &Map.put(&1, :publish_decision, Map.get(&1, :publish_decision) || "publish")
          )

        %{
          case: bench_case,
          reviewer_result: %{cost: 0.0, latency_ms: 0},
          candidate_claims: claims,
          final_claims: claims
        }
      end)

    score = Sugary.Scorer.score(method_id, results)
    per_case = Enum.map(results, &case_stats/1)

    %{
      policy_id: method_id,
      score: score,
      per_case: per_case,
      research_utility: research_utility(per_case, 1.0)
    }
  end

  defp rank_and_publish(candidates, refuter_claims, bench_case, policy) do
    candidates
    |> Enum.map(&score_claim(&1, refuter_claims, bench_case, policy))
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
        |> Map.put(:suppressed_reason, "adversarial_refuter_ranker")
      end
    end)
  end

  defp score_claim(claim, refuter_claims, bench_case, policy) do
    support = independent_support(claim, refuter_claims)
    counterarguments = counterarguments(claim, support, bench_case)
    features = ranker_features(claim, support, counterarguments, bench_case)
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
        weights.static_proof * features.static_proof +
        weights.independent_support * features.independent_support

    refutation = weights.counterargument * features.counterargument
    publish_score = positive - refutation

    claim
    |> Map.put(:counterarguments, counterarguments)
    |> Map.put(:independent_support, support)
    |> Map.put(:ranker_features, features)
    |> Map.put(:evidence_score, Float.round(positive, 4))
    |> Map.put(:refutation_score, Float.round(refutation, 4))
    |> Map.put(:publish_score, Float.round(publish_score, 4))
    |> Map.put(:ranker_reason, ranker_reason(counterarguments, publish_score, policy.threshold))
  end

  defp independent_support(claim, refuter_claims) do
    matches =
      refuter_claims
      |> Enum.map(&{&1, claim_similarity(claim, &1)})
      |> Enum.filter(fn {_claim, score} -> score >= 0.42 end)
      |> Enum.sort_by(fn {_claim, score} -> score end, :desc)

    %{
      supported: matches != [],
      support_count: length(matches),
      max_similarity: matches |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0.0 end),
      supporting_claim_ids: Enum.map(matches, fn {claim, _score} -> Map.get(claim, :id) end)
    }
  end

  defp claim_similarity(left, right) do
    path_bonus =
      if same_path?(Map.get(left, :path), Map.get(right, :path)), do: 0.35, else: 0.0

    token_score =
      left
      |> claim_tokens()
      |> jaccard(claim_tokens(right))

    min(path_bonus + token_score, 1.0)
  end

  defp counterarguments(claim, support, bench_case) do
    text = claim_text(claim)
    path = Map.get(claim, :path) |> to_string()
    source = Map.get(claim, :source, %{})
    evidence = Map.get(claim, :evidence, []) |> List.wrap()

    []
    |> maybe_counter(
      not support.supported and field(source, :proof_gate, false) != true,
      "missing_independent_support",
      "No independent refuter/reviewer produced a similar claim.",
      0.75
    )
    |> maybe_counter(
      agreement_count(claim) <= 1 and field(source, :proof_gate, false) != true,
      "single_source_claim",
      "Only one source supports this claim.",
      0.35
    )
    |> maybe_counter(
      strongest_evidence_tier(evidence) >= 4 and field(source, :proof_gate, false) != true,
      "weak_evidence_tier",
      "The claim relies on heuristic or non-executable evidence.",
      0.45
    )
    |> maybe_counter(
      Map.get(claim, :failure_path, []) in [nil, []],
      "missing_failure_path",
      "The claim does not provide a concrete failure path.",
      0.65
    )
    |> maybe_counter(
      path in ["", "unknown", "nil"],
      "missing_location",
      "The claim is not tied to a specific source path.",
      0.85
    )
    |> maybe_counter(
      not changed_file?(path, bench_case),
      "outside_changed_files",
      "The claim location is not listed as a changed file in the sanitized bundle.",
      0.25
    )
    |> maybe_counter(
      speculative?(text),
      "speculative_language",
      "The claim uses speculative language instead of a demonstrated failure.",
      0.5
    )
    |> maybe_counter(
      low_signal_category?(claim),
      "low_signal_category",
      "The claim is low severity or style-oriented.",
      0.55
    )
    |> maybe_counter(
      generated_vendor_path?(path),
      "generated_or_vendor_path",
      "The path appears generated or vendored.",
      0.8
    )
  end

  defp maybe_counter(counters, true, id, summary, strength),
    do: [%{id: id, summary: summary, strength: strength} | counters]

  defp maybe_counter(counters, false, _id, _summary, _strength), do: counters

  defp ranker_features(claim, support, counterarguments, bench_case) do
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
      independent_support: independent_support_score(support),
      counterargument: counterargument_score(counterarguments)
    }
  end

  defp independent_support_score(%{supported: false}), do: 0.0

  defp independent_support_score(support),
    do: min(0.4 + support.max_similarity + support.support_count * 0.15, 1.0)

  defp counterargument_score(counterarguments) do
    counterarguments
    |> Enum.map(&Map.fetch!(&1, :strength))
    |> Enum.sum()
    |> min(3.0)
    |> Kernel./(3.0)
  end

  defp severity_score(severity) do
    %{"critical" => 1.0, "high" => 0.82, "medium" => 0.55, "low" => 0.2}
    |> Map.get(severity |> to_string() |> String.downcase(), 0.45)
  end

  defp evidence_tier_score(evidence) do
    tier = evidence |> Enum.map(&(field(&1, :tier, 5) |> int_value(5))) |> Enum.min(fn -> 5 end)
    (6 - tier) / 5
  end

  defp grounding_score(claim, bench_case) do
    path = Map.get(claim, :path) |> to_string()

    cond do
      path in ["", "unknown", "nil"] -> 0.0
      changed_file?(path, bench_case) and line_known?(claim) -> 1.0
      changed_file?(path, bench_case) -> 0.85
      String.contains?(bench_case.diff || "", path) -> 0.7
      line_known?(claim) -> 0.45
      true -> 0.25
    end
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

  defp strongest_evidence_tier(evidence) do
    evidence
    |> Enum.map(&(field(&1, :tier, 5) |> int_value(5)))
    |> Enum.min(fn -> 5 end)
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

  defp low_signal_category?(claim) do
    category = Map.get(claim, :category) |> to_string() |> String.downcase()
    severity = Map.get(claim, :severity) |> to_string() |> String.downcase()
    category in ["style", "nit", "maintainability"] or severity == "low"
  end

  defp speculative?(text) do
    markers = ~w(might maybe could perhaps seems possibly unclear consider probably likely)
    tokens = text |> String.downcase() |> String.split(~r/[^a-z0-9_]+/, trim: true)
    Enum.any?(tokens, &(&1 in markers))
  end

  defp generated_vendor_path?(path) do
    path = String.downcase(path)
    String.contains?(path, ["/vendor/", "node_modules", ".generated.", "/generated/"])
  end

  defp case_stats(result) do
    published = Enum.filter(result.final_claims, &(&1.publish_decision == "publish"))
    {hit_ids, noise_claim_ids} = hit_and_noise_ids(result.case, published)

    {candidate_hit_ids, _candidate_noise} =
      hit_and_noise_ids(result.case, result.candidate_claims)

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

  defp research_utility(per_case, false_positive_cost) do
    Enum.reduce(per_case, 0.0, fn row, total ->
      total + row.hits - row.noise * false_positive_cost + row.comments * @attention_cost
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
      usefulness: score.usefulness >= baseline_score.usefulness,
      snr: score.snr >= baseline_score.snr,
      noise: score.noise <= baseline_score.noise,
      comments: score.avg_comments_per_pr <= baseline_score.avg_comments_per_pr,
      unique_true_positive: unique_hits(report, baseline) >= 1,
      f1_floor: score.f1 >= baseline_score.f1 * 0.75,
      paired_wins: report.paired_vs_raw_best.wins >= report.paired_vs_raw_best.losses
    }

    %{passes: Enum.all?(Map.values(checks)), checks: checks}
  end

  defp choose_winner(reports, baseline) do
    promotable = Enum.filter(reports, & &1.promotion_guardrails.passes)
    pool = if promotable == [], do: reports, else: promotable

    Enum.max_by(pool, fn report ->
      {
        report.promotion_guardrails.passes,
        report.research_utility,
        unique_hits(report, baseline),
        report.score.f1
      }
    end)
  end

  defp evaluation_decision(report, baseline) do
    guardrails = guardrails(report, baseline)

    %{
      decision: if(guardrails.passes, do: "promote", else: "reject"),
      reason:
        if(guardrails.passes,
          do: "Locked adversarial refuter cleared precision-first guardrails.",
          else: "Locked adversarial refuter failed one or more precision-first guardrails."
        ),
      guardrails: guardrails.checks,
      unique_hits_over_baseline: unique_hits(report, baseline),
      paired_vs_raw_best: report.paired_vs_raw_best
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
      counterarguments: Map.get(claim, :counterarguments, []),
      independent_support: Map.get(claim, :independent_support),
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

  defp lock_artifact(
         winner,
         source_run,
         method_id,
         baseline_id,
         refuter_ids,
         suite,
         limit,
         offset
       ) do
    %{
      version: @version,
      locked_at: timestamp(),
      git_sha: git_sha(),
      source_run: source_run,
      method_id: method_id,
      baseline_id: baseline_id,
      refuter_ids: refuter_ids,
      suite: suite,
      dev_limit: limit,
      dev_offset: offset,
      policy: winner.policy,
      dev_decision:
        if(winner.promotion_guardrails.passes,
          do: "promoted_on_dev_for_holdout_check",
          else: "best_available_policy_failed_dev_guardrails"
        )
    }
  end

  defp write_tuning_artifacts!(
         out_dir,
         source_run,
         method_id,
         baseline_id,
         refuter_ids,
         suite,
         limit,
         offset,
         reports,
         baseline,
         winner,
         lock
       ) do
    Sugary.Json.write!(Path.join(out_dir, "refuter-lock.json"), lock)

    Sugary.Json.write!(Path.join(out_dir, "tuning-config.json"), %{
      source_run: source_run,
      method_id: method_id,
      baseline_id: baseline_id,
      refuter_ids: refuter_ids,
      suite: suite,
      limit: limit,
      offset: offset,
      version: @version
    })

    Sugary.Json.write!(
      Path.join(out_dir, "policy-scorecards.json"),
      Enum.map(reports, &json_report/1)
    )

    Sugary.Json.write!(Path.join(out_dir, "baseline-scorecard.json"), json_report(baseline))
    Sugary.Json.write!(Path.join(out_dir, "failure-analysis.json"), winner.failure_analysis)
    Sugary.Json.write!(Path.join(out_dir, "decision.json"), decision(winner, baseline))

    File.write!(
      Path.join(out_dir, "report.md"),
      render_tuning_report(reports, baseline, winner, suite, limit, offset)
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
         report,
         baseline,
         decision
       ) do
    Sugary.Json.write!(Path.join(out_dir, "refuter-lock.json"), lock)

    Sugary.Json.write!(Path.join(out_dir, "evaluation-config.json"), %{
      lock_path: lock_path,
      source_run: source_run,
      baseline_id: baseline_id,
      suite: suite,
      limit: limit,
      offset: offset,
      version: @version
    })

    Sugary.Json.write!(Path.join(out_dir, "policy-scorecard.json"), json_report(report))
    Sugary.Json.write!(Path.join(out_dir, "baseline-scorecard.json"), json_report(baseline))
    Sugary.Json.write!(Path.join(out_dir, "failure-analysis.json"), report.failure_analysis)
    Sugary.Json.write!(Path.join(out_dir, "decision.json"), decision)

    File.write!(
      Path.join(out_dir, "report.md"),
      render_evaluation_report(report, baseline, decision, suite, limit, offset)
    )
  end

  defp json_report(report), do: Map.update!(report, :score, &Map.from_struct/1)

  defp decision(winner, baseline) do
    %{
      decision:
        if(winner.promotion_guardrails.passes,
          do: "lock_for_holdout_evaluation",
          else: "lock_best_available_for_holdout_evaluation"
        ),
      policy_id: winner.policy_id,
      guardrails: winner.promotion_guardrails.checks,
      research_utility: winner.research_utility,
      unique_hits_over_baseline: unique_hits(winner, baseline)
    }
  end

  defp render_tuning_report(reports, baseline, winner, suite, limit, offset) do
    rows =
      reports
      |> Enum.sort_by(& &1.research_utility, :desc)
      |> Enum.map(&score_row/1)
      |> Enum.join("\n")

    """
    # Adversarial Refuter Ranker v1 Tuning

    Unofficial local smoke run. Not an official benchmark score.

    ## Scope

    - Suite: `#{suite}`
    - Offset: #{offset}
    - Limit: #{limit}
    - Tuning source: existing dev artifacts only.
    - Baseline/refuter: `#{baseline.policy_id}`

    ## Baseline

    #{summary_line(baseline)}

    ## Policies

    | Policy | Utility | F1 | Recall | Usefulness | SNR | Hits | Noise | Comments | Avg Comments/PR | Guardrails |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
    #{rows}

    ## Decision

    Locked `#{winner.policy_id}` for holdout evaluation.
    """
  end

  defp render_evaluation_report(report, baseline, decision, suite, limit, offset) do
    """
    # Adversarial Refuter Ranker v1 Evaluation

    Unofficial local smoke run. Not an official benchmark score.

    ## Scope

    - Suite: `#{suite}`
    - Offset: #{offset}
    - Limit: #{limit}
    - Policy: `#{report.policy_id}`
    - Baseline/refuter: `#{baseline.policy_id}`

    ## Result

    | Method | F1 | Recall | Usefulness | SNR | Hits | Noise | Comments | Avg Comments/PR | Utility |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    | `#{baseline.policy_id}` | #{fmt(baseline.score.f1)} | #{fmt(baseline.score.recall)} | #{fmt(baseline.score.usefulness)} | #{fmt(baseline.score.snr)} | #{baseline.score.hits} | #{baseline.score.noise} | #{baseline.score.published_claims} | #{fmt(baseline.score.avg_comments_per_pr)} | #{fmt(baseline.research_utility)} |
    | `#{report.policy_id}` | #{fmt(report.score.f1)} | #{fmt(report.score.recall)} | #{fmt(report.score.usefulness)} | #{fmt(report.score.snr)} | #{report.score.hits} | #{report.score.noise} | #{report.score.published_claims} | #{fmt(report.score.avg_comments_per_pr)} | #{fmt(report.research_utility)} |

    ## Decision

    #{decision.decision}: #{decision.reason}

    Unique true positives over baseline: #{decision.unique_hits_over_baseline}
    Paired wins/losses/ties: #{decision.paired_vs_raw_best.wins}/#{decision.paired_vs_raw_best.losses}/#{decision.paired_vs_raw_best.ties}
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

  defp ranker_reason(counterarguments, publish_score, threshold) do
    decision = if publish_score >= threshold, do: "above threshold", else: "below threshold"
    [decision | Enum.map(counterarguments, & &1.id)]
  end

  defp load_claims(source_run, method_id, case_id) do
    source_run
    |> claims_path(method_id, case_id)
    |> Sugary.Json.read!()
    |> atomize()
  end

  defp claims_path(run_dir, method_id, case_id),
    do: Path.join([run_dir, method_id, "claims", "#{case_id}.json"])

  defp reset_claim(claim) do
    claim
    |> Map.put(:publish_decision, "candidate")
    |> Map.delete(:suppressed_reason)
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

  defp claim_tokens(claim) do
    claim
    |> claim_text()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, " ")
    |> String.split()
    |> Enum.flat_map(&String.split(&1, "_"))
    |> Enum.reject(&(String.length(&1) < 3))
    |> MapSet.new()
  end

  defp jaccard(left, right) do
    union = MapSet.union(left, right) |> MapSet.size()

    if union == 0 do
      0.0
    else
      MapSet.intersection(left, right) |> MapSet.size() |> Kernel./(union)
    end
  end

  defp same_path?(left, right) do
    left = normalize_path(left)
    right = normalize_path(right)
    left != "" and right != "" and left == right
  end

  defp make_run_dir(id), do: Path.join(".sugary/research/runs", "#{timestamp()}-#{id}")
  defp timestamp, do: DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _ -> nil
    end
  end

  defp normalize_path(path), do: path |> to_string() |> String.downcase() |> String.trim()
  defp present?(value), do: value |> to_string() |> String.trim() |> Kernel.!=("")
  defp clamp(value), do: value |> max(0.0) |> min(1.0)
  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)

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

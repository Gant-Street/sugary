defmodule Sugary.ResearchScorecard do
  @version "research-scorecard-v0"
  @attention_cost -0.1

  def build(manifest, method_reports, cases) do
    method_cards = Enum.map(method_reports, &method_card/1)
    next_ablation = next_ablation(manifest, method_cards, method_reports)

    %{
      version: @version,
      suite: manifest.suite,
      split: manifest.split,
      metric_posture: %{
        primary_use: "decision support",
        note:
          "Research Scorecard v0 is reporting-only. It does not change publishing, ranking, or promotion behavior."
      },
      utility_model: %{
        true_defect_hit: 1.0,
        high_or_critical_severity_bonus: 2.0,
        noise: -1.0,
        preexisting_false_positive: -2.0,
        published_comment_attention_cost: @attention_cost
      },
      summary: summary(method_cards, cases),
      methods: method_cards,
      next_ablation: next_ablation
    }
  end

  def write!(run_dir, scorecard) do
    Sugary.Json.write!(Path.join(run_dir, "research-scorecard.json"), scorecard)
    File.write!(Path.join(run_dir, "research-scorecard.md"), render_markdown(scorecard))
    scorecard
  end

  def render_markdown(scorecard) do
    method_rows =
      scorecard.methods
      |> Enum.map(fn method ->
        "| #{method.method_id} | #{fmt(method.research_utility)} | #{method.defect_hits} | #{method.expected_defects} | #{fmt(method.recall)} | #{fmt(method.usefulness)} | #{method.noise} | #{method.published_comments} | #{fmt(method.avg_comments_per_pr)} |"
      end)
      |> Enum.join("\n")

    marginal_rows =
      scorecard.methods
      |> Enum.flat_map(fn method ->
        Enum.map(method.marginal_utility_by_rank, fn rank ->
          "| #{method.method_id} | #{rank.rank} | #{rank.published_comments} | #{rank.defect_hits} | #{rank.noise} | #{fmt(rank.utility)} |"
        end)
      end)
      |> Enum.join("\n")

    evidence_rows =
      scorecard.methods
      |> Enum.flat_map(fn method ->
        Enum.map(method.evidence_tier_distribution, fn tier ->
          "| #{method.method_id} | #{tier.tier} | #{tier.published_comments} | #{tier.defect_hits} | #{tier.noise} | #{fmt(tier.utility)} |"
        end)
      end)
      |> Enum.join("\n")

    fp_rows =
      scorecard.methods
      |> Enum.flat_map(fn method ->
        Enum.map(method.false_positive_categories, fn {category, count} ->
          "| #{method.method_id} | #{category} | #{count} |"
        end)
      end)
      |> Enum.join("\n")

    unresolved_rows =
      scorecard.methods
      |> Enum.flat_map(fn method ->
        method.unresolved_expected_defects
        |> Enum.take(20)
        |> Enum.map(fn defect ->
          "| #{method.method_id} | #{defect.case_id} | #{defect.expected_claim_id} | #{defect.category} | #{defect.severity} | #{Enum.join(List.wrap(defect.required_context), ", ")} |"
        end)
      end)
      |> Enum.join("\n")

    recommendations =
      scorecard.next_ablation.recommendations
      |> Enum.map(&"- `#{&1.ablation}`: #{&1.reason}")
      |> Enum.join("\n")

    """
    # Research Scorecard

    Research Scorecard v0 is a reporting-only decision layer. It is meant to make the next ablation smaller and more falsifiable; it does not change publishing behavior.

    ## Summary

    - Best method by research utility: `#{scorecard.summary.best_method_by_research_utility || "none"}`
    - Best method by recall: `#{scorecard.summary.best_method_by_recall || "none"}`
    - Expected defects: #{scorecard.summary.expected_defects}
    - Recommended next ablation: `#{scorecard.next_ablation.primary_ablation}`

    ## Method Summary

    | Method | Research Utility | Hits | Expected | Recall | Usefulness | Noise | Comments | Avg Comments/PR |
    | --- | --- | --- | --- | --- | --- | --- | --- | --- |
    #{method_rows}

    ## Marginal Utility By Rank

    | Method | Rank | Comments | Hits | Noise | Utility |
    | --- | --- | --- | --- | --- | --- |
    #{marginal_rows}

    ## Evidence Tier Distribution

    | Method | Evidence Tier | Comments | Hits | Noise | Utility |
    | --- | --- | --- | --- | --- | --- |
    #{evidence_rows}

    ## False-Positive Categories

    | Method | Category | Count |
    | --- | --- | --- |
    #{if fp_rows == "", do: "| none | none | 0 |", else: fp_rows}

    ## Unresolved Expected Defects

    | Method | Case | Expected Claim | Category | Severity | Required Context |
    | --- | --- | --- | --- | --- | --- |
    #{if unresolved_rows == "", do: "| none | none | none | none | none | none |", else: unresolved_rows}

    ## Next Ablation Recommendation

    Primary: `#{scorecard.next_ablation.primary_ablation}`

    #{if recommendations == "", do: "- no recommendation", else: recommendations}
    """
  end

  defp method_card(report) do
    results = List.wrap(Map.get(report, :results, []))
    published_records = Enum.flat_map(results, &published_records/1)
    unresolved = Enum.flat_map(results, &unresolved_expected_defects/1)
    high_conf_suppressed = Enum.flat_map(results, &suppressed_high_confidence_true_claims/1)

    %{
      method_id: report.method.id,
      class: report.method.class,
      research_utility: sum_by(published_records, :utility),
      defect_hits: Enum.count(published_records, &(&1.outcome == "hit")),
      expected_defects: report.score.expected_claims,
      recall: report.score.recall,
      published_comments: report.score.published_claims,
      avg_comments_per_pr: report.score.avg_comments_per_pr,
      noise: report.score.noise,
      usefulness: report.score.usefulness,
      snr: report.score.snr,
      f1: report.score.f1,
      cost: report.score.cost,
      latency_ms: report.score.latency_ms,
      suppressed_true_claims: report.score.suppressed_true_claims,
      suppressed_high_confidence_true_claims: high_conf_suppressed,
      evidence_tier_distribution: evidence_tier_distribution(published_records),
      marginal_utility_by_rank: marginal_utility_by_rank(published_records),
      false_positive_categories: false_positive_categories(published_records),
      unresolved_expected_defects: unresolved,
      published_claims: published_records
    }
  end

  defp published_records(result) do
    result.final_claims
    |> Enum.filter(&(&1.publish_decision == "publish"))
    |> Enum.with_index(1)
    |> Enum.map_reduce(MapSet.new(), fn {claim, rank}, seen_hits ->
      expected_claim = Sugary.ClaimMatcher.expected_claim(result.case, claim)
      match_key = if expected_claim, do: expected_claim.id, else: claim.dedupe_key
      duplicate_hit? = expected_claim && MapSet.member?(seen_hits, match_key)
      hit? = expected_claim && not duplicate_hit?

      category =
        cond do
          duplicate_hit? -> "duplicate_comment"
          hit? -> nil
          true -> false_positive_category(result.case, claim)
        end

      outcome = if hit?, do: "hit", else: "noise"

      severity =
        if expected_claim, do: field(expected_claim, :severity, "medium"), else: claim.severity

      utility = claim_utility(outcome, severity, category)

      record = %{
        case_id: result.case.id,
        rank: rank,
        rank_bucket: rank_bucket(rank),
        claim_id: claim.id,
        dedupe_key: match_key,
        claim: claim.claim,
        category:
          if(expected_claim,
            do: field(expected_claim, :category, claim.category),
            else: claim.category
          ),
        severity: severity,
        confidence: claim.confidence,
        evidence_tier: strongest_evidence_tier(claim),
        outcome: outcome,
        false_positive_category: category,
        utility: utility
      }

      seen_hits = if hit?, do: MapSet.put(seen_hits, match_key), else: seen_hits
      {record, seen_hits}
    end)
    |> elem(0)
  end

  defp unresolved_expected_defects(result) do
    hit_keys =
      result.final_claims
      |> Enum.filter(&(&1.publish_decision == "publish"))
      |> Enum.flat_map(fn claim ->
        case Sugary.ClaimMatcher.expected_claim(result.case, claim) do
          nil -> []
          expected -> [expected.id]
        end
      end)
      |> MapSet.new()

    result.case.oracle
    |> Map.get(:expectedClaims, [])
    |> Enum.reject(&MapSet.member?(hit_keys, &1.id))
    |> Enum.map(fn expected ->
      %{
        case_id: result.case.id,
        expected_claim_id: expected.id,
        category: field(expected, :category, "bug"),
        severity: field(expected, :severity, "medium"),
        required_context: field(expected, :required_context, []),
        difficulty: field(expected, :difficulty, "unknown"),
        specialist: field(expected, :specialist, "general")
      }
    end)
  end

  defp suppressed_high_confidence_true_claims(result) do
    published_keys =
      result.final_claims
      |> Enum.filter(&(&1.publish_decision == "publish"))
      |> Enum.flat_map(fn claim ->
        case Sugary.ClaimMatcher.expected_claim(result.case, claim) do
          nil -> []
          expected -> [expected.id]
        end
      end)
      |> MapSet.new()

    result.candidate_claims
    |> Enum.flat_map(fn claim ->
      case Sugary.ClaimMatcher.expected_claim(result.case, claim) do
        nil -> []
        expected -> [{claim, expected}]
      end
    end)
    |> Enum.reject(fn {_claim, expected} -> MapSet.member?(published_keys, expected.id) end)
    |> Enum.filter(fn {claim, _expected} -> (claim.confidence || 0.0) >= 0.7 end)
    |> Enum.map(fn {claim, expected} ->
      %{
        case_id: result.case.id,
        claim_id: claim.id,
        dedupe_key: expected.id,
        confidence: claim.confidence
      }
    end)
  end

  defp evidence_tier_distribution(records) do
    records
    |> Enum.group_by(& &1.evidence_tier)
    |> Enum.map(fn {tier, tier_records} ->
      %{
        tier: tier,
        published_comments: length(tier_records),
        defect_hits: Enum.count(tier_records, &(&1.outcome == "hit")),
        noise: Enum.count(tier_records, &(&1.outcome == "noise")),
        utility: sum_by(tier_records, :utility)
      }
    end)
    |> Enum.sort_by(&tier_sort/1)
  end

  defp marginal_utility_by_rank(records) do
    buckets = ["1", "2", "3", "4_plus"]

    bucket_rows =
      buckets
      |> Enum.map(fn bucket ->
        bucket_records = Enum.filter(records, &(&1.rank_bucket == bucket))
        rank_row(bucket, bucket_records)
      end)

    bucket_rows ++ [rank_row("all", records)]
  end

  defp rank_row(rank, records) do
    %{
      rank: rank,
      published_comments: length(records),
      defect_hits: Enum.count(records, &(&1.outcome == "hit")),
      noise: Enum.count(records, &(&1.outcome == "noise")),
      utility: sum_by(records, :utility)
    }
  end

  defp false_positive_categories(records) do
    records
    |> Enum.filter(&(&1.outcome == "noise"))
    |> Enum.group_by(&(&1.false_positive_category || "unsupported"))
    |> Map.new(fn {category, values} -> {category, length(values)} end)
  end

  defp summary(method_cards, cases) do
    best_utility = Enum.max_by(method_cards, & &1.research_utility, fn -> nil end)
    best_recall = Enum.max_by(method_cards, &{&1.recall, &1.usefulness, &1.snr}, fn -> nil end)

    %{
      expected_defects: expected_count(cases),
      best_method_by_research_utility: if(best_utility, do: best_utility.method_id),
      best_method_by_recall: if(best_recall, do: best_recall.method_id)
    }
  end

  defp next_ablation(manifest, method_cards, method_reports) do
    best = Enum.max_by(method_cards, & &1.research_utility, fn -> nil end)
    unique_hit_methods = unique_hit_methods(method_reports)
    public_suite? = manifest.suite in ["martian-offline", "cr-bench"]

    recommendations =
      []
      |> maybe_recommend(
        (best && length(best.unresolved_expected_defects) > best.noise) and
          cross_file_or_contract_unresolved?(best),
        "context_retrieval",
        "False negatives dominate and unresolved defects require cross-file, contract, schema, middleware, route, or historical context."
      )
      |> maybe_recommend(
        (best && tier5_noise(best) > 0) and tier5_noise(best) >= max(div(best.noise + 1, 2), 1),
        "evidence_gate",
        "Tier 5 weak-heuristic claims dominate published noise."
      )
      |> maybe_recommend(
        best && best.noise > length(best.unresolved_expected_defects),
        "refutation",
        "False positives dominate the best method's remaining error profile."
      )
      |> maybe_recommend(
        best && best.suppressed_high_confidence_true_claims != [],
        "ranking_or_publishing_threshold",
        "High-confidence true candidate claims were generated but suppressed before publishing."
      )
      |> maybe_recommend(
        length(unique_hit_methods) >= 2,
        "team_or_hybrid_composition",
        "Multiple reviewers contributed unique true positives, so composition may matter."
      )
      |> maybe_recommend(
        (public_suite? and best) && best.recall < 0.5,
        "public_transfer_fixture_expansion",
        "Public smoke recall is low; local fixtures likely miss transfer failure modes."
      )
      |> Enum.reverse()

    recommendations =
      if recommendations == [] do
        [
          %{
            ablation: "evidence_refutation_ablation",
            reason:
              "No single dominant failure mode was detected; run the narrow PCRS evidence/refutation ablation next."
          }
        ]
      else
        recommendations
      end

    %{
      primary_ablation: hd(recommendations).ablation,
      recommendations: recommendations,
      signals: %{
        best_method: if(best, do: best.method_id),
        best_method_noise: if(best, do: best.noise, else: 0),
        best_method_unresolved_expected_defects:
          if(best, do: length(best.unresolved_expected_defects), else: 0),
        best_method_tier5_noise: if(best, do: tier5_noise(best), else: 0),
        suppressed_high_confidence_true_claims:
          if(best, do: length(best.suppressed_high_confidence_true_claims), else: 0),
        unique_hit_methods: unique_hit_methods
      }
    }
  end

  defp maybe_recommend(recommendations, true, ablation, reason),
    do: [%{ablation: ablation, reason: reason} | recommendations]

  defp maybe_recommend(recommendations, _false, _ablation, _reason), do: recommendations

  defp cross_file_or_contract_unresolved?(method) do
    Enum.any?(method.unresolved_expected_defects, fn defect ->
      required_context =
        defect.required_context
        |> List.wrap()
        |> Enum.join(" ")
        |> String.downcase()

      category = defect.category |> to_string() |> String.downcase()

      String.contains?(required_context, "contract") or
        String.contains?(required_context, "schema") or
        String.contains?(required_context, "middleware") or
        String.contains?(required_context, "route") or
        String.contains?(required_context, "historical") or
        String.contains?(category, "contract")
    end)
  end

  defp tier5_noise(method) do
    method.published_claims
    |> Enum.count(&(&1.outcome == "noise" and &1.evidence_tier == "tier_5"))
  end

  defp unique_hit_methods(method_reports) do
    hits =
      method_reports
      |> Enum.flat_map(fn report ->
        Map.get(report, :results, [])
        |> List.wrap()
        |> Enum.flat_map(fn result ->
          result.final_claims
          |> Enum.filter(&(&1.publish_decision == "publish"))
          |> Enum.flat_map(fn claim ->
            case Sugary.ClaimMatcher.expected_claim(result.case, claim) do
              nil -> []
              expected -> [{"#{result.case.id}::#{expected.id}", report.method.id}]
            end
          end)
        end)
      end)
      |> Enum.group_by(fn {key, _method_id} -> key end, fn {_key, method_id} -> method_id end)

    hits
    |> Enum.flat_map(fn {_key, method_ids} ->
      method_ids = Enum.uniq(method_ids)
      if length(method_ids) == 1, do: method_ids, else: []
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp claim_utility("hit", severity, _category) do
    1.0 + severity_bonus(severity) + @attention_cost
  end

  defp claim_utility("noise", _severity, "preexisting_bug"), do: -2.0 + @attention_cost
  defp claim_utility("noise", _severity, _category), do: -1.0 + @attention_cost

  defp severity_bonus(severity) when severity in ["high", "critical"], do: 2.0
  defp severity_bonus(_severity), do: 0.0

  defp false_positive_category(bench_case, claim) do
    non_issue = Sugary.ClaimMatcher.known_non_issue(bench_case, claim)
    trap_category = if non_issue, do: field(non_issue, :trapCategory)

    cond do
      is_binary(trap_category) ->
        trap_category

      non_issue && claim.introduced_by_pr == false ->
        "preexisting_bug"

      non_issue && claim.category == "style" ->
        "stylistic_preference"

      non_issue ->
        "low_severity_noise"

      true ->
        "speculative_edge_case"
    end
  end

  defp strongest_evidence_tier(claim) do
    claim.evidence
    |> List.wrap()
    |> Enum.map(&field(&1, :tier))
    |> Enum.map(&parse_tier/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.min(fn -> nil end)
    |> case do
      nil -> "unknown"
      tier -> "tier_#{tier}"
    end
  end

  defp parse_tier(tier) when is_integer(tier), do: tier

  defp parse_tier(tier) when is_binary(tier) do
    case Integer.parse(tier) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp parse_tier(_tier), do: nil

  defp rank_bucket(rank) when rank in [1, 2, 3], do: to_string(rank)
  defp rank_bucket(_rank), do: "4_plus"

  defp tier_sort(%{tier: "unknown"}), do: 99

  defp tier_sort(%{tier: "tier_" <> tier}) do
    case Integer.parse(tier) do
      {number, _rest} -> number
      :error -> 98
    end
  end

  defp expected_count(cases) do
    cases
    |> Enum.map(&(Map.get(&1.oracle, :expectedClaims, []) |> length()))
    |> Enum.sum()
  end

  defp sum_by(records, key), do: Enum.reduce(records, 0.0, &(&2 + Map.get(&1, key, 0.0)))

  defp field(map, key, default \\ nil)

  defp field(%{} = map, key, default),
    do: Map.get(map, key) || Map.get(map, to_string(key)) || default

  defp field(_map, _key, default), do: default

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)
end

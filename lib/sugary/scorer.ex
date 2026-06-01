defmodule Sugary.Scorer do
  alias Sugary.Protocol.{FailureRecord, Scorecard}

  def score(method_id, case_results) do
    per_case = Enum.map(case_results, &score_case(method_id, &1))
    totals = reduce_scores(per_case)
    Scorecard.new(Map.put(totals, :method_id, method_id))
  end

  def failures(method_id, case_results) do
    case_results
    |> Enum.flat_map(&case_failures(method_id, &1))
  end

  def slices(method_id, case_results) do
    expected =
      Enum.flat_map(case_results, fn result ->
        result.case.oracle
        |> Map.get(:expectedClaims, [])
        |> Enum.map(fn claim -> {result, claim} end)
      end)

    %{
      method_id: method_id,
      category: slice_by(expected, &Map.get(&1, :category, "bug")),
      severity: slice_by(expected, &Map.get(&1, :severity, "medium")),
      difficulty: slice_by(expected, &Map.get(&1, :difficulty, "unknown")),
      required_context: slice_many(expected, &Map.get(&1, :required_context, [])),
      specialist: slice_by(expected, &Map.get(&1, :specialist, "general")),
      evidence_tier:
        slice_by(expected, &(Map.get(&1, :expected_evidence_tier, "unknown") |> to_string()))
    }
  end

  defp score_case(_method_id, result) do
    published = Enum.filter(result.final_claims, &(&1.publish_decision == "publish"))
    accounting = Sugary.ScoreAccounting.claim_accounting(result.case, published)
    valid = 0

    suppressed_true =
      MapSet.difference(candidate_hit_ids(result), published_hit_ids(result))
      |> MapSet.size()

    %{
      cases: 1,
      expected_claims: Sugary.ClaimMatcher.expected_ids(result.case) |> MapSet.size(),
      published_claims: length(published),
      precision_denominator: accounting.precision_denominator,
      hits: accounting.unique_hits,
      valid_suggestions: valid,
      noise: accounting.noise_events,
      matched_comments: accounting.matched_comments,
      noisy_or_trap_comments: accounting.noisy_or_trap_comments,
      unsupported_comments: accounting.unsupported_comments,
      known_non_issue_comments: accounting.known_non_issue_comments,
      hit_and_trap_comments: accounting.hit_and_trap_comments,
      duplicate_hit_events: accounting.duplicate_hit_events,
      suppressed_true_claims: suppressed_true,
      cost: result.reviewer_result.cost,
      latency_ms: result.reviewer_result.latency_ms
    }
  end

  defp reduce_scores(scores) do
    totals =
      Enum.reduce(scores, zero(), fn score, acc ->
        Map.merge(acc, score, fn _key, left, right -> left + right end)
      end)

    useful = totals.hits + totals.valid_suggestions
    precision = ratio(useful, totals.published_claims)
    recall = ratio(totals.hits, totals.expected_claims)

    totals
    |> Map.put(:precision, precision)
    |> Map.put(:recall, recall)
    |> Map.put(
      :f1,
      if(precision + recall == 0, do: 0.0, else: 2 * precision * recall / (precision + recall))
    )
    |> Map.put(:usefulness, precision)
    |> Map.put(:snr, if(totals.noise == 0, do: useful * 1.0, else: useful / totals.noise))
    |> Map.put(:avg_comments_per_pr, ratio(totals.published_claims, max(totals.cases, 1)))
  end

  defp zero do
    %{
      cases: 0,
      expected_claims: 0,
      published_claims: 0,
      hits: 0,
      valid_suggestions: 0,
      noise: 0,
      precision_denominator: 0,
      matched_comments: 0,
      noisy_or_trap_comments: 0,
      unsupported_comments: 0,
      known_non_issue_comments: 0,
      hit_and_trap_comments: 0,
      duplicate_hit_events: 0,
      suppressed_true_claims: 0,
      cost: 0.0,
      latency_ms: 0
    }
  end

  defp case_failures(method_id, result) do
    published = Enum.filter(result.final_claims, &(&1.publish_decision == "publish"))
    expected = Sugary.ClaimMatcher.expected_ids(result.case)
    published_keys = published_hit_ids(result)
    candidate_keys = candidate_hit_ids(result)

    false_negatives =
      expected
      |> MapSet.difference(published_keys)
      |> Enum.map(fn expected_id ->
        category =
          if MapSet.member?(candidate_keys, expected_id),
            do: "comment_suppressed_too_aggressively",
            else: "missing_context"

        FailureRecord.new(%{
          id: "#{result.case.id}-#{method_id}-fn-#{expected_id}",
          case_id: result.case.id,
          method_id: method_id,
          type: "false_negative",
          category: category,
          expected_claim_id: expected_id,
          summary: "Expected claim #{expected_id} was not published.",
          suggested_experiment:
            "Inspect context, evidence, and refutation stages for #{expected_id}."
        })
      end)

    false_positives =
      published
      |> Enum.reject(&Sugary.ClaimMatcher.expected_claim(result.case, &1))
      |> Enum.map(fn claim ->
        FailureRecord.new(%{
          id: "#{result.case.id}-#{method_id}-fp-#{claim.dedupe_key}",
          case_id: result.case.id,
          method_id: method_id,
          type: "false_positive",
          category: false_positive_category(result.case, claim),
          claim_id: claim.dedupe_key,
          summary: "Published unsupported claim #{claim.dedupe_key}.",
          suggested_experiment:
            "Strengthen no-oracle research refutation for #{claim.dedupe_key}."
        })
      end)

    duplicate_failures =
      published
      |> Enum.group_by(& &1.dedupe_key)
      |> Enum.filter(fn {_key, values} -> length(values) > 1 end)
      |> Enum.flat_map(fn {key, [_first | duplicates]} ->
        Enum.map(duplicates, fn duplicate ->
          FailureRecord.new(%{
            id: "#{result.case.id}-#{method_id}-duplicate-#{duplicate.id}",
            case_id: result.case.id,
            method_id: method_id,
            type: "false_positive",
            category: "duplicate_comment",
            claim_id: key,
            summary: "Published duplicate claim #{key}.",
            suggested_experiment: "Deduplicate claims before ranking."
          })
        end)
      end)

    false_negatives ++ false_positives ++ duplicate_failures
  end

  defp false_positive_category(bench_case, claim) do
    non_issue = Sugary.ClaimMatcher.known_non_issue(bench_case, claim)

    trap_category =
      non_issue
      |> case do
        nil -> nil
        value -> Map.get(value, :trapCategory) || Map.get(value, "trapCategory")
      end

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

  defp published_hit_ids(result), do: hit_ids(result.case, result.final_claims, true)
  defp candidate_hit_ids(result), do: hit_ids(result.case, result.candidate_claims, false)

  defp hit_ids(bench_case, claims, published_only?) do
    claims
    |> Enum.filter(fn claim -> not published_only? or claim.publish_decision == "publish" end)
    |> Enum.flat_map(fn claim ->
      case Sugary.ClaimMatcher.expected_claim(bench_case, claim) do
        nil -> []
        expected -> [Map.get(expected, :id)]
      end
    end)
    |> MapSet.new()
  end

  defp slice_by(expected, key_fun) do
    expected
    |> Enum.group_by(fn {_result, claim} -> key_fun.(claim) end)
    |> Map.new(fn {key, pairs} -> {to_string(key), slice_score(pairs)} end)
  end

  defp slice_many(expected, key_fun) do
    expected
    |> Enum.flat_map(fn {result, claim} ->
      keys = key_fun.(claim) |> List.wrap()
      Enum.map(keys, &{result, claim, &1})
    end)
    |> Enum.group_by(fn {_result, _claim, key} -> key end)
    |> Map.new(fn {key, triples} ->
      pairs = Enum.map(triples, fn {result, claim, _key} -> {result, claim} end)
      {to_string(key), slice_score(pairs)}
    end)
  end

  defp slice_score(pairs) do
    expected = length(pairs)

    hits =
      Enum.count(pairs, fn {result, claim} ->
        result.final_claims
        |> Enum.filter(&(&1.publish_decision == "publish"))
        |> Enum.any?(&Sugary.ClaimMatcher.matches_expected?(result.case, &1, claim))
      end)

    %{expected: expected, hits: hits, recall: ratio(hits, expected)}
  end

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den
end

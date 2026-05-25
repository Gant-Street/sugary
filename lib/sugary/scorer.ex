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
    expected = expected_ids(result.case)
    known_noise = known_noise_ids(result.case)
    published = Enum.filter(result.final_claims, &(&1.publish_decision == "publish"))
    published_keys = MapSet.new(Enum.map(published, & &1.dedupe_key))
    candidate_keys = MapSet.new(Enum.map(result.candidate_claims, & &1.dedupe_key))

    hits = MapSet.intersection(published_keys, expected) |> MapSet.size()
    duplicate_noise = length(published) - MapSet.size(published_keys)

    unsupported_noise =
      Enum.count(
        published,
        &(MapSet.member?(known_noise, &1.dedupe_key) or
            not MapSet.member?(expected, &1.dedupe_key))
      )

    noise = duplicate_noise + unsupported_noise
    valid = 0

    suppressed_true =
      MapSet.difference(MapSet.intersection(candidate_keys, expected), published_keys)
      |> MapSet.size()

    %{
      cases: 1,
      expected_claims: MapSet.size(expected),
      published_claims: length(published),
      hits: hits,
      valid_suggestions: valid,
      noise: noise,
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
      suppressed_true_claims: 0,
      cost: 0.0,
      latency_ms: 0
    }
  end

  defp case_failures(method_id, result) do
    expected = expected_ids(result.case)
    known_noise = known_noise_ids(result.case)
    known_noise_map = known_noise_map(result.case)
    published = Enum.filter(result.final_claims, &(&1.publish_decision == "publish"))
    published_keys = MapSet.new(Enum.map(published, & &1.dedupe_key))
    candidate_keys = MapSet.new(Enum.map(result.candidate_claims, & &1.dedupe_key))

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
      |> Enum.reject(&MapSet.member?(expected, &1.dedupe_key))
      |> Enum.map(fn claim ->
        FailureRecord.new(%{
          id: "#{result.case.id}-#{method_id}-fp-#{claim.dedupe_key}",
          case_id: result.case.id,
          method_id: method_id,
          type: "false_positive",
          category: false_positive_category(claim, known_noise, known_noise_map),
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

  defp false_positive_category(claim, known_noise, known_noise_map) do
    trap_category =
      known_noise_map
      |> Map.get(claim.dedupe_key, %{})
      |> Map.get(:trapCategory)

    cond do
      is_binary(trap_category) ->
        trap_category

      MapSet.member?(known_noise, claim.dedupe_key) and claim.introduced_by_pr == false ->
        "preexisting_bug"

      MapSet.member?(known_noise, claim.dedupe_key) and claim.category == "style" ->
        "stylistic_preference"

      MapSet.member?(known_noise, claim.dedupe_key) ->
        "low_severity_noise"

      true ->
        "speculative_edge_case"
    end
  end

  defp expected_ids(bench_case) do
    bench_case.oracle
    |> Map.get(:expectedClaims, [])
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp known_noise_ids(bench_case) do
    bench_case.oracle
    |> Map.get(:knownNonIssues, [])
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp known_noise_map(bench_case) do
    bench_case.oracle
    |> Map.get(:knownNonIssues, [])
    |> Map.new(&{&1.id, &1})
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
        |> Enum.any?(&(&1.dedupe_key == claim.id))
      end)

    %{expected: expected, hits: hits, recall: ratio(hits, expected)}
  end

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den
end

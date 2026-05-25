defmodule Sugary.Pipeline do
  def run_case(bench_case, method) do
    input = Sugary.Fixtures.input_bundle(bench_case, method)
    reviewer_case = reviewer_case(bench_case, method)
    reviewer_result = Sugary.Reviewers.run(method, reviewer_case, input)
    candidate_claims = Enum.map(reviewer_result.claims, &atomize/1)

    processed =
      candidate_claims
      |> apply_evidence(method)
      |> apply_refutation(method)
      |> apply_ranking(method)

    %{
      case: bench_case,
      input: input,
      reviewer_result: reviewer_result,
      candidate_claims: candidate_claims,
      final_claims: processed
    }
  end

  defp reviewer_case(bench_case, %{class: "harness_test"}), do: bench_case

  defp reviewer_case(bench_case, _method),
    do: %{bench_case | oracle: %{expectedClaims: [], knownNonIssues: []}}

  defp apply_evidence(claims, %{evidence: "static_trace_stub"}) do
    Enum.map(claims, fn claim ->
      evidence = [
        %{
          type: "static_trace",
          tier: 3,
          strength: "medium",
          summary: "Static trace stub found a plausible path."
        }
      ]

      %{claim | evidence: evidence, confidence: min(0.95, claim.confidence + 0.1)}
    end)
  end

  defp apply_evidence(claims, _method), do: claims

  defp apply_refutation(claims, %{refutation: "generic_refuter_stub"}) do
    {deduped, _seen} =
      Enum.map_reduce(claims, MapSet.new(), fn claim, seen ->
        cond do
          MapSet.member?(seen, claim.dedupe_key) ->
            {Map.merge(claim, %{
               publish_decision: "suppress",
               suppressed_reason: "duplicate_comment"
             }), seen}

          claim.introduced_by_pr == false ->
            {Map.merge(claim, %{
               publish_decision: "suppress",
               suppressed_reason: "preexisting_bug"
             }), MapSet.put(seen, claim.dedupe_key)}

          claim.category == "style" or claim.confidence < 0.5 ->
            {Map.merge(claim, %{
               publish_decision: "suppress",
               suppressed_reason: "low_severity_noise"
             }), MapSet.put(seen, claim.dedupe_key)}

          true ->
            {claim, MapSet.put(seen, claim.dedupe_key)}
        end
      end)

    deduped
  end

  defp apply_refutation(claims, _method), do: claims

  defp apply_ranking(claims, method) do
    claims
    |> Enum.sort_by(&rank_score(&1, method), :desc)
    |> Enum.with_index()
    |> Enum.map(fn {claim, index} ->
      cond do
        claim.publish_decision == "suppress" ->
          claim

        index < 3 ->
          Map.put(claim, :publish_decision, "publish")

        true ->
          Map.merge(claim, %{publish_decision: "suppress", suppressed_reason: "comment_budget"})
      end
    end)
  end

  defp rank_score(claim, %{ranking: "expected_value_stub"}) do
    severity =
      %{"critical" => 4, "high" => 3, "medium" => 2, "low" => 1} |> Map.get(claim.severity, 1)

    tier = claim.evidence |> List.first(%{}) |> Map.get(:tier, 5)
    claim.confidence * severity * (6 - tier)
  end

  defp rank_score(claim, _method), do: claim.confidence

  defp atomize(%{} = map),
    do: Map.new(map, fn {key, value} -> {atom_key(key), atomize(value)} end)

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value

  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)
end

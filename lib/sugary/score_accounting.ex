defmodule Sugary.ScoreAccounting do
  @moduledoc false

  def claim_accounting(bench_case, claims) do
    claim_rows =
      Enum.map(claims, fn claim ->
        expected = Sugary.ClaimMatcher.expected_claim(bench_case, claim)
        non_issue = Sugary.ClaimMatcher.known_non_issue(bench_case, claim)

        %{
          claim: claim,
          expected_id: expected && field(expected, :id),
          known_non_issue_id: non_issue && field(non_issue, :id),
          matched_expected?: not is_nil(expected),
          known_non_issue?: not is_nil(non_issue)
        }
      end)

    matched_expected_ids =
      claim_rows
      |> Enum.flat_map(fn row ->
        if row.expected_id, do: [row.expected_id], else: []
      end)

    unique_hits = matched_expected_ids |> MapSet.new() |> MapSet.size()
    duplicate_hit_events = length(matched_expected_ids) - unique_hits

    unsupported_comments = Enum.count(claim_rows, &(not &1.matched_expected?))
    known_non_issue_comments = Enum.count(claim_rows, & &1.known_non_issue?)

    noisy_or_trap_comments =
      Enum.count(claim_rows, fn row ->
        not row.matched_expected? or row.known_non_issue?
      end)

    hit_and_trap_comments =
      Enum.count(claim_rows, fn row ->
        row.matched_expected? and row.known_non_issue?
      end)

    %{
      comments: length(claim_rows),
      precision_denominator: length(claim_rows),
      unique_hits: unique_hits,
      matched_comments: Enum.count(claim_rows, & &1.matched_expected?),
      noisy_or_trap_comments: noisy_or_trap_comments,
      unsupported_comments: unsupported_comments,
      known_non_issue_comments: known_non_issue_comments,
      hit_and_trap_comments: hit_and_trap_comments,
      duplicate_hit_events: duplicate_hit_events,
      noise_events: noisy_or_trap_comments + duplicate_hit_events,
      hit_ids: matched_expected_ids |> MapSet.new() |> Enum.sort(),
      rows: claim_rows
    }
  end

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(%_module{} = struct, key, default),
    do: struct |> Map.from_struct() |> field(key, default)

  defp field(%{} = map, key, default), do: map[key] || map[to_string(key)] || default
  defp field(_other, _key, default), do: default
end

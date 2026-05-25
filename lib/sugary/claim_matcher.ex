defmodule Sugary.ClaimMatcher do
  @stopwords MapSet.new(~w(
    a an and are as at be because before by can code for from generated has here in into is it
    new not of on or path pr route should that the this to with without
  ))

  def expected_claim(bench_case, claim) do
    expected_claims(bench_case)
    |> best_match(claim)
  end

  def known_non_issue(bench_case, claim) do
    known_non_issues(bench_case)
    |> best_match(claim)
  end

  def matches_expected?(bench_case, claim, expected) do
    expected_claim(bench_case, claim)
    |> case do
      nil -> false
      matched -> field(matched, :id) == field(expected, :id)
    end
  end

  def expected_ids(bench_case) do
    bench_case
    |> expected_claims()
    |> Enum.map(&field(&1, :id))
    |> MapSet.new()
  end

  def known_non_issue_ids(bench_case) do
    bench_case
    |> known_non_issues()
    |> Enum.map(&field(&1, :id))
    |> MapSet.new()
  end

  defp best_match(oracles, claim) do
    oracles
    |> Enum.map(&{&1, match_rank(claim, &1)})
    |> Enum.reject(fn {_oracle, rank} -> is_nil(rank) end)
    |> Enum.max_by(fn {_oracle, rank} -> rank end, fn -> nil end)
    |> case do
      nil -> nil
      {oracle, _rank} -> oracle
    end
  end

  defp match_rank(claim, oracle) do
    cond do
      exact_match?(claim, oracle) ->
        {2, 1_000_000, 1.0}

      fuzzy_match?(claim, oracle) ->
        {1, token_overlap_count(claim, oracle), token_overlap_score(claim, oracle)}

      true ->
        nil
    end
  end

  defp exact_match?(claim, oracle) do
    key = claim |> field(:dedupe_key) |> to_string()
    id = oracle |> field(:id) |> to_string()
    key != "" and key == id
  end

  defp fuzzy_match?(claim, oracle) do
    compatible_category?(claim, oracle) and
      ((same_path?(claim, oracle) and token_overlap_score(claim, oracle) >= 0.34 and
          token_overlap_count(claim, oracle) >= 2) or
         (unknown_path?(claim) and token_overlap_score(claim, oracle) >= 0.55 and
            token_overlap_count(claim, oracle) >= 4) or
         (unknown_path?(oracle) and token_overlap_score(claim, oracle) >= 0.3 and
            token_overlap_count(claim, oracle) >= 2))
  end

  defp same_path?(claim, oracle) do
    claim_path = claim |> field(:path) |> normalize_path()
    oracle_path = oracle |> field(:path) |> normalize_path()
    claim_path != "" and oracle_path != "" and claim_path == oracle_path
  end

  defp unknown_path?(claim) do
    claim
    |> field(:path)
    |> normalize_path()
    |> Kernel.in(["", "unknown"])
  end

  defp compatible_category?(claim, oracle) do
    claim_category = claim |> field(:category) |> normalize()
    oracle_category = oracle |> field(:category) |> normalize()

    claim_category in ["", oracle_category, "bug", "runtime", "static_analysis", "external_text"] or
      oracle_category in ["bug", "", "public_benchmark"]
  end

  defp token_overlap_score(claim, oracle) do
    claim_tokens = claim_tokens(claim)
    oracle_tokens = oracle_tokens(oracle)

    if MapSet.size(oracle_tokens) == 0 do
      0.0
    else
      MapSet.intersection(claim_tokens, oracle_tokens)
      |> MapSet.size()
      |> Kernel./(MapSet.size(oracle_tokens))
    end
  end

  defp token_overlap_count(claim, oracle) do
    claim
    |> claim_tokens()
    |> MapSet.intersection(oracle_tokens(oracle))
    |> MapSet.size()
  end

  defp claim_tokens(claim) do
    [
      field(claim, :claim),
      field(claim, :category),
      field(claim, :failure_path) |> List.wrap() |> Enum.join(" "),
      claim |> field(:evidence) |> List.wrap() |> Enum.map(&field(&1, :summary)) |> Enum.join(" ")
    ]
    |> Enum.join(" ")
    |> tokens()
  end

  defp oracle_tokens(oracle) do
    [
      field(oracle, :description),
      field(oracle, :category),
      field(oracle, :required_context) |> List.wrap() |> Enum.join(" "),
      field(oracle, :specialist)
    ]
    |> Enum.join(" ")
    |> tokens()
  end

  defp tokens(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, " ")
    |> String.split()
    |> Enum.flat_map(&String.split(&1, "_"))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.reject(&MapSet.member?(@stopwords, &1))
    |> MapSet.new()
  end

  defp expected_claims(bench_case), do: oracle_list(bench_case, :expectedClaims)
  defp known_non_issues(bench_case), do: oracle_list(bench_case, :knownNonIssues)

  defp oracle_list(bench_case, key) do
    bench_case.oracle
    |> field(key, [])
    |> List.wrap()
  end

  defp normalize_path(path), do: path |> to_string() |> String.trim()

  defp normalize(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.trim()
  end

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(%_module{} = struct, key, default),
    do: struct |> Map.from_struct() |> field(key, default)

  defp field(%{} = map, key, default), do: map[key] || map[to_string(key)] || default
  defp field(_other, _key, default), do: default
end

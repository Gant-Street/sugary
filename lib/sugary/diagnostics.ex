defmodule Sugary.Diagnostics do
  def saturation(method_reports, cases, split \\ nil) do
    individual_reports = Enum.reject(method_reports, &(Map.get(&1.method, :class) == "team"))
    team_reports = Enum.filter(method_reports, &(Map.get(&1.method, :class) == "team"))

    best_individual =
      individual_reports
      |> Enum.max_by(&score_rank(&1.score), fn -> nil end)

    best_team =
      team_reports
      |> Enum.max_by(&score_rank(&1.score), fn -> nil end)

    oracle = oracle_union(method_reports, cases)
    best_individual_score = score_or_zero(best_individual)
    best_team_score = score_or_zero(best_team)

    saturated? =
      expected_count(cases) > 0 and best_individual_score.hits == expected_count(cases) and
        best_individual_score.noise == 0

    %{
      split: split,
      best_individual_reviewer: method_id(best_individual),
      best_individual_recall: best_individual_score.recall,
      best_individual_usefulness: best_individual_score.usefulness,
      best_individual_snr: best_individual_score.snr,
      any_perfect_reviewer: Enum.any?(individual_reports, &perfect?(&1, cases)),
      any_perfect_method_or_team: Enum.any?(method_reports, &perfect?(&1, cases)),
      fixture_saturated: saturated?,
      message:
        if(saturated?,
          do:
            "This suite is saturated. It cannot support claims about team complementarity or architecture superiority.",
          else:
            "This suite is not saturated. Architecture comparisons may still have useful gradient."
        ),
      true_positives_remaining_unfound_by_any_reviewer:
        max(expected_count(cases) - oracle.hits, 0),
      noise_produced_by_any_reviewer: Enum.reduce(method_reports, 0, &(&1.score.noise + &2)),
      oracle_union_upper_bound: oracle,
      gap_best_individual_to_oracle: oracle.f1 - best_individual_score.f1,
      gap_best_team_to_oracle: oracle.f1 - best_team_score.f1,
      complementarity_headroom: oracle.f1 - best_individual_score.f1
    }
  end

  def anti_overfitting_warnings(method_reports, cases, split \\ nil) do
    Enum.flat_map(method_reports, fn report ->
      []
      |> maybe_warning(exact_oracle_wording?(report), %{
        method_id: report.method.id,
        type: "exact_oracle_wording",
        summary: "Reviewer emitted a claim with exact oracle wording."
      })
      |> maybe_warning(case_name_leak?(report), %{
        method_id: report.method.id,
        type: "fixture_specific_name_match",
        summary: "Reviewer output includes fixture-specific case names."
      })
      |> maybe_warning(path_category_coupling?(report), %{
        method_id: report.method.id,
        type: "path_category_coupling",
        summary: "Reviewer hits may depend on case ids or paths containing the bug category."
      })
      |> maybe_warning(perfect?(report, cases) and split in ["train", "dev"], %{
        method_id: report.method.id,
        type: "perfect_train_or_dev",
        summary: "Reviewer is perfect on a tunable split; verify against holdout."
      })
      |> maybe_warning(report.failures == [] and expected_count(cases) > 0, %{
        method_id: report.method.id,
        type: "no_failures_across_hard_cases",
        summary: "Reviewer produced no failures across hard cases; benchmark may be too easy."
      })
    end)
  end

  def coverage_matrix_v2(method_reports, cases) do
    reviewer_ids = Enum.map(method_reports, & &1.method.id)

    expected =
      Enum.flat_map(cases, fn bench_case ->
        bench_case.oracle
        |> Map.get(:expectedClaims, [])
        |> Enum.map(fn expected ->
          %{
            type: "expected",
            case_id: bench_case.id,
            expected_claim: expected.id,
            required_context: Map.get(expected, :required_context, []),
            difficulty: Map.get(expected, :difficulty, "unknown"),
            reviewers:
              Map.new(method_reports, fn report ->
                {report.method.id, report_hits?(report, bench_case.id, expected.id)}
              end)
          }
        end)
      end)

    traps =
      Enum.flat_map(cases, fn bench_case ->
        bench_case.oracle
        |> Map.get(:knownNonIssues, [])
        |> Enum.map(fn trap ->
          %{
            type: "trap",
            case_id: bench_case.id,
            trap: trap.id,
            trap_category: Map.get(trap, :trapCategory, "low_severity_noise"),
            reviewers:
              Map.new(method_reports, fn report ->
                {report.method.id, report_hits?(report, bench_case.id, trap.id)}
              end)
          }
        end)
      end)

    %{reviewers: reviewer_ids, expected: expected, traps: traps}
  end

  def score_slices(method_reports) do
    Map.new(method_reports, fn report ->
      {report.method.id, Sugary.Scorer.slices(report.method.id, report.results || [])}
    end)
  end

  defp oracle_union(method_reports, cases) do
    hit_count =
      method_reports
      |> Enum.reduce(MapSet.new(), fn report, acc ->
        report.results
        |> List.wrap()
        |> Enum.reduce(acc, fn result, result_acc ->
          result.final_claims
          |> Enum.filter(&(&1.publish_decision == "publish"))
          |> Enum.flat_map(fn claim ->
            case Sugary.ClaimMatcher.expected_claim(result.case, claim) do
              nil -> []
              expected -> ["#{result.case.id}::#{expected.id}"]
            end
          end)
          |> MapSet.new()
          |> MapSet.union(result_acc)
        end)
      end)
      |> MapSet.size()

    expected = expected_count(cases)
    recall = ratio(hit_count, expected)
    f1 = if hit_count == 0, do: 0.0, else: 2 * recall / (1 + recall)

    %{
      hits: hit_count,
      expected_claims: expected,
      precision: if(hit_count == 0, do: 0.0, else: 1.0),
      recall: recall,
      f1: f1,
      usefulness: if(hit_count == 0, do: 0.0, else: 1.0),
      snr: hit_count * 1.0
    }
  end

  defp report_hits?(report, case_id, dedupe_key) do
    report.results
    |> List.wrap()
    |> Enum.find(&(&1.case.id == case_id))
    |> case do
      nil ->
        false

      result ->
        Enum.any?(
          result.final_claims,
          &(&1.publish_decision == "publish" and
              case Sugary.ClaimMatcher.expected_claim(result.case, &1) do
                nil -> false
                expected -> expected.id == dedupe_key
              end)
        )
    end
  end

  defp exact_oracle_wording?(report) do
    Enum.any?(report.results || [], fn result ->
      oracle_text =
        result.case.oracle
        |> Map.get(:expectedClaims, [])
        |> Enum.map(&Map.get(&1, :description))
        |> MapSet.new()

      Enum.any?(result.final_claims, &MapSet.member?(oracle_text, &1.claim))
    end)
  end

  defp case_name_leak?(report) do
    Enum.any?(report.results || [], fn result ->
      Enum.any?(result.final_claims, fn claim ->
        String.contains?(String.downcase(claim.claim || ""), String.downcase(result.case.id))
      end)
    end)
  end

  defp path_category_coupling?(report) do
    hits =
      Enum.flat_map(report.results || [], fn result ->
        expected_by_id =
          result.case.oracle
          |> Map.get(:expectedClaims, [])
          |> Map.new(&{&1.id, &1})

        result.final_claims
        |> Enum.filter(&(&1.publish_decision == "publish"))
        |> Enum.filter(&Map.has_key?(expected_by_id, &1.dedupe_key))
        |> Enum.map(fn claim ->
          {result.case, claim, Map.fetch!(expected_by_id, claim.dedupe_key)}
        end)
      end)

    hits != [] and Enum.all?(hits, &path_or_case_contains_category?/1)
  end

  defp path_or_case_contains_category?({bench_case, claim, expected}) do
    category =
      expected
      |> Map.get(:category, "")
      |> to_string()
      |> String.downcase()

    haystack =
      [bench_case.id, claim.path]
      |> Enum.join(" ")
      |> String.downcase()

    category != "" and String.contains?(haystack, category)
  end

  defp perfect?(report, cases) do
    expected_count(cases) > 0 and report.score.hits == expected_count(cases) and
      report.score.noise == 0
  end

  defp maybe_warning(warnings, true, warning), do: [warning | warnings]
  defp maybe_warning(warnings, _false, _warning), do: warnings

  defp score_or_zero(nil), do: zero_score()
  defp score_or_zero(report), do: report.score
  defp method_id(nil), do: nil
  defp method_id(report), do: report.method.id

  defp expected_count(cases) do
    cases
    |> Enum.map(&(Map.get(&1.oracle, :expectedClaims, []) |> length()))
    |> Enum.sum()
  end

  defp score_rank(score), do: {score.f1, score.usefulness, score.snr}
  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den

  defp zero_score do
    %{
      hits: 0,
      noise: 0,
      recall: 0.0,
      usefulness: 0.0,
      snr: 0.0,
      f1: 0.0
    }
  end
end

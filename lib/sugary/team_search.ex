defmodule Sugary.TeamSearch do
  alias Sugary.Protocol.{ReviewerResult, ReviewTeam}

  def run!(pack_path, suite, opts \\ []) do
    pack = Sugary.ReviewerPacks.load!(pack_path)
    max_team_size = Keyword.get(opts, :max_team_size, 3)
    split = Keyword.get(opts, :split)
    cases = Sugary.Fixtures.load_suite!(suite, split: split)
    run_dir = make_run_dir(pack.id)
    File.mkdir_p!(run_dir)

    reviewer_results = evaluate_reviewers(pack.reviewers, cases)
    team_results = evaluate_teams(pack, cases, reviewer_results, max_team_size)
    metrics = complementarity_metrics(pack, cases, reviewer_results, team_results, max_team_size)

    metrics =
      Map.merge(metrics, %{suite: suite, split: split, holdout_warning: holdout_warning(split)})

    write_artifacts!(run_dir, pack_path, pack, metrics)
    run_dir
  end

  def load_pack!(path), do: Sugary.ReviewerPacks.load!(path)

  def reviewer_subsets(reviewers, max_team_size) do
    max = min(max_team_size, length(reviewers))

    sized =
      1..max
      |> Enum.flat_map(&combinations(reviewers, &1))

    if length(reviewers) > max_team_size do
      sized ++ [reviewers]
    else
      sized
    end
  end

  def complementarity_metrics(pack, cases, reviewer_results, team_results, max_team_size \\ 3) do
    reviewer_metrics = reviewer_metrics(pack.reviewers, cases, reviewer_results)
    best_single = Enum.max_by(reviewer_metrics, &score_rank(&1.score), fn -> nil end)
    team_metrics = team_metrics(team_results, best_single, max_team_size)
    full_team = Enum.find(team_metrics, & &1.full_team)
    oracle = oracle_union_upper_bound(cases, reviewer_metrics)
    coverage = coverage_matrix(cases, reviewer_metrics)
    promotion = promotion_decision(team_metrics, best_single)

    %{
      pack_id: pack.id,
      suite_cases: length(cases),
      reviewer_metrics: reviewer_metrics,
      team_metrics: team_metrics,
      best_single_reviewer: best_single,
      best_pair: best_team_of_size(team_metrics, 2),
      best_team_of_3: best_team_of_size(team_metrics, 3),
      full_team: full_team,
      oracle_union_upper_bound: oracle,
      avoidable_noise_from_union: oracle.avoidable_noise,
      coverage_matrix: coverage,
      uncovered_categories: uncovered_categories(cases, reviewer_metrics),
      promotion: promotion
    }
  end

  def render_report(metrics) do
    reviewer_rows =
      metrics.reviewer_metrics
      |> Enum.map(fn reviewer ->
        "| #{reviewer.id} | #{Enum.join(reviewer.capabilities, ", ")} | #{reviewer.score.hits} | #{reviewer.unique_hits} | #{reviewer.duplicate_hits} | #{reviewer.score.noise} | #{fmt(reviewer.score.usefulness)} | #{fmt(reviewer.score.snr)} | #{fmt(reviewer.marginal_f1)} | #{fmt(reviewer.marginal_usefulness)} | #{fmt(reviewer.marginal_snr)} | #{reviewer.decision} |"
      end)
      |> Enum.join("\n")

    team_rows =
      metrics.team_metrics
      |> Enum.map(fn team ->
        "| #{team.id} | #{Enum.join(team.reviewer_ids, " + ")} | #{fmt(team.score.recall)} | #{fmt(team.score.usefulness)} | #{fmt(team.score.snr)} | #{fmt(team.score.avg_comments_per_pr)} | #{if team.beats_best_individual, do: "yes", else: "no"} | #{team.decision} |"
      end)
      |> Enum.join("\n")

    coverage_rows =
      metrics.coverage_matrix
      |> Enum.map(fn row ->
        reviewer_cells =
          metrics.reviewer_metrics
          |> Enum.map(fn reviewer ->
            if Map.get(row.reviewers, reviewer.id), do: "yes", else: "no"
          end)
          |> Enum.join(" | ")

        "| #{row.case_id} | #{row.expected_claim} | #{reviewer_cells} |"
      end)
      |> Enum.join("\n")

    reviewer_headers =
      metrics.reviewer_metrics
      |> Enum.map(& &1.id)
      |> Enum.join(" | ")

    reviewer_separators =
      metrics.reviewer_metrics
      |> Enum.map(fn _ -> "---" end)
      |> Enum.join(" | ")

    """
    # Complementarity Report: #{metrics.pack_id}

    Suite: `#{metrics[:suite] || "unknown"}`#{if metrics[:split], do: " / split: `" <> metrics[:split] <> "`", else: ""}

    #{metrics[:holdout_warning] || ""}

    ## Decision

    #{metrics.promotion.summary}

    ## Direct Answers

    - Did any team beat the best individual reviewer? #{if Enum.any?(metrics.team_metrics, & &1.beats_best_individual), do: "yes", else: "no"}
    - Best individual reviewer: #{maybe_id(metrics.best_single_reviewer)}
    - Best pair: #{maybe_id(metrics.best_pair)}
    - Best team of 3: #{maybe_id(metrics.best_team_of_3)}
    - Full team: #{maybe_id(metrics.full_team)}
    - Reviewer with most unique true positives: #{most(metrics.reviewer_metrics, :unique_hits)}
    - Reviewer adding most noise: #{most_score(metrics.reviewer_metrics, [:score, :noise])}
    - Next specialist reviewer to build: #{next_specialist(metrics.uncovered_categories)}

    ## Reviewer Complementarity

    | Reviewer | Capabilities | Hits | Unique Hits | Duplicate Hits | Noise | Usefulness | SNR | Marginal F1 | Marginal Usefulness | Marginal SNR | Decision |
    | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
    #{reviewer_rows}

    ## Team Search

    | Team | Reviewers | Recall | Usefulness | SNR | Avg Comments | Beats Best Individual? | Decision |
    | --- | --- | --- | --- | --- | --- | --- | --- |
    #{team_rows}

    ## Oracle Union Upper Bound

    - Hits if all true claims were kept: #{metrics.oracle_union_upper_bound.hits}
    - Recall: #{fmt(metrics.oracle_union_upper_bound.recall)}
    - F1: #{fmt(metrics.oracle_union_upper_bound.f1)}
    - Avoidable union noise: #{metrics.avoidable_noise_from_union}

    ## Fixture Coverage Matrix

    | Case | Expected Claim | #{reviewer_headers} |
    | --- | --- | #{reviewer_separators} |
    #{coverage_rows}

    ## Interpretation

    Team promotion requires beating the best individual on F1 or usefulness-adjusted F1, SNR loss under 10%, staying under comment budget, at least one unique true positive beyond the best individual, and no net noise after merge/ranking. Fixture-only results are research signals, not benchmark superiority claims.
    """
  end

  defp evaluate_reviewers(reviewers, cases) do
    Enum.map(reviewers, fn reviewer ->
      method = Sugary.Methods.from_team_reviewer(reviewer)

      case_results =
        Enum.map(cases, fn bench_case ->
          Sugary.Pipeline.run_case(bench_case, method)
        end)

      %{
        id: Sugary.ReviewerPacks.reviewer_id(reviewer),
        reviewer: reviewer,
        method: method,
        capabilities: Sugary.ReviewerPacks.capabilities(reviewer),
        case_results: case_results,
        score: Sugary.Scorer.score(method.id, case_results),
        hit_keys: hit_keys(cases, case_results),
        noise_keys: noise_keys(cases, case_results),
        published_keys: published_keys(case_results)
      }
    end)
  end

  defp evaluate_teams(pack, cases, reviewer_results, max_team_size) do
    reviewers = pack.reviewers

    reviewers
    |> reviewer_subsets(max_team_size)
    |> Enum.map(fn subset ->
      subset_ids = Enum.map(subset, &Sugary.ReviewerPacks.reviewer_id/1)
      team_id = team_id(subset_ids, length(reviewers))

      team =
        ReviewTeam.new(%{
          id: team_id,
          description: "Generated complementarity search team.",
          reviewers: subset,
          failure_policy: "continue",
          merge_strategy: "dedupe_by_key_location_and_claim",
          max_published_claims: 3,
          metadata: %{pack_id: pack.id, generated_by: "team_search"},
          artifact_fields: []
        })

      case_results =
        Enum.map(cases, fn bench_case ->
          synthesize_team_case(bench_case, team, subset_ids, reviewer_results)
        end)

      score = Sugary.Scorer.score(team_id, case_results)

      %{
        id: team_id,
        reviewer_ids: subset_ids,
        size: length(subset_ids),
        full_team: length(subset_ids) == length(reviewers),
        case_results: case_results,
        score: score
      }
    end)
  end

  defp synthesize_team_case(bench_case, team, subset_ids, reviewer_results) do
    selected =
      reviewer_results
      |> Enum.filter(&(&1.id in subset_ids))

    selected_case_results =
      selected
      |> Enum.map(fn reviewer ->
        result = Enum.find(reviewer.case_results, &(&1.case.id == bench_case.id))
        annotate_case_result(result, reviewer.id)
      end)

    raw_claims = Enum.flat_map(selected_case_results, & &1.candidate_claims)

    merge_candidates =
      selected_case_results
      |> Enum.flat_map(& &1.final_claims)
      |> Enum.reject(&(&1.publish_decision == "suppress"))

    merged = Sugary.Teams.merge_claims(merge_candidates, team)
    final = Sugary.Teams.publish_claims(merged, team)
    duration = selected_case_results |> Enum.map(& &1.reviewer_result.latency_ms) |> Enum.sum()
    cost = selected_case_results |> Enum.map(& &1.reviewer_result.cost) |> Enum.sum()

    %{
      case: bench_case,
      input: Sugary.Fixtures.input_bundle(bench_case, %{id: team.id, type: "team_search"}),
      reviewer_result:
        ReviewerResult.new(%{
          reviewer_id: team.id,
          method_id: team.id,
          class: "team_search",
          claims: final,
          cost: cost,
          latency_ms: duration,
          artifacts: [],
          errors: []
        }),
      candidate_claims: merged,
      final_claims: final,
      team: %{
        manifest: team,
        reviewer_runs: [],
        raw_claims: raw_claims,
        merge_candidates: merge_candidates,
        merged_claims: merged,
        published_claims: Enum.filter(final, &(&1.publish_decision == "publish")),
        provenance: [],
        failure_reason: nil,
        execution_mode: "cached_sequential"
      }
    }
  end

  defp annotate_case_result(result, reviewer_id) do
    result_id = "#{result.case.id}--#{reviewer_id}"

    %{
      result
      | candidate_claims:
          Enum.map(result.candidate_claims, &annotate_claim(&1, reviewer_id, result_id)),
        final_claims: Enum.map(result.final_claims, &annotate_claim(&1, reviewer_id, result_id))
    }
  end

  defp annotate_claim(claim, reviewer_id, result_id) do
    claim = atomize(claim)
    source = Map.get(claim, :source, %{})
    Map.put(claim, :source, Map.merge(source, %{reviewer_id: reviewer_id, result_id: result_id}))
  end

  defp reviewer_metrics(_reviewers, cases, reviewer_results) do
    expected_count = total_expected(cases)
    stronger = stronger_reviewer_map(reviewer_results)

    full_team_score =
      reviewer_results
      |> Enum.map(& &1.id)
      |> then(fn ids -> full_team_score_from_reviewers(cases, reviewer_results, ids) end)

    Enum.map(reviewer_results, fn reviewer ->
      duplicate_hits =
        reviewer.hit_keys
        |> Enum.count(fn hit ->
          Enum.any?(
            reviewer_results,
            &(&1.id != reviewer.id and MapSet.member?(&1.hit_keys, hit))
          )
        end)

      unique_hits =
        reviewer.hit_keys
        |> Enum.reject(fn hit ->
          Enum.any?(Map.get(stronger, reviewer.id, []), &MapSet.member?(&1.hit_keys, hit))
        end)
        |> length()

      without =
        reviewer_results
        |> Enum.reject(&(&1.id == reviewer.id))
        |> Enum.map(& &1.id)
        |> then(fn ids -> full_team_score_from_reviewers(cases, reviewer_results, ids) end)

      reviewer
      |> Map.put(:expected_claims, expected_count)
      |> Map.put(:unique_hits, unique_hits)
      |> Map.put(:duplicate_hits, duplicate_hits)
      |> Map.put(:marginal_f1, full_team_score.f1 - without.f1)
      |> Map.put(:marginal_usefulness, full_team_score.usefulness - without.usefulness)
      |> Map.put(:marginal_snr, full_team_score.snr - without.snr)
      |> Map.put(:decision, reviewer_decision(reviewer, unique_hits))
      |> Map.drop([:case_results])
    end)
  end

  defp full_team_score_from_reviewers(_cases, _reviewer_results, []), do: zero_score("empty")

  defp full_team_score_from_reviewers(cases, reviewer_results, ids) do
    team =
      ReviewTeam.new(%{
        id: "counterfactual",
        reviewers: [],
        failure_policy: "continue",
        merge_strategy: "dedupe_by_key_location_and_claim",
        max_published_claims: 3
      })

    results =
      Enum.map(cases, fn bench_case ->
        synthesize_team_case(bench_case, team, ids, reviewer_results)
      end)

    Sugary.Scorer.score("counterfactual", results)
  end

  defp team_metrics(team_results, best_single, max_team_size) do
    Enum.map(team_results, fn team ->
      unique_beyond_best =
        if best_single do
          team_hit_keys(team.case_results)
          |> MapSet.difference(best_single.hit_keys)
          |> MapSet.size()
        else
          0
        end

      beats_best =
        best_single &&
          (team.score.f1 > best_single.score.f1 or
             usefulness_adjusted_f1(team.score) > usefulness_adjusted_f1(best_single.score))

      policy = promotion_status(team, best_single, unique_beyond_best)

      team
      |> Map.drop([:case_results])
      |> Map.put(:unique_hits_beyond_best_individual, unique_beyond_best)
      |> Map.put(:beats_best_individual, beats_best)
      |> Map.put(:comment_budget, 3)
      |> Map.put(:max_team_size, max_team_size)
      |> Map.put(:decision, policy)
    end)
  end

  defp promotion_decision(_team_metrics, nil) do
    %{
      promoted_team: nil,
      summary: "No team promoted. No individual reviewer baseline was available."
    }
  end

  defp promotion_decision(team_metrics, _best_single) do
    candidates =
      team_metrics
      |> Enum.filter(&(&1.decision == "promote"))

    case Enum.max_by(candidates, &score_rank(&1.score), fn -> nil end) do
      nil ->
        %{
          promoted_team: nil,
          summary: "No team promoted. Best individual reviewer remains the default."
        }

      team ->
        %{
          promoted_team: team.id,
          summary: "Promote `#{team.id}` for this fixture-only complementarity run."
        }
    end
  end

  defp promotion_status(_team, nil, _unique_beyond_best), do: "reject:no_best_single"

  defp promotion_status(team, best_single, unique_beyond_best) do
    beats =
      team.score.f1 > best_single.score.f1 or
        usefulness_adjusted_f1(team.score) > usefulness_adjusted_f1(best_single.score)

    snr_ok = team.score.snr >= best_single.score.snr * 0.9
    comments_ok = team.score.avg_comments_per_pr <= 3
    unique_ok = unique_beyond_best > 0
    noise_ok = team.score.noise <= best_single.score.noise

    if beats and snr_ok and comments_ok and unique_ok and noise_ok do
      "promote"
    else
      "reject"
    end
  end

  defp oracle_union_upper_bound(cases, reviewer_metrics) do
    hits =
      reviewer_metrics
      |> Enum.reduce(MapSet.new(), &MapSet.union(&1.hit_keys, &2))
      |> MapSet.size()

    expected = total_expected(cases)
    precision = if hits == 0, do: 0.0, else: 1.0
    recall = ratio(hits, expected)
    f1 = if precision + recall == 0, do: 0.0, else: 2 * precision * recall / (precision + recall)

    %{
      hits: hits,
      expected_claims: expected,
      published_claims: hits,
      noise: 0,
      precision: precision,
      recall: recall,
      f1: f1,
      usefulness: precision,
      snr: hits * 1.0,
      avoidable_noise:
        reviewer_metrics
        |> Enum.reduce(MapSet.new(), &MapSet.union(&1.noise_keys, &2))
        |> MapSet.size()
    }
  end

  defp coverage_matrix(cases, reviewer_metrics) do
    Enum.flat_map(cases, fn bench_case ->
      expected_claims = Map.get(bench_case.oracle, :expectedClaims, [])

      Enum.map(expected_claims, fn expected ->
        key = claim_key(bench_case.id, expected.id)

        %{
          case_id: bench_case.id,
          expected_claim: expected.id,
          category: Map.get(expected, :category, "bug"),
          reviewers:
            Map.new(reviewer_metrics, fn reviewer ->
              {reviewer.id, MapSet.member?(reviewer.hit_keys, key)}
            end)
        }
      end)
    end)
  end

  defp uncovered_categories(cases, reviewer_metrics) do
    covered =
      reviewer_metrics
      |> Enum.reduce(MapSet.new(), &MapSet.union(&1.hit_keys, &2))

    cases
    |> Enum.flat_map(fn bench_case ->
      bench_case.oracle
      |> Map.get(:expectedClaims, [])
      |> Enum.reject(&MapSet.member?(covered, claim_key(bench_case.id, &1.id)))
      |> Enum.map(&Map.get(&1, :category, "bug"))
    end)
    |> Enum.frequencies()
  end

  defp stronger_reviewer_map(reviewer_results) do
    Map.new(reviewer_results, fn reviewer ->
      stronger =
        reviewer_results
        |> Enum.filter(&(score_rank(&1.score) > score_rank(reviewer.score)))

      {reviewer.id, stronger}
    end)
  end

  defp hit_keys(cases, case_results) do
    expected_by_case = Map.new(cases, &{&1.id, expected_ids(&1)})

    case_results
    |> Enum.flat_map(fn result ->
      expected = Map.fetch!(expected_by_case, result.case.id)

      result.final_claims
      |> Enum.filter(&(&1.publish_decision == "publish"))
      |> Enum.filter(&MapSet.member?(expected, &1.dedupe_key))
      |> Enum.map(&claim_key(result.case.id, &1.dedupe_key))
    end)
    |> MapSet.new()
  end

  defp noise_keys(cases, case_results) do
    expected_by_case = Map.new(cases, &{&1.id, expected_ids(&1)})
    known_noise_by_case = Map.new(cases, &{&1.id, known_noise_ids(&1)})

    case_results
    |> Enum.flat_map(fn result ->
      expected = Map.fetch!(expected_by_case, result.case.id)
      known_noise = Map.fetch!(known_noise_by_case, result.case.id)

      result.final_claims
      |> Enum.filter(&(&1.publish_decision == "publish"))
      |> Enum.reject(&MapSet.member?(expected, &1.dedupe_key))
      |> Enum.map(fn claim ->
        kind = if MapSet.member?(known_noise, claim.dedupe_key), do: "known", else: "unsupported"
        claim_key(result.case.id, "#{kind}:#{claim.dedupe_key}")
      end)
    end)
    |> MapSet.new()
  end

  defp published_keys(case_results) do
    case_results
    |> Enum.flat_map(fn result ->
      result.final_claims
      |> Enum.filter(&(&1.publish_decision == "publish"))
      |> Enum.map(&claim_key(result.case.id, &1.dedupe_key))
    end)
    |> MapSet.new()
  end

  defp team_hit_keys(case_results) do
    case_results
    |> Enum.flat_map(fn result ->
      expected = expected_ids(result.case)

      result.final_claims
      |> Enum.filter(&(&1.publish_decision == "publish"))
      |> Enum.filter(&MapSet.member?(expected, &1.dedupe_key))
      |> Enum.map(&claim_key(result.case.id, &1.dedupe_key))
    end)
    |> MapSet.new()
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

  defp total_expected(cases) do
    cases
    |> Enum.map(&(Map.get(&1.oracle, :expectedClaims, []) |> length()))
    |> Enum.sum()
  end

  defp best_team_of_size(team_metrics, size) do
    team_metrics
    |> Enum.filter(&(&1.size == size))
    |> Enum.max_by(&score_rank(&1.score), fn -> nil end)
  end

  defp reviewer_decision(reviewer, unique_hits) do
    cond do
      reviewer.score.noise > reviewer.score.hits -> "quarantine"
      unique_hits > 0 -> "keep:unique_signal"
      reviewer.score.hits > 0 -> "keep:duplicate_signal"
      true -> "reject:no_signal"
    end
  end

  defp write_artifacts!(run_dir, pack_path, pack, metrics) do
    File.cp!(pack_path, Path.join(run_dir, "pack-manifest.toml"))
    Sugary.Json.write!(Path.join(run_dir, "pack.json"), pack)

    Sugary.Json.write!(
      Path.join(run_dir, "reviewer-scorecards.json"),
      json_safe(metrics.reviewer_metrics)
    )

    Sugary.Json.write!(
      Path.join(run_dir, "team-scorecards.json"),
      json_safe(metrics.team_metrics)
    )

    Sugary.Json.write!(Path.join(run_dir, "coverage-matrix.json"), metrics.coverage_matrix)

    Sugary.Json.write!(
      Path.join(run_dir, "complementarity-summary.json"),
      json_safe(%{
        pack_id: metrics.pack_id,
        suite: metrics[:suite],
        split: metrics[:split],
        holdout_warning: metrics[:holdout_warning],
        best_single_reviewer: metrics.best_single_reviewer,
        best_pair: metrics.best_pair,
        best_team_of_3: metrics.best_team_of_3,
        full_team: metrics.full_team,
        promotion: metrics.promotion,
        avoidable_noise_from_union: metrics.avoidable_noise_from_union,
        uncovered_categories: metrics.uncovered_categories
      })
    )

    Sugary.Json.write!(
      Path.join(run_dir, "oracle-union-upper-bound.json"),
      metrics.oracle_union_upper_bound
    )

    Sugary.Json.write!(Path.join(run_dir, "promotion.json"), metrics.promotion)
    File.write!(Path.join(run_dir, "report.md"), render_report(metrics))
  end

  defp make_run_dir(pack_id) do
    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%dT%H%M%SZ")

    Path.join(".sugary/research/runs", "#{timestamp}-team-search-#{pack_id}")
  end

  defp holdout_warning("holdout"),
    do:
      "Holdout warning: reviewer inputs were blinded. Verify these methods were not tuned against this split before making promotion claims."

  defp holdout_warning(_split), do: nil

  defp combinations(_items, 0), do: [[]]
  defp combinations([], _size), do: []

  defp combinations([item | rest], size) do
    Enum.map(combinations(rest, size - 1), &[item | &1]) ++ combinations(rest, size)
  end

  defp team_id(ids, full_size) do
    if length(ids) == full_size do
      "full-team"
    else
      "team-" <> Enum.join(ids, "--")
    end
  end

  defp usefulness_adjusted_f1(score), do: score.f1 * score.usefulness
  defp score_rank(score), do: {score.f1, score.usefulness, score.snr}
  defp claim_key(case_id, dedupe_key), do: "#{case_id}::#{dedupe_key}"
  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den

  defp zero_score(method_id) do
    Sugary.Protocol.Scorecard.new(%{
      method_id: method_id,
      cases: 0,
      expected_claims: 0,
      published_claims: 0,
      hits: 0,
      valid_suggestions: 0,
      noise: 0,
      suppressed_true_claims: 0,
      precision: 0.0,
      recall: 0.0,
      f1: 0.0,
      usefulness: 0.0,
      snr: 0.0,
      avg_comments_per_pr: 0.0,
      cost: 0.0,
      latency_ms: 0
    })
  end

  defp atomize(%{} = map),
    do: Map.new(map, fn {key, value} -> {atom_key(key), atomize(value)} end)

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value
  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)

  defp json_safe(%MapSet{} = set), do: set |> MapSet.to_list() |> Enum.sort()
  defp json_safe(%_module{} = struct), do: struct |> Map.from_struct() |> json_safe()
  defp json_safe(%{} = map), do: Map.new(map, fn {key, value} -> {key, json_safe(value)} end)
  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(value), do: value

  defp maybe_id(nil), do: "none"
  defp maybe_id(%{id: id}), do: id

  defp most([], _key), do: "none"

  defp most(items, key) do
    items
    |> Enum.max_by(&Map.get(&1, key, 0))
    |> Map.get(:id)
  end

  defp most_score([], _path), do: "none"

  defp most_score(items, path) do
    item = Enum.max_by(items, &path_get(&1, path))

    if path_get(item, path) == 0 do
      "none"
    else
      Map.get(item, :id)
    end
  end

  defp path_get(value, []), do: value
  defp path_get(value, [key | rest]), do: value |> Map.get(key) |> path_get(rest)

  defp next_specialist(uncovered) when map_size(uncovered) == 0, do: "none from current fixtures"

  defp next_specialist(uncovered) do
    {category, _count} = Enum.max_by(uncovered, fn {_category, count} -> count end)
    "#{category} specialist"
  end

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)
end

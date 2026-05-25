defmodule Sugary.Teams do
  alias Sugary.Protocol.{ReviewerResult, ReviewTeam}

  @default_failure_policy "continue"
  @default_merge_strategy "dedupe_by_key_location_and_claim"
  @default_max_published_claims 3

  def load!(path), do: Sugary.Toml.parse_team_file!(path)

  def run_case(bench_case, %{type: "team"} = team_method) do
    team = load!(team_method.team_path)
    run_case_with_team(bench_case, team_method, team)
  end

  def run_case_with_team(bench_case, team_method, %ReviewTeam{} = team) do
    started = System.monotonic_time(:millisecond)
    input = Sugary.Fixtures.input_bundle(bench_case, team_method)

    reviewer_runs =
      team.reviewers
      |> Enum.map(&Sugary.Methods.from_team_reviewer/1)
      |> Enum.map(&inherit_team_options(&1, team_method))
      |> run_reviewers_sequentially(bench_case)

    raw_claims = Enum.flat_map(reviewer_runs, & &1.raw_claims)
    merge_candidates = Enum.flat_map(reviewer_runs, & &1.merge_candidates)
    failure_reason = team_failure_reason(team, reviewer_runs)

    {merged_claims, final_claims, provenance} =
      if failure_reason do
        {[], [], []}
      else
        merged = merge_claims(merge_candidates, team)
        {merged, publish_claims(merged, team), provenance_records(merged)}
      end

    duration_ms = System.monotonic_time(:millisecond) - started

    reviewer_result =
      ReviewerResult.new(%{
        reviewer_id: team_method.id,
        method_id: team_method.id,
        class: "team",
        claims: Enum.map(final_claims, &claim_to_map/1),
        cost: Enum.reduce(reviewer_runs, 0.0, &(&1.cost + &2)),
        latency_ms: duration_ms,
        artifacts: [team_artifact(team, reviewer_runs, raw_claims, merged_claims)],
        errors: team_errors(failure_reason, reviewer_runs)
      })

    %{
      case: bench_case,
      input: input,
      reviewer_result: reviewer_result,
      candidate_claims: merged_claims,
      final_claims: final_claims,
      team: %{
        manifest: team,
        reviewer_runs: reviewer_runs,
        raw_claims: raw_claims,
        merge_candidates: merge_candidates,
        merged_claims: merged_claims,
        published_claims: Enum.filter(final_claims, &(&1.publish_decision == "publish")),
        provenance: provenance,
        failure_reason: failure_reason,
        execution_mode: "sequential"
      }
    }
  end

  def contributions(team_results, team_score) do
    reviewer_ids =
      team_results
      |> Enum.flat_map(& &1.team.reviewer_runs)
      |> Enum.map(& &1.reviewer_id)
      |> Enum.uniq()

    Enum.map(reviewer_ids, fn reviewer_id ->
      individual_results = individual_results(team_results, reviewer_id)
      individual_score = Sugary.Scorer.score(reviewer_id, individual_results)
      without_score = score_without_reviewer(team_results, reviewer_id)

      %{
        reviewer_id: reviewer_id,
        individual_score: individual_score,
        raw_claims: raw_claim_count(team_results, reviewer_id),
        hits: individual_score.hits,
        noise: individual_score.noise,
        unique_hits_contributed_to_team: unique_hits(team_results, reviewer_id),
        duplicate_claims: duplicate_claims(team_results, reviewer_id),
        claims_suppressed_by_merge_or_ranking: suppressed_by_team(team_results, reviewer_id),
        marginal_team_contribution: team_score.f1 - without_score.f1,
        reviewer_failures: reviewer_failures(team_results, reviewer_id)
      }
    end)
  end

  def score_without_reviewer(team_results, reviewer_id) do
    results =
      Enum.map(team_results, fn result ->
        team = result.team.manifest

        kept =
          result.team.merge_candidates
          |> Enum.reject(&(reviewer_id_for_claim(&1) == reviewer_id))

        merged = merge_claims(kept, team)
        final = publish_claims(merged, team)

        %{
          case: result.case,
          input: result.input,
          reviewer_result:
            ReviewerResult.new(%{
              reviewer_id: result.reviewer_result.reviewer_id <> "-without-" <> reviewer_id,
              method_id: result.reviewer_result.method_id <> "-without-" <> reviewer_id,
              class: "team_counterfactual",
              claims: Enum.map(final, &claim_to_map/1),
              cost: 0.0,
              latency_ms: 0,
              artifacts: [],
              errors: []
            }),
          candidate_claims: merged,
          final_claims: final
        }
      end)

    Sugary.Scorer.score("without-#{reviewer_id}", results)
  end

  def write_artifacts!(method_dir, team_method, team_results, score, contributions, failures) do
    team = team_results |> List.first() |> get_in([:team, :manifest])
    write_team_manifest!(method_dir, team_method, team)
    write_reviewer_results!(method_dir, team_results)

    write_jsonl!(
      Path.join(method_dir, "raw-claims.jsonl"),
      Enum.flat_map(team_results, & &1.team.raw_claims)
    )

    write_jsonl!(
      Path.join(method_dir, "merged-claims.jsonl"),
      Enum.flat_map(team_results, & &1.team.merged_claims)
    )

    write_jsonl!(
      Path.join(method_dir, "published-claims.jsonl"),
      Enum.flat_map(team_results, & &1.team.published_claims)
    )

    Sugary.Json.write!(
      Path.join(method_dir, "provenance.json"),
      Map.new(team_results, &{&1.case.id, &1.team.provenance})
    )

    Sugary.Json.write!(
      Path.join(method_dir, "team-scorecard.json"),
      team_scorecard(team_method.id, team_results, score, contributions)
    )

    Sugary.Json.write!(Path.join(method_dir, "reviewer-contributions.json"), contributions)
    write_jsonl!(Path.join(method_dir, "failures.jsonl"), failures)

    File.write!(
      Path.join(method_dir, "report.md"),
      render_team_report(team_method, score, contributions, team_results)
    )
  end

  def team_scorecard(team_id, team_results, score, contributions) do
    %{
      team_id: team_id,
      raw_claims: team_results |> Enum.flat_map(& &1.team.raw_claims) |> length(),
      merged_claims: team_results |> Enum.flat_map(& &1.team.merged_claims) |> length(),
      published_claims: score.published_claims,
      hits: score.hits,
      valid_suggestions: score.valid_suggestions,
      noise: score.noise,
      suppressed_true_claims: score.suppressed_true_claims,
      precision: score.precision,
      recall: score.recall,
      f1: score.f1,
      usefulness: score.usefulness,
      snr: score.snr,
      average_comments_per_pr: score.avg_comments_per_pr,
      estimated_cost: score.cost,
      latency_ms: score.latency_ms,
      reviewer_failures: Enum.reduce(contributions, 0, &(&1.reviewer_failures + &2))
    }
  end

  def render_team_report(team_method, score, contributions, team_results) do
    best_single =
      Enum.max_by(contributions, & &1.individual_score.f1, fn -> nil end)

    beat_best? = best_single && score.f1 > best_single.individual_score.f1

    reviewer_rows =
      contributions
      |> Enum.map(fn contribution ->
        s = contribution.individual_score

        "| #{contribution.reviewer_id} | #{fmt(s.recall)} | #{fmt(s.usefulness)} | #{fmt(s.snr)} | #{s.published_claims} | #{contribution.raw_claims} | #{contribution.unique_hits_contributed_to_team} | #{fmt(contribution.marginal_team_contribution)} | #{contribution.reviewer_failures} |"
      end)
      |> Enum.join("\n")

    raw_count = team_results |> Enum.flat_map(& &1.team.raw_claims) |> length()
    merged_count = team_results |> Enum.flat_map(& &1.team.merged_claims) |> length()
    failure_count = Enum.reduce(contributions, 0, &(&1.reviewer_failures + &2))

    """
    # Review Team Report: #{team_method.id}

    ## Team Scorecard

    | Recall | Usefulness | SNR | F1 | Avg Comments | Cost | Latency |
    | --- | --- | --- | --- | --- | --- | --- |
    | #{fmt(score.recall)} | #{fmt(score.usefulness)} | #{fmt(score.snr)} | #{fmt(score.f1)} | #{fmt(score.avg_comments_per_pr)} | #{fmt(score.cost)} | #{score.latency_ms} |

    ## Merge Summary

    - Raw claims: #{raw_count}
    - Merged claims: #{merged_count}
    - Published claims: #{score.published_claims}
    - Reviewer failures: #{failure_count}

    ## Reviewer Contributions

    | Reviewer | Recall | Usefulness | SNR | Published | Raw Claims | Unique Team Hits | Marginal F1 | Failures |
    | --- | --- | --- | --- | --- | --- | --- | --- | --- |
    #{reviewer_rows}

    ## Architecture Check

    - Beat best single reviewer by F1: #{if beat_best?, do: "yes", else: "no"}
    - Improved usefulness/SNR without bloating comment count: #{comment_bloat_summary(score, best_single)}
    - External reviewers still produce claims only; Sugary owns merge, ranking, scoring, reports, and publishing decisions.
    """
  end

  defp run_reviewers_sequentially(reviewer_methods, bench_case) do
    reviewer_methods
    |> Enum.with_index(1)
    |> Enum.map(fn {method, order} ->
      result =
        if Map.get(method, :type) == "team" do
          run_case(bench_case, method)
        else
          Sugary.Pipeline.run_case(bench_case, method)
        end

      result_id = "#{bench_case.id}--#{method.id}--#{order}"

      final_claims =
        result.final_claims
        |> Enum.map(&annotate_claim(&1, method.id, result_id, order))

      raw_claims =
        result.candidate_claims
        |> Enum.map(&annotate_claim(&1, method.id, result_id, order))

      %{
        reviewer_id: method.id,
        method: method,
        order: order,
        result_id: result_id,
        case_result: %{result | final_claims: final_claims, candidate_claims: raw_claims},
        reviewer_result: result.reviewer_result,
        raw_claims: raw_claims,
        merge_candidates: Enum.reject(final_claims, &(&1.publish_decision == "suppress")),
        failed: reviewer_failed?(result),
        cost: result.reviewer_result.cost || 0.0,
        latency_ms: result.reviewer_result.latency_ms || 0
      }
    end)
  end

  defp inherit_team_options(method, team_method) do
    method
    |> put_inherited(:replay_mode, team_method)
  end

  defp put_inherited(method, key, source) do
    case {Map.get(method, key), Map.get(source, key)} do
      {nil, value} when value not in [nil, ""] -> Map.put(method, key, value)
      _other -> method
    end
  end

  defp team_failure_reason(team, reviewer_runs) do
    failed = Enum.filter(reviewer_runs, & &1.failed)
    success_count = Enum.count(reviewer_runs, &(not &1.failed))

    case team.failure_policy || @default_failure_policy do
      "fail_team" ->
        if failed == [], do: nil, else: "reviewer_failure"

      "require_at_least_one_success" ->
        if success_count > 0, do: nil, else: "no_successful_reviewers"

      _continue ->
        nil
    end
  end

  defp team_errors(nil, reviewer_runs), do: reviewer_error_entries(reviewer_runs)

  defp team_errors(reason, reviewer_runs) do
    [%{reason: reason} | reviewer_error_entries(reviewer_runs)]
  end

  defp reviewer_error_entries(reviewer_runs) do
    reviewer_runs
    |> Enum.filter(& &1.failed)
    |> Enum.map(fn run ->
      %{reason: "reviewer_failed", reviewer_id: run.reviewer_id, result_id: run.result_id}
    end)
  end

  defp reviewer_failed?(result) do
    result.reviewer_result.errors not in [nil, []]
  end

  def merge_claims(raw_claims, team) do
    raw_claims
    |> Enum.map(&claim_to_map/1)
    |> Enum.with_index()
    |> Enum.group_by(fn {claim, _index} -> dedupe_signature(claim) end)
    |> Enum.sort_by(fn {_signature, pairs} -> pairs |> Enum.map(&elem(&1, 1)) |> Enum.min() end)
    |> Enum.with_index(1)
    |> Enum.map(fn {{signature, pairs}, index} ->
      claims = Enum.map(pairs, &elem(&1, 0))
      merge_group(claims, signature, index, team)
    end)
  end

  def publish_claims(claims, team) do
    max_published = team.max_published_claims || @default_max_published_claims

    claims
    |> Enum.sort_by(&rank_score/1, :desc)
    |> Enum.with_index()
    |> Enum.map(fn {claim, index} ->
      cond do
        index < max_published and publishable?(claim) ->
          Map.put(claim, :publish_decision, "publish")

        index < max_published ->
          claim
          |> Map.put(:publish_decision, "suppress")
          |> Map.put(:suppressed_reason, "team_rank_threshold")

        true ->
          claim
          |> Map.put(:publish_decision, "suppress")
          |> Map.put(:suppressed_reason, "team_comment_budget")
      end
    end)
  end

  defp merge_group(claims, signature, index, team) do
    first = hd(claims)
    provenance = Enum.map(claims, &provenance_for_claim/1)
    confidences = Enum.map(claims, &(&1.confidence || 0.0))
    agreement_count = length(provenance)

    merged_confidence =
      min(0.99, Enum.max(confidences, fn -> 0.0 end) + 0.05 * (agreement_count - 1))

    evidence =
      claims
      |> Enum.flat_map(&List.wrap(&1.evidence))
      |> Enum.uniq_by(&Sugary.Json.encode!/1)

    source =
      first
      |> Map.get(:source, %{})
      |> Map.merge(%{
        team_id: team.id,
        provenance: provenance,
        reviewer_ids: provenance |> Enum.map(& &1.reviewer_id) |> Enum.uniq(),
        original_claim_ids: Enum.map(provenance, & &1.claim_id),
        original_confidences: confidences,
        merged_confidence: merged_confidence,
        agreement_count: agreement_count,
        merge_reason: if(agreement_count > 1, do: "dedupe:#{signature}", else: "single_claim")
      })

    first
    |> Map.put(:id, "team-claim-#{String.pad_leading(to_string(index), 3, "0")}")
    |> Map.put(:dedupe_key, public_dedupe_key(signature, first))
    |> Map.put(:evidence, evidence)
    |> Map.put(:confidence, merged_confidence)
    |> Map.put(:source, source)
    |> Map.put(:publish_decision, "candidate")
    |> Map.delete(:suppressed_reason)
  end

  defp provenance_records(merged_claims) do
    Enum.map(merged_claims, fn claim ->
      %{
        claim_id: claim.id,
        dedupe_key: claim.dedupe_key,
        summary: claim.claim,
        provenance: get_in(claim, [:source, :provenance]) || []
      }
    end)
  end

  defp provenance_for_claim(claim) do
    source = Map.get(claim, :source, %{})

    %{
      reviewer_id: Map.get(source, :reviewer_id, Map.get(source, :method)),
      claim_id: claim.id,
      result_id: Map.get(source, :result_id),
      original_dedupe_key: Map.get(claim, :dedupe_key)
    }
  end

  defp annotate_claim(claim, reviewer_id, result_id, order) do
    claim = claim_to_map(claim)
    source = Map.get(claim, :source, %{})

    Map.put(
      claim,
      :source,
      Map.merge(source, %{reviewer_id: reviewer_id, result_id: result_id, order: order})
    )
  end

  defp dedupe_signature(claim) do
    case normalized_dedupe_key(claim) do
      "" ->
        [
          "loc",
          normalize(Map.get(claim, :path, "")),
          Map.get(claim, :start_line) || 1,
          Map.get(claim, :end_line) || Map.get(claim, :start_line) || 1,
          normalize(Map.get(claim, :category, "")),
          normalize(Map.get(claim, :severity, "")),
          canonicalize(Map.get(claim, :claim, ""))
        ]
        |> Enum.join(":")

      key ->
        "key:#{key}"
    end
  end

  defp normalized_dedupe_key(claim) do
    claim
    |> Map.get(:dedupe_key, "")
    |> to_string()
    |> String.trim()
    |> String.downcase()
  end

  defp public_dedupe_key("key:" <> key, _claim), do: key
  defp public_dedupe_key(signature, _claim), do: signature

  defp rank_score(claim) do
    severity =
      %{"critical" => 4, "high" => 3, "medium" => 2, "low" => 1} |> Map.get(claim.severity, 1)

    agreement_count = get_in(claim, [:source, :agreement_count]) || 1
    claim.confidence * severity * agreement_count
  end

  defp publishable?(claim), do: rank_score(claim) > 1.4

  defp team_artifact(team, reviewer_runs, raw_claims, merged_claims) do
    %{
      adapter: "review_team",
      team_id: team.id,
      merge_strategy: team.merge_strategy || @default_merge_strategy,
      failure_policy: team.failure_policy || @default_failure_policy,
      execution_mode: "sequential",
      reviewer_results:
        Enum.map(reviewer_runs, &Map.take(&1, [:reviewer_id, :result_id, :order, :failed])),
      raw_claims: length(raw_claims),
      merged_claims: length(merged_claims)
    }
  end

  defp individual_results(team_results, reviewer_id) do
    team_results
    |> Enum.flat_map(& &1.team.reviewer_runs)
    |> Enum.filter(&(&1.reviewer_id == reviewer_id))
    |> Enum.map(& &1.case_result)
  end

  defp raw_claim_count(team_results, reviewer_id) do
    team_results
    |> claims_for_reviewer(reviewer_id)
    |> length()
  end

  defp duplicate_claims(team_results, reviewer_id) do
    team_results
    |> claims_for_reviewer(reviewer_id)
    |> Enum.group_by(&dedupe_signature/1)
    |> Enum.reduce(0, fn {_signature, claims}, total -> total + max(length(claims) - 1, 0) end)
  end

  defp suppressed_by_team(team_results, reviewer_id) do
    Enum.reduce(team_results, 0, fn result, total ->
      published =
        result.team.published_claims
        |> Enum.filter(fn claim ->
          claim
          |> get_in([:source, :provenance])
          |> List.wrap()
          |> Enum.any?(&(&1.reviewer_id == reviewer_id))
        end)
        |> length()

      raw =
        result.team.raw_claims
        |> Enum.count(&(reviewer_id_for_claim(&1) == reviewer_id))

      total + max(raw - published, 0)
    end)
  end

  defp unique_hits(team_results, reviewer_id) do
    Enum.reduce(team_results, 0, fn result, total ->
      expected = expected_ids(result.case)

      hits =
        result.team.published_claims
        |> Enum.count(fn claim ->
          provenance = get_in(claim, [:source, :provenance]) || []

          MapSet.member?(expected, claim.dedupe_key) and length(provenance) == 1 and
            hd(provenance).reviewer_id == reviewer_id
        end)

      total + hits
    end)
  end

  defp reviewer_failures(team_results, reviewer_id) do
    team_results
    |> Enum.flat_map(& &1.team.reviewer_runs)
    |> Enum.count(&(&1.reviewer_id == reviewer_id and &1.failed))
  end

  defp claims_for_reviewer(team_results, reviewer_id) do
    team_results
    |> Enum.flat_map(& &1.team.raw_claims)
    |> Enum.filter(&(reviewer_id_for_claim(&1) == reviewer_id))
  end

  defp reviewer_id_for_claim(claim), do: claim |> Map.get(:source, %{}) |> Map.get(:reviewer_id)

  defp expected_ids(bench_case) do
    bench_case.oracle
    |> Map.get(:expectedClaims, [])
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp write_team_manifest!(method_dir, team_method, nil) do
    File.write!(Path.join(method_dir, "team-manifest.toml"), "id = \"#{team_method.id}\"\n")
  end

  defp write_team_manifest!(method_dir, _team_method, team) do
    text =
      if team.path && File.exists?(team.path) do
        File.read!(team.path)
      else
        "id = \"#{team.id}\"\n"
      end

    File.write!(Path.join(method_dir, "team-manifest.toml"), text)
  end

  defp write_reviewer_results!(method_dir, team_results) do
    Enum.each(team_results, fn result ->
      Enum.each(result.team.reviewer_runs, fn run ->
        Sugary.Json.write!(
          Path.join([
            method_dir,
            "reviewer-results",
            "#{result.case.id}--#{run.reviewer_id}.json"
          ]),
          run.reviewer_result
        )
      end)
    end)
  end

  defp write_jsonl!(path, records) do
    path |> Path.dirname() |> File.mkdir_p!()

    records
    |> Enum.map(&(Sugary.Json.encode!(&1) <> "\n"))
    |> Enum.join()
    |> then(&File.write!(path, &1))
  end

  defp comment_bloat_summary(_score, nil), do: "no single-reviewer baseline available"

  defp comment_bloat_summary(score, best_single) do
    s = best_single.individual_score

    if score.usefulness >= s.usefulness and score.snr >= s.snr and
         score.avg_comments_per_pr <= s.avg_comments_per_pr + 1 do
      "yes"
    else
      "no"
    end
  end

  defp claim_to_map(%_module{} = struct), do: struct |> Map.from_struct() |> claim_to_map()

  defp claim_to_map(%{} = map) do
    map
    |> Map.delete(:__struct__)
    |> Map.new(fn {key, value} -> {atom_key(key), claim_to_map(value)} end)
  end

  defp claim_to_map(list) when is_list(list), do: Enum.map(list, &claim_to_map/1)
  defp claim_to_map(value), do: value

  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)

  defp normalize(value), do: value |> to_string() |> String.downcase() |> String.trim()

  defp canonicalize(value) do
    value
    |> normalize()
    |> String.replace(~r/[^a-z0-9]+/, " ")
    |> String.split()
    |> Enum.take(12)
    |> Enum.join(" ")
  end

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)
end

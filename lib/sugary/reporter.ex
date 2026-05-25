defmodule Sugary.Reporter do
  def write_report!(run_dir, manifest, method_reports, cases \\ []) do
    research_scorecard = Sugary.ResearchScorecard.build(manifest, method_reports, cases)
    report = render_report(manifest, method_reports, cases, research_scorecard)
    File.write!(Path.join(run_dir, "report.md"), report)
    write_diagnostics!(run_dir, manifest, method_reports, cases, research_scorecard)
    report
  end

  def render_report(manifest, method_reports, cases \\ []) do
    render_report(
      manifest,
      method_reports,
      cases,
      Sugary.ResearchScorecard.build(manifest, method_reports, cases)
    )
  end

  def render_report(manifest, method_reports, cases, research_scorecard) do
    best =
      Enum.max_by(method_reports, &{&1.score.f1, &1.score.usefulness, &1.score.snr}, fn -> nil end)

    decision = decision(best)

    rows =
      method_reports
      |> Enum.map(fn report ->
        score = report.score

        "| #{report.method.id} | #{report.method.class} | #{fmt(score.recall)} | #{fmt(score.usefulness)} | #{fmt(score.snr)} | #{fmt(score.avg_comments_per_pr)} | #{fmt(score.cost)} |"
      end)
      |> Enum.join("\n")

    failures =
      method_reports
      |> Enum.flat_map(& &1.failures)
      |> Enum.group_by(& &1.category)
      |> Enum.map(fn {category, values} -> "- #{category}: #{length(values)}" end)
      |> Enum.join("\n")

    team_details = render_team_details(method_reports)
    external_details = render_external_details(method_reports)
    research_details = render_research_scorecard(research_scorecard)
    diagnostics = render_diagnostics(manifest, method_reports, cases)

    """
    # Experiment Report: #{manifest.id}

    #{manifest.description || ""}

    Suite: `#{manifest.suite}`#{if manifest.split, do: " / split: `" <> manifest.split <> "`", else: ""}

    #{holdout_warning(manifest)}

    ## Decision

    #{decision}

    ## Scorecard

    | Method | Class | Recall | Usefulness | SNR | Avg Comments | Cost |
    | --- | --- | --- | --- | --- | --- | --- |
    #{rows}

    ## What Improved

    The report is generated from reproducible local artifacts. Harness-test methods are not evidence for PCRS theory validation.

    ## What Regressed

    Inspect failures below before promoting any research method.

    ## Failure Clusters

    #{if failures == "", do: "- none", else: failures}

    #{team_details}

    #{external_details}

    #{research_details}

    #{diagnostics}

    ## Next Experiments

    - Promote only non-oracle research methods that clear the theory success bar.
    - Add real reviewer adapters after the harness is stable.
    """
  end

  defp write_diagnostics!(run_dir, _manifest, _method_reports, [], research_scorecard) do
    Sugary.ResearchScorecard.write!(run_dir, research_scorecard)
  end

  defp write_diagnostics!(run_dir, manifest, method_reports, cases, research_scorecard) do
    Sugary.ResearchScorecard.write!(run_dir, research_scorecard)

    Sugary.EvidenceRefutationAblation.maybe_write!(
      run_dir,
      manifest,
      method_reports,
      research_scorecard
    )

    Sugary.Json.write!(
      Path.join(run_dir, "saturation-diagnostics.json"),
      Sugary.Diagnostics.saturation(method_reports, cases, manifest.split)
    )

    Sugary.Json.write!(
      Path.join(run_dir, "anti-overfitting-warnings.json"),
      Sugary.Diagnostics.anti_overfitting_warnings(method_reports, cases, manifest.split)
    )

    Sugary.Json.write!(
      Path.join(run_dir, "coverage-matrix-v2.json"),
      Sugary.Diagnostics.coverage_matrix_v2(method_reports, cases)
    )

    Sugary.Json.write!(
      Path.join(run_dir, "score-slices.json"),
      Sugary.Diagnostics.score_slices(method_reports)
    )
  end

  defp render_diagnostics(_manifest, _method_reports, []), do: ""

  defp render_diagnostics(manifest, method_reports, cases) do
    saturation = Sugary.Diagnostics.saturation(method_reports, cases, manifest.split)
    warnings = Sugary.Diagnostics.anti_overfitting_warnings(method_reports, cases, manifest.split)

    warning_rows =
      warnings
      |> Enum.map(&"- #{&1.method_id}: #{&1.type} - #{&1.summary}")
      |> Enum.join("\n")

    """
    ## Saturation Diagnostics

    - Best individual reviewer: #{saturation.best_individual_reviewer || "none"}
    - Best individual recall: #{fmt(saturation.best_individual_recall)}
    - Best individual usefulness: #{fmt(saturation.best_individual_usefulness)}
    - Best individual SNR: #{fmt(saturation.best_individual_snr)}
    - Any perfect individual reviewer: #{if saturation.any_perfect_reviewer, do: "yes", else: "no"}
    - Any perfect method or team: #{if saturation.any_perfect_method_or_team, do: "yes", else: "no"}
    - Fixture saturated: #{if saturation.fixture_saturated, do: "yes", else: "no"}
    - True positives remaining unfound by any reviewer: #{saturation.true_positives_remaining_unfound_by_any_reviewer}
    - Noise produced by any reviewer: #{saturation.noise_produced_by_any_reviewer}
    - Gap best individual to oracle union: #{fmt(saturation.gap_best_individual_to_oracle)}
    - Gap best team to oracle union: #{fmt(saturation.gap_best_team_to_oracle)}
    - Complementarity headroom: #{fmt(saturation.complementarity_headroom)}

    #{saturation.message}

    ## Anti-Overfitting Warnings

    #{if warning_rows == "", do: "- none", else: warning_rows}
    """
  end

  defp render_research_scorecard(scorecard) do
    """
    ## Research Scorecard

    Full artifacts:

    - `research-scorecard.json`
    - `research-scorecard.md`

    - Best method by research utility: `#{scorecard.summary.best_method_by_research_utility || "none"}`
    - Recommended next ablation: `#{scorecard.next_ablation.primary_ablation}`
    - Metric posture: reporting-only; publishing behavior is unchanged.
    """
  end

  defp holdout_warning(%{split: "holdout"}),
    do:
      "Holdout warning: reviewer inputs were blinded. Verify these methods were not tuned against this split before making promotion claims."

  defp holdout_warning(_manifest), do: ""

  defp decision(nil), do: "Lab failure: no methods were executed."

  defp decision(best) do
    if best.score.published_claims >= 0 do
      "Lab success: harness executed and produced a truthful scorecard. Best method by F1/usefulness: `#{best.method.id}`. This does not validate PCRS unless the method is non-oracle and clears the theory bar."
    else
      "Lab failure: scorecard could not be produced."
    end
  end

  defp render_team_details(method_reports) do
    team_reports = Enum.filter(method_reports, &Map.has_key?(&1, :team))

    if team_reports == [] do
      ""
    else
      sections =
        team_reports
        |> Enum.map(fn report ->
          contributions = report.team.contributions
          best_single = Enum.max_by(contributions, & &1.individual_score.f1, fn -> nil end)

          reviewer_rows =
            contributions
            |> Enum.map(fn contribution ->
              s = contribution.individual_score

              "| #{contribution.reviewer_id} | #{fmt(s.f1)} | #{fmt(s.usefulness)} | #{fmt(s.snr)} | #{contribution.raw_claims} | #{contribution.unique_hits_contributed_to_team} | #{fmt(contribution.marginal_team_contribution)} |"
            end)
            |> Enum.join("\n")

          beat_best? = best_single && report.score.f1 > best_single.individual_score.f1

          """
          ### #{report.method.id}

          - Raw claims: #{report.team.team_scorecard.raw_claims}
          - Merged claims: #{report.team.team_scorecard.merged_claims}
          - Published claims: #{report.team.team_scorecard.published_claims}
          - Beat best single reviewer by F1: #{if beat_best?, do: "yes", else: "no"}
          - Improved usefulness/SNR without bloating comments: #{team_quality_summary(report.score, best_single)}

          | Reviewer | F1 | Usefulness | SNR | Raw Claims | Unique Team Hits | Marginal F1 |
          | --- | --- | --- | --- | --- | --- | --- |
          #{reviewer_rows}
          """
        end)
        |> Enum.join("\n")

      "## Review Teams\n\n" <> sections
    end
  end

  defp render_external_details(method_reports) do
    rows =
      method_reports
      |> Enum.flat_map(fn report ->
        Map.get(report, :results, [])
        |> Enum.flat_map(fn result ->
          result.reviewer_result.artifacts
          |> List.wrap()
          |> Enum.filter(
            &(Map.get(&1, :adapter) == "command" or Map.get(&1, "adapter") == "command")
          )
          |> Enum.map(fn artifact ->
            mode =
              Map.get(artifact, :execution_mode) || Map.get(artifact, "execution_mode") ||
                "unknown"

            cache = Map.get(artifact, :cache_hit) || Map.get(artifact, "cache_hit") || false

            latency =
              Map.get(artifact, :duration_ms) || Map.get(artifact, "duration_ms") ||
                result.reviewer_result.latency_ms

            quality =
              Map.get(artifact, :quality_warnings) || Map.get(artifact, "quality_warnings") || []

            "| #{report.method.id} | #{mode} | #{cache} | #{fmt(result.reviewer_result.cost)} | #{latency} | #{length(quality)} |"
          end)
        end)
      end)

    if rows == [] do
      ""
    else
      """
      ## External Reviewer Execution

      | Reviewer | Mode | Cache Hit | Cost | Latency ms | Quality Warnings |
      | --- | --- | --- | --- | --- | --- |
      #{Enum.join(rows, "\n")}
      """
    end
  end

  defp team_quality_summary(_score, nil), do: "no single-reviewer baseline available"

  defp team_quality_summary(score, best_single) do
    s = best_single.individual_score

    if score.usefulness >= s.usefulness and score.snr >= s.snr and
         score.avg_comments_per_pr <= s.avg_comments_per_pr + 1 do
      "yes"
    else
      "no"
    end
  end

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)
end

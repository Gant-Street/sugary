defmodule Sugary.EvidenceRefutationAblationTest do
  use ExUnit.Case

  alias Sugary.Protocol

  defp manifest do
    Protocol.ExperimentManifest.new(%{
      id: "evidence-refutation-ablation-test",
      suite: "unit-fixtures",
      methods: []
    })
  end

  defp scorecard(method_cards, expected_defects) do
    %{
      version: "research-scorecard-v0",
      summary: %{expected_defects: expected_defects},
      methods: method_cards
    }
  end

  defp method_report(id, attrs) do
    method =
      %{
        id: id,
        class: "research",
        context: "symbol_graph_stub",
        candidate_generation: "reflexion_stub",
        evidence: "none",
        refutation: "none",
        ranking: "fixed_threshold"
      }
      |> Map.merge(Map.new(attrs))

    %{method: method, score: %{}, failures: [], results: []}
  end

  defp method_card(id, attrs) do
    Map.merge(
      %{
        method_id: id,
        research_utility: 0.0,
        defect_hits: 0,
        expected_defects: 2,
        recall: 0.0,
        noise: 0,
        usefulness: 0.0,
        published_comments: 0,
        avg_comments_per_pr: 0.0,
        unresolved_expected_defects: [],
        evidence_tier_distribution: [],
        marginal_utility_by_rank: []
      },
      Map.new(attrs)
    )
  end

  defp reports_and_scorecard(overrides \\ %{}) do
    specs = [
      {"a", "baseline", %{}},
      {"b", "evidence_only", %{evidence: "static_trace_stub"}},
      {"c", "refutation_only", %{refutation: "generic_refuter_stub"}},
      {"d", "evidence_refutation",
       %{evidence: "static_trace_stub", refutation: "generic_refuter_stub"}},
      {"e", "evidence_refutation_ranker",
       %{
         evidence: "static_trace_stub",
         refutation: "generic_refuter_stub",
         ranking: "expected_value_stub"
       }}
    ]

    reports =
      Enum.map(specs, fn {suffix, _variant, attrs} ->
        method_report("ablation-#{suffix}", attrs)
      end)

    cards =
      Enum.map(specs, fn {suffix, variant, _attrs} ->
        default =
          case variant do
            "baseline" ->
              %{research_utility: 1.0, defect_hits: 1, noise: 1, usefulness: 0.5}

            "evidence_refutation" ->
              %{research_utility: 3.0, defect_hits: 2, noise: 0, usefulness: 1.0}

            "evidence_refutation_ranker" ->
              %{research_utility: 2.5, defect_hits: 2, noise: 0, usefulness: 1.0}

            _other ->
              %{research_utility: 1.2, defect_hits: 1, noise: 1, usefulness: 0.5}
          end

        attrs = Map.merge(default, Map.get(overrides, variant, %{}))
        method_card("ablation-#{suffix}", attrs)
      end)

    {reports, scorecard(cards, Map.get(overrides, :expected_defects, 2))}
  end

  test "build reports variants, deltas, shared path, and promotion decision" do
    {reports, scorecard} = reports_and_scorecard()
    ablation = Sugary.EvidenceRefutationAblation.build(manifest(), reports, scorecard)

    assert ablation.required_variants_present == true
    assert ablation.shared_candidate_path.shared_context == true
    assert ablation.shared_candidate_path.shared_candidate_generation == true
    assert ablation.decision.decision == "promote_evidence_refutation_path"
    assert ablation.decision.promoted_variant == "evidence_refutation"

    promoted = Enum.find(ablation.variants, &(&1.variant == "evidence_refutation"))
    assert promoted.delta_vs_baseline.research_utility == 2.0
    assert promoted.delta_vs_baseline.defect_hits == 1
    assert promoted.delta_vs_baseline.noise == -1
  end

  test "decision rejects when evidence/refutation adds noise without utility lift" do
    {reports, scorecard} =
      reports_and_scorecard(%{
        "evidence_refutation" => %{research_utility: 0.5, defect_hits: 1, noise: 2},
        "evidence_refutation_ranker" => %{research_utility: 0.4, defect_hits: 1, noise: 2}
      })

    ablation = Sugary.EvidenceRefutationAblation.build(manifest(), reports, scorecard)

    assert ablation.decision.decision == "reject_evidence_refutation_path"
  end

  test "decision asks for harder fixtures when baseline is saturated" do
    {reports, scorecard} =
      reports_and_scorecard(%{
        "baseline" => %{research_utility: 4.0, defect_hits: 2, noise: 0},
        :expected_defects => 2
      })

    ablation = Sugary.EvidenceRefutationAblation.build(manifest(), reports, scorecard)

    assert ablation.decision.decision == "needs_harder_fixtures"
    assert ablation.decision.reason =~ "baseline already found every expected defect"
  end

  test "experiment manifest writes ablation artifacts" do
    run_dir =
      Sugary.Runner.run_experiment_file!("experiments/evidence-refutation-ablation-v0.toml")

    on_exit(fn -> File.rm_rf(run_dir) end)

    assert File.exists?(Path.join(run_dir, "evidence-refutation-ablation.json"))
    assert File.exists?(Path.join(run_dir, "evidence-refutation-ablation.md"))

    ablation = Sugary.Json.read!(Path.join(run_dir, "evidence-refutation-ablation.json"))
    markdown = File.read!(Path.join(run_dir, "evidence-refutation-ablation.md"))

    assert ablation["version"] == "evidence-refutation-ablation-v0"
    assert ablation["required_variants_present"] == true
    assert markdown =~ "Research Scorecard Deltas"
    assert markdown =~ "Evidence Tier Distribution"
  end
end

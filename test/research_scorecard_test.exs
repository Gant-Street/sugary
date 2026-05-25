defmodule Sugary.ResearchScorecardTest do
  use ExUnit.Case

  alias Sugary.Protocol

  defp claim(id, attrs) do
    Protocol.ReviewClaim.new(
      Map.merge(
        %{
          id: id,
          claim: "Synthetic claim #{id}",
          category: "bug",
          severity: "medium",
          confidence: 0.7,
          path: "src/example.ex",
          introduced_by_pr: true,
          evidence: [%{type: "static_trace", tier: 3, strength: "medium", summary: "trace"}],
          dedupe_key: id,
          source: %{method: "synthetic"},
          publish_decision: "publish"
        },
        Map.new(attrs)
      )
    )
  end

  defp benchmark_case(attrs \\ %{}) do
    Protocol.BenchmarkCase.new(
      Map.merge(
        %{
          id: "research-scorecard-case",
          suite: "research-scorecard-fixtures",
          pr: %{title: "Synthetic PR", body: ""},
          diff: "synthetic diff",
          context: %{allowed: %{symbols: ["route uses middleware contract"]}},
          oracle: %{
            expectedClaims: [
              %{
                id: "critical-hit",
                description: "Critical defect.",
                category: "security",
                severity: "critical",
                required_context: ["route", "middleware"],
                difficulty: "hard",
                specialist: "security"
              },
              %{
                id: "suppressed-hit",
                description: "Suppressed true defect.",
                category: "contract",
                severity: "high",
                required_context: ["schema_contract"],
                difficulty: "hard",
                specialist: "contract"
              }
            ],
            knownNonIssues: [
              %{
                id: "preexisting-noise",
                description: "Pre-existing issue.",
                category: "bug",
                trapCategory: "preexisting_bug"
              }
            ]
          }
        },
        attrs
      )
    )
  end

  defp result do
    bench_case = benchmark_case()

    hit =
      claim("critical-hit",
        severity: "critical",
        confidence: 0.9,
        evidence: [%{type: "static_trace", tier: 3, strength: "medium", summary: "trace"}]
      )

    preexisting =
      claim("preexisting-noise",
        introduced_by_pr: false,
        confidence: 0.8,
        evidence: [%{type: "heuristic", tier: 5, strength: "weak", summary: "weak"}]
      )

    speculative =
      claim("speculative-noise",
        confidence: 0.6,
        evidence: [%{type: "heuristic", tier: 5, strength: "weak", summary: "weak"}]
      )

    suppressed =
      claim("suppressed-hit",
        confidence: 0.91,
        dedupe_key: "suppressed-hit",
        publish_decision: "suppress",
        suppressed_reason: "comment_budget"
      )

    %{
      case: bench_case,
      input: Sugary.Fixtures.input_bundle(bench_case, %{id: "synthetic"}),
      reviewer_result:
        Protocol.ReviewerResult.new(%{
          reviewer_id: "synthetic",
          method_id: "synthetic",
          class: "research",
          claims: Enum.map([hit, preexisting, speculative, suppressed], &Protocol.to_map/1),
          cost: 0.0,
          latency_ms: 1,
          artifacts: [],
          errors: []
        }),
      candidate_claims: [hit, preexisting, speculative, suppressed],
      final_claims: [hit, preexisting, speculative, suppressed]
    }
  end

  defp method_report(method_id \\ "synthetic") do
    result = result()

    %{
      method: %{id: method_id, class: "research"},
      score: Sugary.Scorer.score(method_id, [result]),
      failures: Sugary.Scorer.failures(method_id, [result]),
      results: [result]
    }
  end

  defp scorecard(reports \\ [method_report()]) do
    manifest =
      Protocol.ExperimentManifest.new(%{
        id: "research-scorecard-test",
        suite: "research-scorecard-fixtures",
        methods: []
      })

    Sugary.ResearchScorecard.build(manifest, reports, [result().case])
  end

  test "research utility, marginal rank utility, evidence tiers, and false positives are reported" do
    [method] = scorecard().methods

    assert method.defect_hits == 1
    assert method.expected_defects == 2
    assert method.noise == 2
    assert_in_delta method.research_utility, -0.3, 0.001

    rank1 = Enum.find(method.marginal_utility_by_rank, &(&1.rank == "1"))
    rank2 = Enum.find(method.marginal_utility_by_rank, &(&1.rank == "2"))
    rank3 = Enum.find(method.marginal_utility_by_rank, &(&1.rank == "3"))

    assert_in_delta rank1.utility, 2.9, 0.001
    assert_in_delta rank2.utility, -2.1, 0.001
    assert_in_delta rank3.utility, -1.1, 0.001

    tier3 = Enum.find(method.evidence_tier_distribution, &(&1.tier == "tier_3"))
    tier5 = Enum.find(method.evidence_tier_distribution, &(&1.tier == "tier_5"))

    assert tier3.defect_hits == 1
    assert tier5.noise == 2
    assert method.false_positive_categories["preexisting_bug"] == 1
    assert method.false_positive_categories["speculative_edge_case"] == 1
  end

  test "unresolved expected defects and suppressed high-confidence true claims are reported" do
    [method] = scorecard().methods

    assert [%{expected_claim_id: "suppressed-hit", category: "contract"}] =
             method.unresolved_expected_defects

    assert [%{dedupe_key: "suppressed-hit", confidence: 0.91}] =
             method.suppressed_high_confidence_true_claims
  end

  test "next ablation recommendation is deterministic and can recommend evidence gates" do
    card = scorecard()

    assert card.next_ablation.primary_ablation == "evidence_gate"
    assert Enum.any?(card.next_ablation.recommendations, &(&1.ablation == "refutation"))
    assert Enum.any?(card.next_ablation.recommendations, &(&1.ablation == "evidence_gate"))

    assert Enum.any?(
             card.next_ablation.recommendations,
             &(&1.ablation == "ranking_or_publishing_threshold")
           )
  end

  test "context retrieval is recommended when false negatives dominate cross-file defects" do
    bench_case = benchmark_case()

    suppressed =
      claim("suppressed-hit", dedupe_key: "suppressed-hit", publish_decision: "suppress")

    result = %{
      case: bench_case,
      input: Sugary.Fixtures.input_bundle(bench_case, %{id: "context-missing"}),
      reviewer_result:
        Protocol.ReviewerResult.new(%{
          reviewer_id: "context-missing",
          method_id: "context-missing",
          class: "research",
          claims: [Protocol.to_map(suppressed)],
          cost: 0.0,
          latency_ms: 1,
          artifacts: [],
          errors: []
        }),
      candidate_claims: [suppressed],
      final_claims: [suppressed]
    }

    report = %{
      method: %{id: "context-missing", class: "research"},
      score: Sugary.Scorer.score("context-missing", [result]),
      failures: Sugary.Scorer.failures("context-missing", [result]),
      results: [result]
    }

    card = scorecard([report])

    assert card.next_ablation.primary_ablation == "context_retrieval"
  end

  test "experiment runs write research scorecard artifacts and link them from report" do
    run_dir = Sugary.Runner.run_experiment_file!("experiments/pcrs-hard-fixtures-v0.toml")
    on_exit(fn -> File.rm_rf(run_dir) end)

    assert File.exists?(Path.join(run_dir, "research-scorecard.json"))
    assert File.exists?(Path.join(run_dir, "research-scorecard.md"))

    report = File.read!(Path.join(run_dir, "report.md"))
    markdown = File.read!(Path.join(run_dir, "research-scorecard.md"))
    json = Sugary.Json.read!(Path.join(run_dir, "research-scorecard.json"))

    assert report =~ "Research Scorecard"
    assert report =~ "research-scorecard.md"
    assert markdown =~ "Next Ablation Recommendation"
    assert json["version"] == "research-scorecard-v0"
  end
end

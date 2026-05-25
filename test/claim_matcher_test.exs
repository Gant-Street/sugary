defmodule Sugary.ClaimMatcherTest do
  use ExUnit.Case

  alias Sugary.Protocol

  defp bench_case do
    Protocol.BenchmarkCase.new(%{
      id: "feature-flag-inversion",
      suite: "agent-written-hard-fixtures",
      pr: %{title: "Generated onboarding flow", body: ""},
      diff: "generated code uses unless beta_onboarding_enabled",
      context: %{},
      oracle: %{
        expectedClaims: [
          %{
            id: "feature-flag-inversion",
            description:
              "Generated feature flag condition is inverted and enables the new flow for non-beta accounts.",
            category: "bug",
            severity: "high",
            path: "src/onboarding.ex",
            required_context: ["feature_flag_contract"],
            specialist: "logic"
          }
        ],
        knownNonIssues: [
          %{
            id: "trap-feature-flag-name",
            description: "The feature flag name is intentionally verbose and not a review issue.",
            category: "style",
            path: "src/onboarding.ex",
            trapCategory: "stylistic_preference"
          }
        ]
      }
    })
  end

  defp claim(attrs) do
    Protocol.ReviewClaim.new(
      Map.merge(
        %{
          id: "llm-claim-1",
          claim:
            "The feature flag condition is inverted, so non-beta accounts enter the new flow.",
          category: "bug",
          severity: "high",
          confidence: 0.78,
          path: "src/onboarding.ex",
          introduced_by_pr: true,
          evidence: [
            %{
              type: "llm",
              tier: 4,
              strength: "medium",
              summary: "unless beta_onboarding_enabled reverses the feature flag contract"
            }
          ],
          dedupe_key: "bug:src/onboarding.ex:inverted feature flag",
          source: %{method: "llm"},
          publish_decision: "publish"
        },
        attrs
      )
    )
  end

  test "matches semantically equivalent LLM claims without exact fixture ids" do
    assert %{id: "feature-flag-inversion"} =
             Sugary.ClaimMatcher.expected_claim(bench_case(), claim(%{}))
  end

  test "does not match claims on the wrong path" do
    refute Sugary.ClaimMatcher.expected_claim(bench_case(), claim(%{path: "src/other.ex"}))
  end

  test "matches unknown-path claims only when semantic overlap is strong" do
    assert %{id: "feature-flag-inversion"} =
             Sugary.ClaimMatcher.expected_claim(bench_case(), claim(%{path: "unknown"}))

    weak_claim =
      claim(%{
        path: "unknown",
        claim: "This generated code may be hard to read.",
        evidence: [%{type: "llm", tier: 5, strength: "weak", summary: "style concern"}]
      })

    refute Sugary.ClaimMatcher.expected_claim(bench_case(), weak_claim)
  end

  test "scorer credits fuzzy matched LLM claims" do
    result = %{
      case: bench_case(),
      input: Sugary.Fixtures.input_bundle(bench_case(), %{id: "llm"}),
      reviewer_result:
        Protocol.ReviewerResult.new(%{
          reviewer_id: "llm",
          method_id: "llm",
          class: "research",
          claims: [],
          cost: 0.0,
          latency_ms: 1,
          artifacts: [],
          errors: []
        }),
      candidate_claims: [claim(%{})],
      final_claims: [claim(%{})]
    }

    score = Sugary.Scorer.score("llm", [result])

    [card] =
      Sugary.ResearchScorecard.build(
        Protocol.ExperimentManifest.new(%{id: "matcher", suite: "unit", methods: []}),
        [
          %{
            method: %{id: "llm", class: "research"},
            score: score,
            failures: [],
            results: [result]
          }
        ],
        [bench_case()]
      ).methods

    assert score.hits == 1
    assert score.noise == 0
    assert card.defect_hits == 1
    assert card.research_utility > 0
  end
end

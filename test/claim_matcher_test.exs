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

  test "normalizes common benchmark and reviewer category synonyms" do
    aacr_case =
      Protocol.BenchmarkCase.new(%{
        id: "aacr-category-synonym",
        suite: "aacr-bench",
        pr: %{title: "Generated pagination", body: ""},
        diff: "offset = page * limit",
        context: %{},
        oracle: %{
          expectedClaims: [
            %{
              id: "pagination-off-by-one",
              description:
                "The pagination offset skips the first page because it uses page * limit instead of (page - 1) * limit.",
              category: "Code Defect",
              severity: "high",
              path: "src/pagination.ts"
            },
            %{
              id: "naming-obscures-pagination",
              description:
                "The pagination helper uses ambiguous names that make page and offset semantics hard to maintain.",
              category: "Maintainability and Readability",
              severity: "medium",
              path: "src/pagination.ts"
            }
          ],
          knownNonIssues: []
        }
      })

    correctness_claim =
      claim(%{
        path: "src/pagination.ts",
        category: "correctness",
        claim:
          "The offset calculation uses page * limit, which skips page one instead of using (page - 1) * limit.",
        evidence: [%{type: "llm", tier: 4, strength: "medium", summary: "off-by-one pagination"}]
      })

    maintainability_claim =
      claim(%{
        path: "src/pagination.ts",
        category: "maintainability",
        claim:
          "The pagination helper uses ambiguous names, making page and offset semantics hard to maintain.",
        evidence: [%{type: "llm", tier: 5, strength: "weak", summary: "ambiguous names"}]
      })

    assert %{id: "pagination-off-by-one"} =
             Sugary.ClaimMatcher.expected_claim(aacr_case, correctness_claim)

    assert %{id: "naming-obscures-pagination"} =
             Sugary.ClaimMatcher.expected_claim(aacr_case, maintainability_claim)
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

  test "matches public benchmark claims with unknown oracle paths conservatively" do
    public_case =
      Protocol.BenchmarkCase.new(%{
        id: "martian-smoke",
        suite: "martian-offline",
        pr: %{title: "Async cleanup", body: ""},
        diff: "forEach(async callback) is not awaited",
        context: %{},
        public_benchmark: true,
        oracle: %{
          expectedClaims: [
            %{
              id: "martian-golden-1",
              description:
                "The code uses forEach with async callbacks, so asynchronous cleanup runs without being awaited and failures bypass the surrounding try-catch.",
              category: "public_benchmark",
              severity: "critical",
              path: "unknown"
            }
          ],
          knownNonIssues: []
        }
      })

    public_claim =
      claim(%{
        path: "packages/app-store/vital/lib/reschedule.ts",
        category: "runtime",
        claim:
          "Using forEach with async callbacks means calendar cleanup is not awaited and errors will not be caught.",
        evidence: [
          %{
            type: "llm",
            tier: 4,
            strength: "medium",
            summary: "The async callback is fire-and-forget and bypasses try-catch."
          }
        ]
      })

    assert %{id: "martian-golden-1"} =
             Sugary.ClaimMatcher.expected_claim(public_case, public_claim)
  end

  test "selects the strongest public benchmark fuzzy match instead of the first match" do
    public_case =
      Protocol.BenchmarkCase.new(%{
        id: "martian-smoke-migration",
        suite: "martian-offline",
        pr: %{title: "Migrate embeddable hosts", body: ""},
        diff: "",
        context: %{},
        public_benchmark: true,
        oracle: %{
          expectedClaims: [
            %{
              id: "martian-golden-1",
              description: "NoMethodError before_validation in EmbeddableHost",
              category: "public_benchmark",
              severity: "critical",
              path: "unknown"
            },
            %{
              id: "martian-golden-4",
              description:
                "Because this migration inserts embeddable_hosts rows with raw SQL, existing values with http://, https://, or path segments will not go through EmbeddableHost model normalization, so host lookup may fail for migrated data.",
              category: "public_benchmark",
              severity: "high",
              path: "unknown"
            }
          ],
          knownNonIssues: []
        }
      })

    public_claim =
      claim(%{
        path: "db/migrate/20150818190757_create_embeddable_hosts.rb",
        category: "contract",
        claim:
          "The migration inserts existing embeddable_hosts values through raw SQL, bypassing EmbeddableHost normalization that strips schemes and path segments; migrated hosts can fail lookup.",
        evidence: [
          %{
            type: "static_diff_proof",
            tier: 3,
            strength: "strong",
            summary:
              "The diff adds before_validation host normalization but inserts raw host values in SQL."
          }
        ]
      })

    assert %{id: "martian-golden-4"} =
             Sugary.ClaimMatcher.expected_claim(public_case, public_claim)
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

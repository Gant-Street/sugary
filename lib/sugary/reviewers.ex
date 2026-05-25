defmodule Sugary.Reviewers do
  alias Sugary.Protocol.{Evidence, ReviewClaim, ReviewerResult}

  def run(%{type: "command"} = method, _bench_case, input) do
    Sugary.CommandReviewer.run(method, input)
  end

  def run(method, bench_case, input) do
    start = System.monotonic_time(:millisecond)
    claims = generate_claims(method, bench_case, input)
    latency = System.monotonic_time(:millisecond) - start

    ReviewerResult.new(%{
      reviewer_id: method.id,
      method_id: method.id,
      class: method.class,
      claims: Enum.map(claims, &Sugary.Protocol.to_map/1),
      cost: 0.0,
      latency_ms: latency,
      artifacts: [],
      errors: []
    })
  end

  defp generate_claims(
         %{class: "harness_test", candidate_generation: "golden_perfect"} = method,
         bench_case,
         _input
       ) do
    expected_claims(bench_case, method)
  end

  defp generate_claims(
         %{class: "harness_test", candidate_generation: "golden_noisy"} = method,
         bench_case,
         _input
       ) do
    expected_claims(bench_case, method) ++ known_noise(bench_case, method)
  end

  defp generate_claims(
         %{class: "harness_test", candidate_generation: "golden_missing_context"} = method,
         bench_case,
         _input
       ) do
    bench_case
    |> expected_claims(method)
    |> Enum.reject(&("needs_context" in List.wrap(&1.source[:tags])))
  end

  defp generate_claims(
         %{class: "harness_test", candidate_generation: "golden_duplicate"} = method,
         bench_case,
         _input
       ) do
    claims = expected_claims(bench_case, method)

    case claims do
      [first | _] ->
        claims ++
          [
            %{
              first
              | id: first.id <> "-duplicate",
                source: Map.put(first.source, :duplicate, true)
            }
          ]

      [] ->
        []
    end
  end

  defp generate_claims(method, _bench_case, input), do: research_claims(method, input)

  defp expected_claims(bench_case, method) do
    bench_case.oracle
    |> Map.get(:expectedClaims, [])
    |> Enum.map(&claim_from_oracle(&1, method, bench_case))
  end

  defp known_noise(bench_case, method) do
    bench_case.oracle
    |> Map.get(:knownNonIssues, [])
    |> Enum.map(&noise_from_oracle(&1, method, bench_case))
  end

  defp claim_from_oracle(oracle, method, bench_case) do
    evidence =
      Evidence.new(%{
        type: "fixture_oracle",
        tier: 1,
        strength: "strong",
        summary: "Harness-test oracle claim."
      })

    ReviewClaim.new(%{
      id: oracle.id,
      claim: oracle.description,
      category: Map.get(oracle, :category, "bug"),
      severity: Map.get(oracle, :severity, "medium"),
      confidence: 0.99,
      path: Map.get(oracle, :path, "unknown"),
      start_line: Map.get(oracle, :line, 1),
      end_line: Map.get(oracle, :line, 1),
      introduced_by_pr: true,
      failure_path: Map.get(oracle, :failurePath, []),
      evidence: [Sugary.Protocol.to_map(evidence)],
      suggested_fix: Map.get(oracle, :suggestedFix, "Fix the described defect."),
      suggested_test: Map.get(oracle, :suggestedTest, "Add a regression test."),
      dedupe_key: oracle.id,
      source: %{
        method: method.id,
        class: method.class,
        case_id: bench_case.id,
        tags: Map.get(oracle, :tags, [])
      },
      publish_decision: "candidate"
    })
  end

  defp noise_from_oracle(non_issue, method, bench_case) do
    evidence =
      Evidence.new(%{
        type: "fixture_oracle",
        tier: 5,
        strength: "weak",
        summary: "Harness-test non-issue."
      })

    ReviewClaim.new(%{
      id: non_issue.id,
      claim: non_issue.description,
      category: Map.get(non_issue, :category, "noise"),
      severity: "low",
      confidence: 0.4,
      path: Map.get(non_issue, :path, "unknown"),
      start_line: Map.get(non_issue, :line, 1),
      end_line: Map.get(non_issue, :line, 1),
      introduced_by_pr: Map.get(non_issue, :introducedByPr, false),
      failure_path: [],
      evidence: [Sugary.Protocol.to_map(evidence)],
      suggested_fix: "",
      suggested_test: "",
      dedupe_key: non_issue.id,
      source: %{method: method.id, class: method.class, case_id: bench_case.id, non_issue: true},
      publish_decision: "candidate"
    })
  end

  defp research_claims(method, input) do
    diff = input.diff
    context = input.context || %{}
    mode = method.context
    reflexion? = method.candidate_generation == "reflexion_stub"

    []
    |> maybe_claim(
      String.contains?(diff, "loadUser_retry") and mode != "diff_only",
      null_guard(method)
    )
    |> maybe_claim(
      String.contains?(diff, "hard_null_contract") and mode != "diff_only",
      hard_cross_file_null_contract(method)
    )
    |> maybe_claim(String.contains?(diff, "route_admin"), missing_auth(method))
    |> maybe_claim(
      String.contains?(diff, "preexisting_bug") and
        not String.contains?(diff, "hard_preexisting_bug_near_changed_code"),
      preexisting_bug(method)
    )
    |> maybe_claim(
      String.contains?(diff, "hard_preexisting_bug_near_changed_code"),
      hard_preexisting_bug_near_changed_code(method)
    )
    |> maybe_claim(String.contains?(diff, "TODO_STYLE"), weak_heuristic(method))
    |> maybe_claim(String.contains?(diff, "new_behavior_no_test"), missing_test(method))
    |> maybe_claim(String.contains?(diff, "duplicate_condition"), duplicate_condition(method))
    |> maybe_claim(
      reflexion? and String.contains?(diff, "hard_generated_api_hallucination"),
      hard_generated_api_hallucination(method)
    )
    |> maybe_claim(
      reflexion? and String.contains?(diff, "hard_feature_flag_inversion"),
      hard_feature_flag_inversion(method)
    )
    |> maybe_claim(
      reflexion? and String.contains?(diff, "imaginaryClient"),
      hallucinated_api(method)
    )
    |> maybe_claim(
      reflexion? and String.contains?(diff, "discount_total"),
      plausible_wrong_logic(method)
    )
    |> maybe_claim(
      reflexion? and String.contains?(diff, "edge_case_missing"),
      missing_edge_case(method)
    )
    |> maybe_claim(
      reflexion? and String.contains?(diff, "rewriteAllHandlers"),
      overbroad_refactor(method)
    )
    |> maybe_claim(
      reflexion? and String.contains?(diff, "generatedRoute"),
      weak_auth_generated_route(method)
    )
    |> maybe_claim(
      reflexion? and String.contains?(diff, "schema_v2"),
      integration_contract_mismatch(method)
    )
    |> add_symbol_graph_context(context, method)
  end

  defp maybe_claim(claims, true, claim), do: claims ++ [claim]
  defp maybe_claim(claims, _condition, _claim), do: claims

  defp add_symbol_graph_context(claims, context, method) do
    if method.context == "symbol_graph_stub" and Map.get(context, :symbols, []) != [] do
      claims
    else
      claims
    end
  end

  defp base_claim(method, id, attrs) do
    evidence =
      Evidence.new(%{
        type: "heuristic",
        tier: 5,
        strength: "weak",
        summary: "Generated from non-oracle input bundle."
      })

    defaults = %{
      id: id,
      claim: id,
      category: "bug",
      severity: "medium",
      confidence: 0.65,
      path: "src/example.ex",
      start_line: 1,
      end_line: 1,
      introduced_by_pr: true,
      failure_path: [],
      evidence: [Sugary.Protocol.to_map(evidence)],
      suggested_fix: "Investigate and fix the described issue.",
      suggested_test: "Add a regression test for the described behavior.",
      dedupe_key: id,
      source: %{method: method.id, class: "research"},
      publish_decision: "candidate"
    }

    ReviewClaim.new(Map.merge(defaults, attrs))
  end

  defp null_guard(method),
    do:
      base_claim(method, "null-user-retry-build-session", %{
        claim: "Retry path can pass a null user into buildSession.",
        path: "src/session.ex",
        severity: "high",
        confidence: 0.78,
        failure_path: ["loadUser_retry returns nil", "buildSession expects a user"]
      })

  defp missing_auth(method),
    do:
      base_claim(method, "admin-route-missing-auth", %{
        claim: "Admin route is added without an authorization guard.",
        path: "src/router.ex",
        severity: "high",
        confidence: 0.82
      })

  defp preexisting_bug(method),
    do:
      base_claim(method, "preexisting-cache-bug", %{
        claim: "Cache bug appears to be pre-existing.",
        introduced_by_pr: false,
        confidence: 0.6
      })

  defp weak_heuristic(method),
    do:
      base_claim(method, "style-only-early-return", %{
        claim: "This could use an early return.",
        category: "style",
        severity: "low",
        confidence: 0.35
      })

  defp missing_test(method),
    do:
      base_claim(method, "new-behavior-missing-test", %{
        claim: "New behavior is not covered by a regression test.",
        category: "test",
        confidence: 0.72
      })

  defp duplicate_condition(method),
    do:
      base_claim(method, "duplicate-condition-branch", %{
        claim: "Condition duplicates the previous branch.",
        confidence: 0.7
      })

  defp hard_cross_file_null_contract(method),
    do:
      base_claim(method, "cross-file-null-contract", %{
        claim:
          "Changed retry flow can pass a nullable cached user into a cross-file non-null contract.",
        path: "src/session.ex",
        severity: "high",
        confidence: 0.73,
        failure_path: ["retry cache returns nil", "session builder requires non-null user"]
      })

  defp hard_generated_api_hallucination(method),
    do:
      base_claim(method, "generated-api-hallucination", %{
        claim: "Generated tracking helper calls a client API that does not exist.",
        path: "src/client.ex",
        severity: "high",
        confidence: 0.77
      })

  defp hard_feature_flag_inversion(method),
    do:
      base_claim(method, "feature-flag-inversion", %{
        claim: "Generated feature flag branch appears inverted for the rollout gate.",
        path: "src/onboarding.ex",
        severity: "high",
        confidence: 0.69
      })

  defp hard_preexisting_bug_near_changed_code(method),
    do:
      base_claim(method, "preexisting-bug-near-changed-code", %{
        claim: "Nearby stale cache behavior appears risky but predates this PR.",
        introduced_by_pr: false,
        confidence: 0.58
      })

  defp hallucinated_api(method),
    do:
      base_claim(method, "hallucinated-api-call", %{
        claim: "Generated code calls an API that does not exist in the client.",
        path: "src/client.ex",
        severity: "high",
        confidence: 0.8
      })

  defp plausible_wrong_logic(method),
    do:
      base_claim(method, "plausible-wrong-discount-logic", %{
        claim: "Discount total is computed from the wrong amount.",
        severity: "high",
        confidence: 0.76
      })

  defp missing_edge_case(method),
    do:
      base_claim(method, "missing-edge-case-test", %{
        claim: "Generated branch lacks the edge-case test that would catch empty input.",
        category: "test",
        confidence: 0.74
      })

  defp overbroad_refactor(method),
    do:
      base_claim(method, "overbroad-refactor-risk", %{
        claim: "Generated refactor changes unrelated handlers in the same patch.",
        category: "maintainability",
        confidence: 0.68
      })

  defp weak_auth_generated_route(method),
    do:
      base_claim(method, "weak-auth-generated-route", %{
        claim: "Generated route checks login but not tenant or role authorization.",
        severity: "high",
        confidence: 0.81
      })

  defp integration_contract_mismatch(method),
    do:
      base_claim(method, "integration-contract-mismatch", %{
        claim: "Generated schema v2 payload does not match the consumer contract.",
        severity: "high",
        confidence: 0.79
      })
end

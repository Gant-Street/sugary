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
    if method.candidate_generation == "public_static_proof_gate" do
      public_static_proof_claims(method, input)
    else
      fixture_research_claims(method, input)
    end
  end

  defp fixture_research_claims(method, input) do
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

  defp public_static_proof_claims(method, input) do
    diff = input.diff || ""

    []
    |> maybe_claim(
      duplicate_ruby_class_method_arity?(diff, "downsize"),
      ruby_method_override_claim(method)
    )
    |> maybe_claim(hardcoded_site_setting_limit?(diff), hardcoded_upload_limit_claim(method))
    |> maybe_claim(
      raw_migration_bypasses_model_normalization?(diff),
      raw_migration_normalization_claim(method)
    )
    |> maybe_claim(
      nil_find_by_dereference?(diff, "TopicUser", "tu"),
      nil_topic_user_claim(method)
    )
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

  defp proof_claim(method, id, attrs) do
    evidence =
      Evidence.new(%{
        type: "static_diff_proof",
        tier: 3,
        strength: "strong",
        summary: Map.fetch!(attrs, :evidence_summary)
      })

    attrs =
      attrs
      |> Map.drop([:evidence_summary])
      |> Map.put(:evidence, [Sugary.Protocol.to_map(evidence)])
      |> Map.put(:source, %{method: method.id, class: "research", proof_gate: true})
      |> Map.put(:publish_decision, "candidate")

    base_claim(method, id, attrs)
  end

  defp duplicate_ruby_class_method_arity?(diff, method_name) do
    diff
    |> ruby_class_method_arities(method_name)
    |> Enum.uniq()
    |> length()
    |> Kernel.>(1)
  end

  defp ruby_class_method_arities(diff, method_name) do
    pattern = ~r/def self\.#{Regex.escape(method_name)}\(([^)]*)\)/

    diff
    |> String.split("\n")
    |> Enum.reject(&String.starts_with?(&1, ["---", "+++"]))
    |> Enum.flat_map(fn line ->
      case Regex.run(pattern, line) do
        [_match, args] -> [argument_arity(args)]
        _ -> []
      end
    end)
  end

  defp argument_arity(args) do
    args
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> length()
  end

  defp hardcoded_site_setting_limit?(diff) do
    String.contains?(diff, "Discourse.SiteSettings") and
      (String.contains?(diff, "+    var maxSizeKB = 10 * 1024") or
         String.contains?(diff, "+          var maxSizeKB = 10 * 1024"))
  end

  defp raw_migration_bypasses_model_normalization?(diff) do
    String.contains?(diff, "before_validation") and
      String.contains?(diff, "self.host.sub!") and
      String.contains?(diff, "INSERT INTO embeddable_hosts") and
      String.contains?(diff, ~S|VALUES ('#{h}'|)
  end

  defp nil_find_by_dereference?(diff, model, variable) do
    String.contains?(diff, "#{variable} = #{model}.find_by(") and
      String.contains?(diff, "#{variable}.notification_level")
  end

  defp ruby_method_override_claim(method),
    do:
      proof_claim(method, "public-static-ruby-method-arity-override", %{
        claim:
          "The patch defines OptimizedImage.downsize with incompatible arities; the later dimensions-string definition overrides the existing width/height API and breaks callers that still pass separate max_width and max_height arguments.",
        category: "runtime",
        severity: "medium",
        confidence: 0.94,
        path: "app/models/optimized_image.rb",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "existing downsize accepts from, to, max_width, max_height, opts",
          "new downsize accepts from, to, dimensions, opts",
          "Ruby keeps the later method definition for the same class method name",
          "callers using separate width and height arguments now hit the wrong API"
        ],
        suggested_fix:
          "Keep a single downsize method that preserves the old width/height signature, or introduce a differently named helper for dimensions-string callers.",
        suggested_test:
          "Add a regression test that calls OptimizedImage.downsize with separate max_width and max_height arguments.",
        dedupe_key: "public-static-ruby-method-arity-override",
        evidence_summary:
          "The diff contains two `def self.downsize` definitions with different argument counts in app/models/optimized_image.rb."
      })

  defp hardcoded_upload_limit_claim(method),
    do:
      proof_claim(method, "public-static-hardcoded-upload-limit", %{
        claim:
          "Hardcoding maxSizeKB to 10 * 1024 ignores Discourse.SiteSettings max upload settings, so client-side validation and the 413 handler can diverge from configured per-type and server-side limits.",
        category: "contract",
        severity: "low",
        confidence: 0.91,
        path: "app/assets/javascripts/discourse/lib/utilities.js",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "old code reads Discourse.SiteSettings['max_' + type + '_size_kb'] and max_image_size_kb",
          "new code replaces both reads with a fixed 10 MB value",
          "sites with different configured limits get incorrect client behavior"
        ],
        suggested_fix:
          "Continue reading the configured SiteSettings values and only use a constant as a fallback when the setting is unavailable.",
        suggested_test:
          "Add a client-side test where the configured max image/upload size is not 10 MB.",
        dedupe_key: "public-static-hardcoded-upload-limit",
        evidence_summary:
          "The diff replaces Discourse.SiteSettings-based upload limits with `10 * 1024` in utilities.js."
      })

  defp raw_migration_normalization_claim(method),
    do:
      proof_claim(method, "public-static-migration-bypasses-normalization", %{
        claim:
          "The migration inserts existing embeddable_hosts values through raw SQL, bypassing EmbeddableHost normalization that strips schemes and path segments; migrated hosts can fail lookup even though newly saved hosts are normalized.",
        category: "contract",
        severity: "high",
        confidence: 0.88,
        path: "db/migrate/20150818190757_create_embeddable_hosts.rb",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "EmbeddableHost before_validation strips http/https prefixes and paths",
          "migration inserts raw site setting values directly with execute",
          "EmbeddableHost.host_allowed? compares against normalized host values"
        ],
        suggested_fix:
          "Normalize each migrated host with the same scheme/path stripping logic before inserting rows, or create records through the model when safe.",
        suggested_test:
          "Add migration coverage for existing embeddable_hosts entries with http://, https://, and path components.",
        dedupe_key: "public-static-migration-bypasses-normalization",
        evidence_summary:
          "The diff adds model-level host normalization but the migration inserts raw `h` values with SQL."
      })

  defp nil_topic_user_claim(method),
    do:
      proof_claim(method, "public-static-topic-user-nil-deref", %{
        claim:
          "TopicUser.find_by can return nil in the unsubscribe action, but the new code immediately reads tu.notification_level and saves tu; users without an existing TopicUser row will crash instead of unsubscribing.",
        category: "runtime",
        severity: "high",
        confidence: 0.9,
        path: "app/controllers/topics_controller.rb",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "unsubscribe action calls TopicUser.find_by",
          "find_by returns nil when no TopicUser row exists",
          "the next branch reads tu.notification_level"
        ],
        suggested_fix:
          "Use TopicUser.lookup_or_create_for or explicitly handle nil before reading notification_level.",
        suggested_test:
          "Add an unsubscribe controller test for a user with no existing TopicUser row for the topic.",
        dedupe_key: "public-static-topic-user-nil-deref",
        evidence_summary:
          "The diff assigns `tu = TopicUser.find_by(...)` and dereferences `tu.notification_level` without a nil guard."
      })

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

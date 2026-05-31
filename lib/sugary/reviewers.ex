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
    |> maybe_claim(ruby_open_url_ssrf?(diff), ruby_open_url_ssrf_claim(method))
    |> maybe_claim(allowall_clickjacking?(diff), allowall_clickjacking_claim(method))
    |> maybe_claim(
      unhandled_async_find_members?(diff),
      unhandled_async_find_members_claim(method)
    )
    |> maybe_claim(sample_rate_falsy_guard?(diff), sample_rate_falsy_guard_claim(method))
    |> maybe_claim(refresh_token_literal?(diff), refresh_token_literal_claim(method))
    |> maybe_claim(fetch_response_data_shape?(diff), fetch_response_data_shape_claim(method))
    |> maybe_claim(
      email_blacklist_case_sensitive?(diff),
      email_blacklist_case_sensitive_claim(method)
    )
    |> maybe_claim(retry_count_stale_increment?(diff), retry_count_stale_increment_claim(method))
    |> maybe_claim(
      github_authenticated_state_missing?(diff),
      github_authenticated_state_missing_claim(method)
    )
    |> maybe_claim(
      dataclass_eager_timestamp_default?(diff),
      dataclass_eager_timestamp_claim(method)
    )
    |> maybe_claim(
      monitor_config_returns_original?(diff),
      monitor_config_returns_original_claim(method)
    )
    |> maybe_claim(
      grafana_rule_list_item_missing_key?(diff),
      grafana_rule_list_item_missing_key_claim(method)
    )
    |> maybe_claim(grafana_nil_plugin_context?(diff), grafana_nil_plugin_context_claim(method))
    |> maybe_claim(grafana_exec_args_splat?(diff), grafana_exec_args_splat_claim(method))
    |> maybe_claim(
      grafana_device_limit_ambiguous?(diff),
      grafana_device_limit_ambiguous_claim(method)
    )
    |> maybe_claim(
      grafana_device_time_window_inconsistent?(diff),
      grafana_device_time_window_claim(method)
    )
    |> maybe_claim(
      grafana_wrong_logger_context?(diff),
      grafana_wrong_logger_context_claim(method)
    )
    |> maybe_claim(
      grafana_web_assets_missing_double_check?(diff),
      grafana_web_assets_double_check_claim(method)
    )
    |> maybe_claim(grafana_total_docs_race?(diff), grafana_total_docs_race_claim(method))
    |> maybe_claim(
      keycloak_feature_flag_mismatch?(diff),
      keycloak_feature_flag_mismatch_claim(method)
    )
    |> maybe_claim(keycloak_picocli_exit?(diff), keycloak_picocli_exit_claim(method))
    |> maybe_claim(keycloak_optional_get?(diff), keycloak_optional_get_claim(method))
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

  defp ruby_open_url_ssrf?(diff) do
    String.contains?(diff, "open(url).read") and
      String.contains?(diff, "Readability::Document") and
      String.contains?(diff, "TopicEmbed.import")
  end

  defp allowall_clickjacking?(diff) do
    String.contains?(diff, "X-Frame-Options") and
      String.contains?(diff, "ALLOWALL") and
      String.contains?(diff, "request.referer")
  end

  defp unhandled_async_find_members?(diff) do
    String.contains?(diff, "return group.findMembers();") and
      not String.contains?(diff, "findMembers().then")
  end

  defp sample_rate_falsy_guard?(diff) do
    String.contains?(diff, "if client_sample_rate:") and
      String.contains?(diff, ~S|normalized_data["sample_rate"]|)
  end

  defp refresh_token_literal?(diff) do
    String.contains?(diff, ~S|refreshTokenResponse.data.refresh_token = "refresh_token"|)
  end

  defp fetch_response_data_shape?(diff) do
    String.contains?(diff, "const token = res?.data") and
      String.contains?(diff, "refreshOAuthTokens(")
  end

  defp email_blacklist_case_sensitive?(diff) do
    String.contains?(diff, "blacklistedGuestEmails") and
      String.contains?(diff, "email.toLowerCase()") and
      String.contains?(diff, "blacklistedGuestEmails.includes(guest)")
  end

  defp retry_count_stale_increment?(diff) do
    String.contains?(diff, "prisma.workflowReminder.update") and
      String.contains?(diff, "retryCount: reminder.retryCount + 1")
  end

  defp github_authenticated_state_missing?(diff) do
    String.contains?(diff, ~S|pipeline.fetch_state("github_authenticated_user")|) and
      String.contains?(diff, ~S|integration.metadata["sender"]["login"]|)
  end

  defp dataclass_eager_timestamp_default?(diff) do
    String.contains?(diff, "@dataclass") and
      String.contains?(diff, "queued: datetime = timezone.now()")
  end

  defp monitor_config_returns_original?(diff) do
    String.contains?(diff, "config = monitor_environment.monitor.config.copy()") and
      String.contains?(diff, ~S|"config": monitor_environment.monitor.config|)
  end

  defp grafana_rule_list_item_missing_key?(diff) do
    String.contains?(diff, "case 'grafana'") and
      String.contains?(diff, "+                <GrafanaRuleListItem") and
      String.contains?(diff, "-                  key={key}")
  end

  defp grafana_nil_plugin_context?(diff) do
    String.contains?(diff, "type ContextualLoggerMiddleware struct") and
      String.contains?(diff, "req.PluginContext") and
      String.contains?(diff, "instrumentContext(ctx")
  end

  defp grafana_exec_args_splat?(diff) do
    String.contains?(diff, "args = append([]interface{}{query}, args...)") and
      String.contains?(diff, "dbSession.Exec(args...)")
  end

  defp grafana_device_limit_ambiguous?(diff) do
    String.contains?(diff, "rowsAffected == 0") and
      String.contains?(diff, "ErrDeviceLimitReached")
  end

  defp grafana_device_time_window_inconsistent?(diff) do
    String.contains?(diff, "device.UpdatedAt.UTC().Add(-anonymousDeviceExpiration)") and
      String.contains?(diff, "device.UpdatedAt.UTC().Add(time.Minute)")
  end

  defp grafana_wrong_logger_context?(diff) do
    String.contains?(
      diff,
      ~S|log := d.Log.WithValues("name", name, "kind", options.Kind, "method", method)|
    ) and
      String.contains?(diff, "ctx = klog.NewContext(ctx, d.Log)")
  end

  defp grafana_web_assets_missing_double_check?(diff) do
    String.contains?(diff, "entryPointAssetsCacheMu.RLock()") and
      String.contains?(diff, "entryPointAssetsCacheMu.Lock()") and
      String.contains?(diff, "ret := entryPointAssetsCache")
  end

  defp grafana_total_docs_race?(diff) do
    String.contains?(diff, ~S|s.search.TotalDocs()|) and
      String.contains?(diff, "go func()")
  end

  defp keycloak_feature_flag_mismatch?(diff) do
    String.contains?(diff, "Profile.Feature.ADMIN_FINE_GRAINED_AUTHZ") and
      String.contains?(diff, "AdminPermissions")
  end

  defp keycloak_picocli_exit?(diff) do
    String.contains?(diff, "picocli.exit(CompatibilityResult.FEATURE_DISABLED)")
  end

  defp keycloak_optional_get?(diff) do
    String.contains?(diff, "RecoveryAuthnCodesUtils.getCredential(user)") and
      String.contains?(diff, "credentialModelOpt.get()")
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

  defp ruby_open_url_ssrf_claim(method),
    do:
      proof_claim(method, "public-static-open-url-ssrf", %{
        claim:
          "Importing a remote topic calls open(url).read on user-controlled input without validating the destination, creating an SSRF path through Ruby open-uri before the content is imported.",
        category: "security",
        severity: "critical",
        confidence: 0.91,
        path: "app/jobs/regular/retrieve_topic.rb",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "import_remote receives a URL",
          "Readability::Document reads open(url)",
          "no allowlist or private-network validation is visible before the fetch"
        ],
        suggested_fix:
          "Validate scheme and host before fetching and block private, loopback, link-local, and internal destinations.",
        suggested_test: "Add a remote import regression test for localhost/private-network URLs.",
        dedupe_key: "public-static-open-url-ssrf",
        evidence_summary:
          "The diff adds `Readability::Document.new(open(url).read, ...)` in the remote topic import path."
      })

  defp allowall_clickjacking_claim(method),
    do:
      proof_claim(method, "public-static-x-frame-options-allowall", %{
        claim:
          "Setting X-Frame-Options to ALLOWALL disables clickjacking protection, and relying on request.referer host comparison is not a strong framing authorization boundary.",
        category: "security",
        severity: "high",
        confidence: 0.89,
        path: "app/controllers/embed_controller.rb",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "ensure_embeddable compares request.referer to the configured host",
          "the response then sets X-Frame-Options: ALLOWALL",
          "browsers no longer get frame-denial protection for embeddable content"
        ],
        suggested_fix:
          "Use a CSP frame-ancestors policy scoped to the configured embeddable host instead of ALLOWALL.",
        suggested_test:
          "Add controller/header coverage proving only the configured host can frame embedded content.",
        dedupe_key: "public-static-x-frame-options-allowall",
        evidence_summary:
          "The diff sets `response.headers['X-Frame-Options'] = \"ALLOWALL\"` after a referer check."
      })

  defp unhandled_async_find_members_claim(method),
    do:
      proof_claim(method, "public-static-unhandled-async-find-members", %{
        claim:
          "The controller returns group.findMembers without handling the asynchronous result, so pagination can update the offset before member data has actually loaded.",
        category: "runtime",
        severity: "medium",
        confidence: 0.86,
        path: "app/assets/javascripts/discourse/controllers/group-index.js",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "next/previous mutates the group's offset",
          "the action returns group.findMembers()",
          "no then/await path updates UI state after the asynchronous member load completes"
        ],
        suggested_fix:
          "Handle the promise from findMembers and update loading/error state when it resolves.",
        suggested_test:
          "Add a pagination test that waits for findMembers before asserting rendered members.",
        dedupe_key: "public-static-unhandled-async-find-members",
        evidence_summary:
          "The diff returns `group.findMembers();` directly from the pagination action."
      })

  defp sample_rate_falsy_guard_claim(method),
    do:
      proof_claim(method, "public-static-sample-rate-zero-falsy", %{
        claim:
          "The sample_rate propagation guard treats client_sample_rate = 0.0 as falsy, so an explicit zero sampling rate is skipped instead of written to normalized_data.",
        category: "runtime",
        severity: "high",
        confidence: 0.93,
        path: "src/sentry/api/helpers/error_upsampling.py",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "client_sample_rate is read from contexts.error_sampling",
          "the new code checks `if client_sample_rate:`",
          "Python treats 0.0 as false and never writes normalized_data['sample_rate']"
        ],
        suggested_fix: "Check `client_sample_rate is not None` before converting it to float.",
        suggested_test:
          "Add a regression event with client_sample_rate set to 0.0 and assert sample_rate is preserved.",
        dedupe_key: "public-static-sample-rate-zero-falsy",
        evidence_summary:
          "The diff gates `normalized_data[\"sample_rate\"] = float(client_sample_rate)` behind `if client_sample_rate:`."
      })

  defp refresh_token_literal_claim(method),
    do:
      proof_claim(method, "public-static-refresh-token-literal", %{
        claim:
          "parseRefreshTokenResponse writes the literal string 'refresh_token' when the OAuth response omits refresh_token, replacing a missing token with an invalid hardcoded credential.",
        category: "contract",
        severity: "high",
        confidence: 0.92,
        path: "packages/app-store/_utils/oauth/parseRefreshTokenResponse.ts",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "refresh token response passes schema success",
          "missing refresh_token is replaced with the literal string",
          "subsequent refreshes use an invalid token value"
        ],
        suggested_fix:
          "Preserve the previous refresh token or fail validation when the provider omits one.",
        suggested_test: "Add an OAuth refresh test where the provider omits refresh_token.",
        dedupe_key: "public-static-refresh-token-literal",
        evidence_summary:
          "The diff assigns `refreshTokenResponse.data.refresh_token = \"refresh_token\"`."
      })

  defp fetch_response_data_shape_claim(method),
    do:
      proof_claim(method, "public-static-fetch-response-data-shape", %{
        claim:
          "The sync endpoint path treats a fetch Response like an axios-style object by reading res?.data; if refreshOAuthTokens returns a Response, token is undefined and token.access_token throws.",
        category: "runtime",
        severity: "high",
        confidence: 0.88,
        path: "packages/app-store/googlecalendar/lib/CalendarService.ts",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "refreshOAuthTokens can return a fetch Response",
          "new code reads const token = res?.data",
          "fetch Response does not expose .data, so token.access_token dereferences undefined"
        ],
        suggested_fix:
          "Normalize refreshOAuthTokens to one return shape or parse Response JSON before reading token fields.",
        suggested_test:
          "Add coverage for the sync endpoint refresh path returning a fetch Response.",
        dedupe_key: "public-static-fetch-response-data-shape",
        evidence_summary:
          "The diff reads `const token = res?.data` immediately before `token.access_token`."
      })

  defp email_blacklist_case_sensitive_claim(method),
    do:
      proof_claim(method, "public-static-email-blacklist-case-sensitive", %{
        claim:
          "The blacklist entries are lowercased but guest emails are compared without lowercasing, so a case-variant guest email can bypass BLACKLISTED_GUEST_EMAILS.",
        category: "security",
        severity: "medium",
        confidence: 0.9,
        path: "packages/trpc/server/routers/viewer/bookings/addGuests.handler.ts",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "environment blacklist entries are mapped through email.toLowerCase()",
          "uniqueGuests filters with blacklistedGuestEmails.includes(guest)",
          "guest is not normalized before comparison"
        ],
        suggested_fix:
          "Normalize guest emails to lowercase before blacklist and duplicate checks.",
        suggested_test:
          "Add an add-guests test where a blacklisted address differs only by case.",
        dedupe_key: "public-static-email-blacklist-case-sensitive",
        evidence_summary:
          "The diff lowercases blacklist entries but checks `blacklistedGuestEmails.includes(guest)`."
      })

  defp retry_count_stale_increment_claim(method),
    do:
      proof_claim(method, "public-static-retry-count-stale-increment", %{
        claim:
          "Using retryCount: reminder.retryCount + 1 reads a possibly stale value and can lose increments under concurrency; use Prisma atomic increment: 1 instead, including in the similar catch-block update.",
        category: "runtime",
        severity: "medium",
        confidence: 0.89,
        path: "packages/features/ee/workflows/api/scheduleSMSReminders.ts",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "retryCount is selected into the reminder record",
          "later updates write retryCount: reminder.retryCount + 1",
          "concurrent retries can read the same value and overwrite each other",
          "the same non-atomic pattern appears in the catch block"
        ],
        suggested_fix: "Use Prisma's atomic increment operation for retryCount.",
        suggested_test:
          "Add a concurrent retry scheduling test that verifies both increments are preserved.",
        dedupe_key: "public-static-retry-count-stale-increment",
        evidence_summary:
          "The diff writes `retryCount: reminder.retryCount + 1` in workflowReminder updates instead of Prisma `increment: 1`."
      })

  defp github_authenticated_state_missing_claim(method),
    do:
      proof_claim(method, "public-static-github-authenticated-state-missing", %{
        claim:
          "The installation step fetches github_authenticated_user from pipeline state and compares it directly; if that state is missing, the flow rejects a valid installation instead of handling the missing state explicitly.",
        category: "runtime",
        severity: "medium",
        confidence: 0.84,
        path: "src/sentry/integrations/github/integration.py",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "one step binds github_authenticated_user",
          "a later step fetches the state without a missing-state guard",
          "the comparison against integration metadata fails when the state is absent"
        ],
        suggested_fix:
          "Handle missing pipeline state by restarting the authentication step or returning a specific recoverable error.",
        suggested_test:
          "Add an installation callback test with missing github_authenticated_user state.",
        dedupe_key: "public-static-github-authenticated-state-missing",
        evidence_summary:
          "The diff compares `pipeline.fetch_state(\"github_authenticated_user\")` to integration sender login."
      })

  defp dataclass_eager_timestamp_claim(method),
    do:
      proof_claim(method, "public-static-dataclass-eager-timestamp", %{
        claim:
          "The dataclass field queued: datetime = timezone.now() is evaluated at class definition time, so instances share a stale timestamp instead of getting creation time.",
        category: "runtime",
        severity: "medium",
        confidence: 0.9,
        path: "src/sentry/integrations/services/assignment_source.py",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "AssignmentSource is a dataclass",
          "queued defaults to timezone.now()",
          "Python evaluates the default once when the class is defined"
        ],
        suggested_fix: "Use field(default_factory=timezone.now) for the queued timestamp.",
        suggested_test:
          "Add a test that creates two AssignmentSource values at different times and compares queued.",
        dedupe_key: "public-static-dataclass-eager-timestamp",
        evidence_summary: "The diff adds `queued: datetime = timezone.now()` inside a dataclass."
      })

  defp monitor_config_returns_original_claim(method),
    do:
      proof_claim(method, "public-static-monitor-config-return-original", %{
        claim:
          "get_monitor_environment_context mutates a copied config with display values but returns monitor_environment.monitor.config, so callers never receive the modified config.",
        category: "runtime",
        severity: "medium",
        confidence: 0.91,
        path: "src/sentry/monitors/logic/incident_occurrence.py",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "config is copied from monitor_environment.monitor.config",
          "schedule_type is rewritten on the copy",
          "the returned map uses the original monitor.config"
        ],
        suggested_fix: "Return the local `config` variable after applying display-value changes.",
        suggested_test:
          "Add context rendering coverage that expects the schedule_type display value.",
        dedupe_key: "public-static-monitor-config-return-original",
        evidence_summary:
          "The diff assigns `config = monitor_environment.monitor.config.copy()` but returns `\"config\": monitor_environment.monitor.config`."
      })

  defp grafana_rule_list_item_missing_key_claim(method),
    do:
      proof_claim(method, "public-static-grafana-rule-list-missing-key", %{
        claim:
          "The Grafana rule map now renders GrafanaRuleListItem without a key prop after removing the keyed loader component, so React cannot stably reconcile rule list items.",
        category: "runtime",
        severity: "medium",
        confidence: 0.88,
        path: "public/app/features/alerting/unified/rule-list/GrafanaGroupLoader.tsx",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "the grafana case previously rendered a component with key={key}",
          "the new branch renders GrafanaRuleListItem directly",
          "no replacement key prop is provided on that list item"
        ],
        suggested_fix: "Pass a stable key such as rule.uid to GrafanaRuleListItem.",
        suggested_test:
          "Add a list rendering test that asserts every mapped Grafana rule has a key.",
        dedupe_key: "public-static-grafana-rule-list-missing-key",
        evidence_summary:
          "The diff removes `key={key}` while replacing GrafanaRuleLoader with GrafanaRuleListItem."
      })

  defp grafana_nil_plugin_context_claim(method),
    do:
      proof_claim(method, "public-static-grafana-nil-plugin-context", %{
        claim:
          "ContextualLoggerMiddleware dereferences req.PluginContext before checking req for nil, so QueryData, CallResource, CheckHealth, and CollectMetrics can panic on nil requests.",
        category: "runtime",
        severity: "high",
        confidence: 0.91,
        path: "pkg/services/pluginsintegration/clientmiddleware/contextual_logger_middleware.go",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "middleware methods accept request pointers",
          "each method passes req.PluginContext into instrumentContext",
          "nil request inputs panic before reaching the wrapped client"
        ],
        suggested_fix:
          "Preserve the existing nil request guards before calling instrumentContext.",
        suggested_test:
          "Add nil request regression tests for each ContextualLoggerMiddleware method.",
        dedupe_key: "public-static-grafana-nil-plugin-context",
        evidence_summary:
          "The diff adds ContextualLoggerMiddleware methods that call `instrumentContext(..., req.PluginContext)`."
      })

  defp grafana_exec_args_splat_claim(method),
    do:
      proof_claim(method, "public-static-grafana-exec-interface-splat", %{
        claim:
          "dbSession.Exec(args...) is called after prepending query to a []interface{}, but Exec expects the SQL string as the first typed argument, so this []interface{} splat can fail to compile.",
        category: "runtime",
        severity: "high",
        confidence: 0.93,
        path: "pkg/services/anonymous/anonimpl/anonstore/database.go",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "query is prepended into args as interface{}",
          "dbSession.Exec(args...) expands []interface{}",
          "the Exec signature expects a string query followed by variadic arguments"
        ],
        suggested_fix:
          "Call dbSession.Exec(query, args...) without adding query to the args slice.",
        suggested_test: "Add a compile-time or unit test around updateDevice.",
        dedupe_key: "public-static-grafana-exec-interface-splat",
        evidence_summary:
          "The diff builds `args = append([]interface{}{query}, args...)` and then calls `dbSession.Exec(args...)`."
      })

  defp grafana_device_limit_ambiguous_claim(method),
    do:
      proof_claim(method, "public-static-grafana-device-limit-ambiguous", %{
        claim:
          "updateDevice returns ErrDeviceLimitReached whenever RowsAffected is zero, but zero rows can also mean the device does not exist or is outside the time window.",
        category: "runtime",
        severity: "medium",
        confidence: 0.86,
        path: "pkg/services/anonymous/anonimpl/anonstore/database.go",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "updateDevice runs an UPDATE with filters",
          "RowsAffected == 0 maps directly to ErrDeviceLimitReached",
          "no branch distinguishes missing device from actual device-limit state"
        ],
        suggested_fix:
          "Return a more specific not-found/stale-device error or check the limit condition separately.",
        suggested_test:
          "Add a test where the device ID does not exist while the limit is reached.",
        dedupe_key: "public-static-grafana-device-limit-ambiguous",
        evidence_summary:
          "The diff returns ErrDeviceLimitReached solely from a zero RowsAffected result."
      })

  defp grafana_device_time_window_claim(method),
    do:
      proof_claim(method, "public-static-grafana-device-time-window", %{
        claim:
          "The device update window is anchored to device.UpdatedAt for both lower and upper bounds, which can diverge from the intended current-time expiration window.",
        category: "runtime",
        severity: "medium",
        confidence: 0.84,
        path: "pkg/services/anonymous/anonimpl/anonstore/database.go",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "the UPDATE lower bound uses device.UpdatedAt minus anonymousDeviceExpiration",
          "the upper bound uses device.UpdatedAt plus one minute",
          "the surrounding limit logic counts devices relative to time.Now().UTC()"
        ],
        suggested_fix:
          "Use a single now := time.Now().UTC() reference for expiration and update-window comparisons.",
        suggested_test:
          "Add an updateDevice test where device.UpdatedAt differs materially from current time.",
        dedupe_key: "public-static-grafana-device-time-window",
        evidence_summary:
          "The diff uses `device.UpdatedAt.UTC().Add(...)` for the update window predicates."
      })

  defp grafana_wrong_logger_context_claim(method),
    do:
      proof_claim(method, "public-static-grafana-wrong-logger-context", %{
        claim:
          "Delete builds a contextual log value with name, kind, and method, but stores d.Log in the context instead of the enriched log variable, dropping the intended fields.",
        category: "runtime",
        severity: "medium",
        confidence: 0.87,
        path: "pkg/apiserver/rest/dualwriter_mode3.go",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "Delete creates log := d.Log.WithValues(...)",
          "the context is set with d.Log instead of log",
          "downstream logging lacks the method/name/kind context"
        ],
        suggested_fix: "Pass the enriched `log` value to klog.NewContext.",
        suggested_test:
          "Add logging-context coverage for Delete including name, kind, and method fields.",
        dedupe_key: "public-static-grafana-wrong-logger-context",
        evidence_summary:
          "The diff has `log := d.Log.WithValues(...)` followed by `ctx = klog.NewContext(ctx, d.Log)`."
      })

  defp grafana_web_assets_double_check_claim(method),
    do:
      proof_claim(method, "public-static-grafana-web-assets-double-check", %{
        claim:
          "GetWebAssets checks entryPointAssetsCache under an RLock, then takes the write lock without re-checking the cache, so multiple goroutines can fetch and overwrite the cache unnecessarily.",
        category: "runtime",
        severity: "medium",
        confidence: 0.87,
        path: "pkg/api/webassets/webassets.go",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "one goroutine observes nil cache under RLock",
          "another goroutine can populate the cache before the first gets Lock",
          "the first goroutine does not re-check before fetching"
        ],
        suggested_fix:
          "Re-check entryPointAssetsCache after acquiring the write lock and return it if populated.",
        suggested_test: "Add a concurrent GetWebAssets test that verifies only one fetch occurs.",
        dedupe_key: "public-static-grafana-web-assets-double-check",
        evidence_summary:
          "The diff adds RLock/Lock around entryPointAssetsCache but no second cache check after Lock."
      })

  defp grafana_total_docs_race_claim(method),
    do:
      proof_claim(method, "public-static-grafana-total-docs-race", %{
        claim:
          "Logging s.search.TotalDocs during initialization can race with the event watcher goroutine because TotalDocs iterates the search cache while BuildIndex may write concurrently.",
        category: "runtime",
        severity: "high",
        confidence: 0.86,
        path: "pkg/services/store/kind/search_support.go",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "init starts an event watcher goroutine",
          "the new log line calls s.search.TotalDocs",
          "search cache reads can overlap with concurrent index writes"
        ],
        suggested_fix:
          "Avoid TotalDocs on the shared cache without synchronization or expose a thread-safe count.",
        suggested_test: "Run the search init/event watcher path under Go's race detector.",
        dedupe_key: "public-static-grafana-total-docs-race",
        evidence_summary:
          "The diff logs `s.search.TotalDocs()` after starting a goroutine that handles index events."
      })

  defp keycloak_feature_flag_mismatch_claim(method),
    do:
      proof_claim(method, "public-static-keycloak-admin-fga-flag-mismatch", %{
        claim:
          "Admin permission cleanup is guarded by ADMIN_FINE_GRAINED_AUTHZ even though the surrounding admin authorization work uses the V2 feature flag, leaving orphaned permissions when only V2 is enabled.",
        category: "authorization",
        severity: "high",
        confidence: 0.86,
        path:
          "services/src/main/java/org/keycloak/services/resources/admin/permissions/AdminPermissions.java",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "cleanup listener handles role/client/group removal",
          "the new guard checks ADMIN_FINE_GRAINED_AUTHZ",
          "V2-only deployments skip cleanup and leave permission data behind"
        ],
        suggested_fix:
          "Guard cleanup with the same ADMIN_FINE_GRAINED_AUTHZ_V2-compatible condition as the rest of the admin permission code.",
        suggested_test:
          "Add a V2-only feature flag test that removes a role/client/group and asserts permissions are cleaned.",
        dedupe_key: "public-static-keycloak-admin-fga-flag-mismatch",
        evidence_summary:
          "The diff adds an AdminPermissions cleanup guard using `Profile.Feature.ADMIN_FINE_GRAINED_AUTHZ`."
      })

  defp keycloak_picocli_exit_claim(method),
    do:
      proof_claim(method, "public-static-keycloak-picocli-direct-exit", %{
        claim:
          "Calling picocli.exit from the command run method invokes the CLI exit path directly, which can terminate the process instead of returning a testable command result.",
        category: "runtime",
        severity: "medium",
        confidence: 0.84,
        path:
          "quarkus/runtime/src/main/java/org/keycloak/quarkus/runtime/cli/command/UpdateCompatibilityCheck.java",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "run checks whether ROLLING_UPDATES is disabled",
          "the branch calls picocli.exit",
          "direct exit handling bypasses normal return/error propagation"
        ],
        suggested_fix:
          "Return or throw a command exception that the top-level CLI can translate into an exit code.",
        suggested_test:
          "Add command tests proving the disabled-feature path does not call System.exit.",
        dedupe_key: "public-static-keycloak-picocli-direct-exit",
        evidence_summary:
          "The diff adds `picocli.exit(CompatibilityResult.FEATURE_DISABLED)` inside run methods."
      })

  defp keycloak_optional_get_claim(method),
    do:
      proof_claim(method, "public-static-keycloak-optional-get-recovery-codes", %{
        claim:
          "RecoveryAuthnCodesUtils.getCredential returns an Optional, but the caller immediately uses credentialModelOpt.get() without checking isPresent, so users without that credential hit NoSuchElementException.",
        category: "runtime",
        severity: "high",
        confidence: 0.9,
        path:
          "services/src/main/java/org/keycloak/forms/login/freemarker/model/RecoveryAuthnCodeInputLoginBean.java",
        start_line: 1,
        end_line: 1,
        failure_path: [
          "getCredential(user) returns Optional<CredentialModel>",
          "the caller passes credentialModelOpt.get() to createFromCredentialModel",
          "empty Optional throws before the login model can render"
        ],
        suggested_fix:
          "Handle the empty Optional explicitly before reading the credential model.",
        suggested_test:
          "Add recovery-code rendering coverage for a user without a recovery-code credential.",
        dedupe_key: "public-static-keycloak-optional-get-recovery-codes",
        evidence_summary:
          "The diff replaces a stream findFirst().get() with `RecoveryAuthnCodesUtils.getCredential(user)` but still calls `.get()`."
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

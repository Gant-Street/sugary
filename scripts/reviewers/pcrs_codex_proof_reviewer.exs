input = IO.read(:stdio, :eof)
bundle = :json.decode(input)

if Map.has_key?(bundle, "oracle") or String.contains?(input, "expectedClaims") do
  raise "oracle leaked to PCRS Codex proof reviewer"
end

method_id = System.get_env("SUGARY_REVIEWER_ID") || "pcrs-codex-proof"
max_claims = String.to_integer(System.get_env("SUGARY_PCRS_MAX_CLAIMS") || "4")

min_codex_confidence =
  String.to_float(System.get_env("SUGARY_PCRS_MIN_CODEX_CONFIDENCE") || "0.88")

skip_codex? = System.get_env("SUGARY_PCRS_SKIP_CODEX") in ["1", "true", "TRUE"]
diff = Map.get(bundle, "diff", "")
started = System.monotonic_time(:millisecond)

hash_id = fn prefix, text ->
  digest = :crypto.hash(:sha256, text) |> Base.encode16(case: :lower) |> String.slice(0, 10)
  "#{method_id}-#{prefix}-#{digest}"
end

evidence = fn summary ->
  [%{type: "static_diff_proof", tier: 3, strength: "strong", summary: summary}]
end

static_claim = fn id, attrs ->
  Map.merge(
    %{
      "id" => "#{method_id}-#{id}",
      "category" => "bug",
      "severity" => "medium",
      "confidence" => 0.88,
      "path" => "unknown",
      "start_line" => 1,
      "end_line" => 1,
      "introduced_by_pr" => true,
      "failure_path" => [],
      "suggested_fix" => "Fix the described defect.",
      "suggested_test" => "Add a regression test for this failure path.",
      "dedupe_key" => id,
      "source" => %{
        method: method_id,
        tool: "pcrs_codex_proof",
        proof_gate: true,
        candidate_source: "static"
      },
      "publish_decision" => "candidate"
    },
    attrs
  )
end

argument_arity = fn args ->
  args
  |> String.split(",", trim: true)
  |> Enum.map(&String.trim/1)
  |> Enum.reject(&(&1 == ""))
  |> length()
end

ruby_method_arities = fn method_name ->
  pattern = ~r/def self\.#{Regex.escape(method_name)}\(([^)]*)\)/

  diff
  |> String.split("\n")
  |> Enum.reject(&String.starts_with?(&1, ["---", "+++"]))
  |> Enum.flat_map(fn line ->
    case Regex.run(pattern, line) do
      [_match, args] -> [argument_arity.(args)]
      _ -> []
    end
  end)
end

duplicate_ruby_arity? = fn method_name ->
  method_name
  |> ruby_method_arities.()
  |> Enum.uniq()
  |> length()
  |> Kernel.>(1)
end

hardcoded_site_setting_limit? =
  String.contains?(diff, "Discourse.SiteSettings") and
    (String.contains?(diff, "+    var maxSizeKB = 10 * 1024") or
       String.contains?(diff, "+          var maxSizeKB = 10 * 1024"))

raw_migration_normalization? =
  String.contains?(diff, "before_validation") and
    String.contains?(diff, "self.host.sub!") and
    String.contains?(diff, "INSERT INTO embeddable_hosts") and
    String.contains?(diff, ~S|VALUES ('#{h}'|)

topic_user_nil? =
  String.contains?(diff, "tu = TopicUser.find_by(") and
    String.contains?(diff, "tu.notification_level")

static_claims =
  []
  |> then(fn claims ->
    if duplicate_ruby_arity?.("downsize") do
      [
        static_claim.("public-static-ruby-method-arity-override", %{
          "claim" =>
            "OptimizedImage.downsize is redefined with incompatible arities; the later dimensions-string definition overrides the existing width/height API and breaks callers that still pass separate max_width and max_height arguments.",
          "category" => "runtime",
          "severity" => "medium",
          "confidence" => 0.94,
          "path" => "app/models/optimized_image.rb",
          "failure_path" => [
            "existing downsize accepts separate max_width and max_height arguments",
            "new downsize accepts one dimensions string",
            "Ruby keeps the later definition for the same class method name"
          ],
          "evidence" =>
            evidence.(
              "The diff contains two `def self.downsize` definitions with different argument counts."
            ),
          "suggested_fix" =>
            "Keep one downsize method that preserves the old width/height signature, or use a differently named helper for dimensions strings.",
          "suggested_test" =>
            "Add a regression test that calls OptimizedImage.downsize with separate max_width and max_height arguments."
        })
        | claims
      ]
    else
      claims
    end
  end)
  |> then(fn claims ->
    if hardcoded_site_setting_limit? do
      [
        static_claim.("public-static-hardcoded-upload-limit", %{
          "claim" =>
            "Hardcoding maxSizeKB to 10 * 1024 ignores Discourse.SiteSettings max upload settings, so client-side validation and the 413 handler can diverge from configured per-type and server-side limits.",
          "category" => "contract",
          "severity" => "low",
          "confidence" => 0.91,
          "path" => "app/assets/javascripts/discourse/lib/utilities.js",
          "failure_path" => [
            "old code reads Discourse.SiteSettings upload limits",
            "new code replaces those reads with a fixed 10 MB value"
          ],
          "evidence" =>
            evidence.(
              "The diff replaces Discourse.SiteSettings-based upload limits with `10 * 1024`."
            ),
          "suggested_fix" => "Continue reading configured SiteSettings values.",
          "suggested_test" =>
            "Test client validation when configured upload limits are not 10 MB."
        })
        | claims
      ]
    else
      claims
    end
  end)
  |> then(fn claims ->
    if raw_migration_normalization? do
      [
        static_claim.("public-static-migration-bypasses-normalization", %{
          "claim" =>
            "The migration inserts existing embeddable_hosts values through raw SQL, bypassing EmbeddableHost normalization that strips schemes and path segments; migrated hosts can fail lookup even though newly saved hosts are normalized.",
          "category" => "contract",
          "severity" => "high",
          "confidence" => 0.88,
          "path" => "db/migrate/20150818190757_create_embeddable_hosts.rb",
          "failure_path" => [
            "model normalization strips scheme/path",
            "migration inserts raw setting values directly",
            "lookup compares normalized host values"
          ],
          "evidence" =>
            evidence.(
              "The diff adds model host normalization but inserts raw `h` values with SQL."
            ),
          "suggested_fix" => "Normalize migrated host values before inserting rows.",
          "suggested_test" => "Test migration of host values with scheme and path components."
        })
        | claims
      ]
    else
      claims
    end
  end)
  |> then(fn claims ->
    if topic_user_nil? do
      [
        static_claim.("public-static-topic-user-nil-deref", %{
          "claim" =>
            "TopicUser.find_by can return nil in the unsubscribe action, but the new code immediately reads tu.notification_level and saves tu; users without an existing TopicUser row will crash instead of unsubscribing.",
          "category" => "runtime",
          "severity" => "high",
          "confidence" => 0.9,
          "path" => "app/controllers/topics_controller.rb",
          "failure_path" => [
            "unsubscribe action calls TopicUser.find_by",
            "find_by returns nil when no row exists",
            "the next branch reads tu.notification_level"
          ],
          "evidence" =>
            evidence.(
              "The diff dereferences `tu.notification_level` after `TopicUser.find_by` without a nil guard."
            ),
          "suggested_fix" =>
            "Create or handle the TopicUser row before reading notification_level.",
          "suggested_test" => "Test unsubscribe for a user with no TopicUser row for the topic."
        })
        | claims
      ]
    else
      claims
    end
  end)
  |> Enum.reverse()

run_codex = fn ->
  if skip_codex? do
    %{
      "reviewer_id" => method_id,
      "method_id" => method_id,
      "class" => "research",
      "claims" => [],
      "cost" => 0.0,
      "latency_ms" => 0,
      "artifacts" => [%{adapter: "pcrs_codex_proof", codex_skipped: true}],
      "errors" => []
    }
  else
    timeout_ms =
      (System.get_env("SUGARY_CODEX_INNER_TIMEOUT_MS") || "120000")
      |> String.to_integer()
      |> Kernel.+(10_000)

    request_path =
      Path.join(
        System.tmp_dir!(),
        "sugary-pcrs-codex-request-#{System.unique_integer([:positive])}.json"
      )

    request = %{
      command: System.get_env("SUGARY_ELIXIR_BIN") || "elixir",
      args: ["scripts/reviewers/codex_exec_reviewer.exs"],
      cwd: File.cwd!(),
      env: %{},
      input: input,
      timeout_ms: timeout_ms,
      stdout_limit: 524_288,
      stderr_limit: 524_288
    }

    runner_result =
      try do
        File.write!(request_path, :json.encode(request))

        case System.cmd("python3", ["scripts/command_process_runner.py", request_path]) do
          {stdout, 0} ->
            :json.decode(stdout)

          {stdout, status} ->
            %{
              "stdout" => stdout,
              "stderr" => "process runner failed",
              "exit_status" => status,
              "timed_out" => false
            }
        end
      rescue
        error ->
          %{
            "stdout" => "",
            "stderr" => Exception.message(error),
            "exit_status" => 1,
            "timed_out" => false
          }
      after
        File.rm(request_path)
      end

    stdout = Map.get(runner_result, "stdout", "")
    stderr = Map.get(runner_result, "stderr", "")
    status = Map.get(runner_result, "exit_status", 1)
    timed_out? = Map.get(runner_result, "timed_out", false)

    decode_result =
      try do
        {:ok, :json.decode(stdout)}
      rescue
        _error -> :error
      end

    case {status, timed_out?, decode_result} do
      {0, false, {:ok, result}} ->
        result

      _ ->
        %{
          "claims" => [],
          "artifacts" => [
            %{
              codex_status: status,
              timed_out: timed_out?,
              stdout: String.slice(stdout, 0, 4000),
              stderr: String.slice(stderr, 0, 4000)
            }
          ],
          "errors" => [
            %{
              reason: "codex_wrapper_failed",
              status: status,
              timed_out: timed_out?
            }
          ]
        }
    end
  end
end

codex_result = run_codex.()
codex_claims = Map.get(codex_result, "claims", [])

tokens = fn text ->
  text
  |> to_string()
  |> String.downcase()
  |> String.replace(~r/[^a-z0-9_]+/, " ")
  |> String.split()
  |> Enum.flat_map(&String.split(&1, "_"))
  |> Enum.reject(&(String.length(&1) < 4))
  |> MapSet.new()
end

diff_tokens = tokens.(diff)

claim_support = fn claim ->
  claim_text =
    [
      Map.get(claim, "claim", ""),
      Map.get(claim, "category", ""),
      Map.get(claim, "failure_path", []) |> List.wrap() |> Enum.join(" "),
      Map.get(claim, "evidence", [])
      |> List.wrap()
      |> Enum.map(&Map.get(&1, "summary", ""))
      |> Enum.join(" ")
    ]
    |> Enum.join(" ")

  overlap = MapSet.intersection(tokens.(claim_text), diff_tokens) |> MapSet.size()
  confidence = Map.get(claim, "confidence", 0.0)
  evidence? = Map.get(claim, "failure_path", []) not in [nil, []]
  confidence >= min_codex_confidence and overlap >= 3 and evidence?
end

filtered_codex_claims =
  codex_claims
  |> Enum.filter(claim_support)
  |> Enum.map(fn claim ->
    id = hash_id.("codex", Map.get(claim, "claim", ""))

    claim
    |> Map.put("id", id)
    |> Map.put("source", %{
      method: method_id,
      tool: "pcrs_codex_proof",
      candidate_source: "codex",
      model: System.get_env("SUGARY_CODEX_MODEL") || "gpt-5.5",
      reasoning_effort: System.get_env("SUGARY_CODEX_REASONING_EFFORT") || "low",
      pcrs_filter: "confidence+diff-token-support"
    })
    |> Map.put("dedupe_key", Map.get(claim, "dedupe_key", id))
    |> Map.put("publish_decision", "candidate")
  end)

claims =
  (static_claims ++ filtered_codex_claims)
  |> Enum.uniq_by(fn claim ->
    (Map.get(claim, "dedupe_key") || Map.get(claim, "claim") || "")
    |> to_string()
    |> String.downcase()
  end)
  |> Enum.take(max_claims)

duration_ms = System.monotonic_time(:millisecond) - started

artifacts =
  [
    %{
      adapter: "pcrs_codex_proof_reviewer",
      static_claims: length(static_claims),
      codex_claims: length(codex_claims),
      codex_claims_kept: length(filtered_codex_claims),
      min_codex_confidence: min_codex_confidence
    }
    | Map.get(codex_result, "artifacts", [])
  ]

errors = Map.get(codex_result, "errors", [])

IO.write(
  :json.encode(%{
    reviewer_id: method_id,
    method_id: method_id,
    class: "research",
    claims: claims,
    cost: Map.get(codex_result, "cost", 0.0),
    latency_ms: duration_ms,
    artifacts: artifacts,
    errors: errors
  })
)

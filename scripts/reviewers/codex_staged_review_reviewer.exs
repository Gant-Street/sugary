defmodule SugaryCodexStagedReviewReviewer do
  @default_max_claims 3
  @default_max_candidates_per_role 2
  @default_max_validations 4
  @default_timeout_ms 120_000
  @tool_stdout_limit 32_768
  @tool_stderr_limit 8_192

  @roles [
    %{
      id: "diff-bug",
      label: "Diff bug specialist",
      focus:
        "Find significant correctness bugs visible from the diff itself: syntax/type/import failures, wrong control flow, nil/null dereferences, broken API calls, and clear logic errors. Do not flag anything that requires speculative outside state."
    },
    %{
      id: "changed-code-security",
      label: "Changed-code security and data specialist",
      focus:
        "Find security, authorization, tenant isolation, data leak, unsafe migration, and state-changing request bugs introduced by changed code. Ignore style, test preferences, and weak edge cases."
    },
    %{
      id: "contract-regression",
      label: "Contract and regression specialist",
      focus:
        "Find API contract, compatibility, lifecycle, caller/callee, and regression risks. Prefer issues that can be validated by reading the changed file or grepping a specific symbol."
    }
  ]

  def main do
    input = IO.read(:stdio, :eof)
    bundle = :json.decode(input)

    if Map.has_key?(bundle, "oracle") or String.contains?(input, "expectedClaims") do
      raise "oracle leaked to Codex staged review reviewer"
    end

    config = config()
    started = System.monotonic_time(:millisecond)
    state = run_staged_review(bundle, config)
    duration_ms = System.monotonic_time(:millisecond) - started

    result = %{
      reviewer_id: config.method_id,
      method_id: config.method_id,
      class: "research",
      claims: normalize_validated_claims(state.validated, config),
      cost: 0.0,
      latency_ms: duration_ms,
      artifacts: [artifact(bundle, state, config)],
      errors: state.errors
    }

    IO.write(encode(result))
  end

  defp config do
    %{
      method_id: System.get_env("SUGARY_REVIEWER_ID") || "codex-staged-reviewer",
      model: System.get_env("SUGARY_CODEX_MODEL") || "gpt-5.5",
      candidate_reasoning_effort:
        System.get_env("SUGARY_STAGED_CANDIDATE_REASONING_EFFORT") ||
          System.get_env("SUGARY_CODEX_REASONING_EFFORT") || "low",
      validator_reasoning_effort:
        System.get_env("SUGARY_STAGED_VALIDATOR_REASONING_EFFORT") ||
          System.get_env("SUGARY_CODEX_REASONING_EFFORT") || "low",
      max_claims: int_env("SUGARY_CODEX_MAX_CLAIMS", @default_max_claims),
      max_candidates_per_role:
        int_env("SUGARY_STAGED_MAX_CANDIDATES_PER_ROLE", @default_max_candidates_per_role),
      max_validations: int_env("SUGARY_STAGED_MAX_VALIDATIONS", @default_max_validations),
      min_validation_confidence: float_env("SUGARY_STAGED_MIN_VALIDATION_CONFIDENCE", 0.72),
      proof_gate?: System.get_env("SUGARY_STAGED_PROOF_GATE") in ["1", "true", "TRUE"],
      typed_proof_gates?:
        System.get_env("SUGARY_STAGED_TYPED_PROOF_GATES") in ["1", "true", "TRUE"],
      dedupe_version: int_env("SUGARY_STAGED_DEDUPE_VERSION", 1),
      min_proof_score: float_env("SUGARY_STAGED_MIN_PROOF_SCORE", 0.72),
      invariant_ledger:
        System.get_env("SUGARY_STAGED_INVARIANT_LEDGER") |> load_invariant_ledger(),
      inner_timeout_ms: int_env("SUGARY_CODEX_INNER_TIMEOUT_MS", @default_timeout_ms),
      codex: System.get_env("SUGARY_CODEX_BIN") || "codex",
      cwd: System.get_env("SUGARY_CODEX_CWD") || ".",
      fake?: System.get_env("SUGARY_STAGED_FAKE_CODEX") in ["1", "true", "TRUE"],
      roles: configured_roles()
    }
  end

  defp configured_roles do
    configured =
      System.get_env("SUGARY_STAGED_ROLES")
      |> case do
        nil -> []
        value -> value |> String.split(",", trim: true) |> Enum.map(&String.trim/1)
      end

    if configured == [] do
      @roles
    else
      Enum.filter(@roles, &(&1.id in configured))
      |> then(fn roles -> if roles == [], do: @roles, else: roles end)
    end
  end

  defp int_env(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_integer(value)
    end
  rescue
    _error -> default
  end

  defp float_env(name, default) do
    case System.get_env(name) do
      nil -> default
      "" -> default
      value -> String.to_float(value)
    end
  rescue
    _error -> default
  end

  defp run_staged_review(bundle, config) do
    candidate_stage = collect_candidates(bundle, config)

    candidates =
      candidate_stage.candidates
      |> dedupe_candidates()
      |> Enum.sort_by(&candidate_rank/1, :desc)
      |> Enum.take(config.max_validations)

    validation_stage =
      Enum.map(candidates, fn candidate ->
        evidence = evidence_for_candidate(bundle, candidate)
        validation = validate_candidate(bundle, candidate, evidence, config)
        %{candidate: candidate, evidence: evidence, validation: validation}
      end)

    proof_stage =
      validation_stage
      |> Enum.map(&Map.put(&1, :proof, proof_decision(&1, config)))

    post_dedupe_stage = suppress_duplicate_root_causes(proof_stage, config)

    validated =
      post_dedupe_stage
      |> Enum.filter(&publishable_proof?/1)
      |> Enum.sort_by(&proof_publish_score/1, :desc)
      |> Enum.take(config.max_claims)

    %{
      candidates: candidate_stage.candidates,
      candidate_calls: candidate_stage.calls,
      validation_stage: post_dedupe_stage,
      validated: validated,
      errors: candidate_stage.errors ++ validation_errors(post_dedupe_stage)
    }
  end

  defp collect_candidates(bundle, config) do
    config.roles
    |> Enum.reduce(%{candidates: [], calls: [], errors: []}, fn role, acc ->
      response = call_candidate_agent(bundle, role, config)

      candidates =
        response.candidates
        |> List.wrap()
        |> Enum.take(config.max_candidates_per_role)
        |> Enum.map(&Map.put(&1, "source_role", role.id))

      errors =
        if response.error do
          acc.errors ++ [%{reason: response.error, phase: "candidate", role: role.id}]
        else
          acc.errors
        end

      %{
        candidates: acc.candidates ++ candidates,
        calls: acc.calls ++ [model_call_artifact("candidate", role.id, response)],
        errors: errors
      }
    end)
  end

  defp call_candidate_agent(bundle, role, config) do
    if config.fake? do
      fake_candidate_response(bundle, role)
    else
      run_codex(
        candidate_prompt(bundle, role, config),
        candidate_schema(config.max_candidates_per_role),
        Map.put(config, :reasoning_effort, config.candidate_reasoning_effort),
        "candidate-#{role.id}"
      )
      |> normalize_candidate_response()
    end
  end

  defp validate_candidate(bundle, candidate, evidence, config) do
    if config.fake? do
      fake_validation_response(candidate, evidence)
    else
      run_codex(
        validator_prompt(bundle, candidate, evidence, config),
        validator_schema(),
        Map.put(config, :reasoning_effort, config.validator_reasoning_effort),
        "validator"
      )
      |> normalize_validation_response()
    end
  end

  defp fake_candidate_response(bundle, role) do
    paths = changed_files(bundle)
    path = List.first(paths, "unknown")
    duplicate? = System.get_env("SUGARY_STAGED_FAKE_DUPLICATE") in ["1", "true", "TRUE"]
    typed_case = System.get_env("SUGARY_STAGED_FAKE_TYPED_CASE")

    candidates =
      cond do
        typed_case == "upload_limit" and role.id == "diff-bug" ->
          [
            fake_typed_candidate(
              path,
              "Hard-coding 10 MB can reject uploads that the SiteSetting size limit allows.",
              "upload_limit_contract",
              "Fake candidate cites the repo invariant that upload limits are controlled by SiteSetting values."
            )
          ]

        typed_case == "sql_injection" and role.id == "changed-code-security" ->
          [
            fake_typed_candidate(
              path,
              "The migration interpolates existing settings directly into SQL, so quoted values break upgrades.",
              "security_injection",
              "Fake candidate cites raw SQL interpolation from legacy settings."
            )
          ]

        typed_case == "topic_user_nil" and role.id == "contract-regression" ->
          [
            fake_typed_candidate(
              path,
              "The unsubscribe action can crash when TopicUser.find_by returns nil and `tu.notification_level` is dereferenced.",
              "runtime_nil",
              "Fake candidate cites a nil TopicUser possibility without proving a missing row path."
            )
          ]

        typed_case == "api_duplicate" and role.id == "diff-bug" ->
          [
            fake_typed_candidate(
              path,
              "Adding a second `OptimizedImage.downsize` definition replaces the existing API, so callers passing width and height now raise `ArgumentError`.",
              "api_contract",
              "Fake candidate cites the duplicate Ruby method definition and changed API contract."
            )
          ]

        typed_case == "api_duplicate" and role.id == "contract-regression" ->
          [
            fake_typed_candidate(
              Enum.at(paths, 1, path),
              "The PR replaces `OptimizedImage.downsize(from, to, max_width, max_height, opts)` with an incompatible overload, which will fail for existing callers.",
              "api_contract",
              "Fake candidate cites existing callers that still use the old OptimizedImage.downsize contract."
            )
          ]

        typed_case == "theme_color_duplicate" and role.id == "diff-bug" ->
          [
            fake_typed_candidate(
              path,
              "The mobile `.custom-message-length` light-theme color changes from the old 70% primary shade to 30%, a theme color regression that makes the hint inconsistent.",
              "theme_color",
              "Fake candidate cites changed Sass color semantics."
            )
          ]

        typed_case == "theme_color_duplicate" and role.id == "contract-regression" ->
          [
            fake_typed_candidate(
              Enum.at(paths, 1, path),
              "The light-theme color for reply author links changes from a 30% lightened primary color to 70%, another theme color regression from the same Sass migration.",
              "theme_color",
              "Fake candidate cites changed Sass color semantics in another selector."
            )
          ]

        typed_case not in [nil, ""] ->
          []

        duplicate? and role.id == "diff-bug" ->
          [fake_duplicate_candidate(path, "FakeApi.call raises for the new caller")]

        duplicate? and role.id == "contract-regression" ->
          [
            fake_duplicate_candidate(
              Enum.at(paths, 1, path),
              "The changed contract still lets `FakeApi.call` raise at runtime"
            )
          ]

        role.id == "diff-bug" ->
          [
            %{
              "claim" => "Fake staged candidate needs validation",
              "category" => "bug",
              "severity" => "medium",
              "confidence" => 0.78,
              "path" => path,
              "start_line" => 1,
              "end_line" => 20,
              "introduced_by_pr" => true,
              "evidence_summary" => "Fake candidate emitted for staged wrapper testing.",
              "reason_flagged" => "Fake candidate.",
              "failure_path" => ["fake candidate"],
              "suggested_fix" => "Fix the fake issue.",
              "suggested_test" => "Add a fake regression test."
            }
          ]

        true ->
          []
      end

    %{
      candidates: candidates,
      summary: "fake candidate response",
      error: nil,
      status: 0,
      duration_ms: 0,
      raw_stdout: "",
      raw_stderr: "",
      output_text: ""
    }
  end

  defp fake_duplicate_candidate(path, claim) do
    %{
      "claim" => claim,
      "category" => "bug",
      "severity" => "medium",
      "confidence" => 0.86,
      "path" => path,
      "start_line" => 1,
      "end_line" => 20,
      "introduced_by_pr" => true,
      "evidence_summary" => "Fake candidate says `FakeApi.call` is the root cause.",
      "reason_flagged" => "Duplicate fake root cause.",
      "failure_path" => [
        "New code calls `FakeApi.call`",
        "`FakeApi.call` raises at runtime for the changed input"
      ],
      "suggested_fix" => "Guard or normalize the changed input before calling `FakeApi.call`.",
      "suggested_test" => "Add a regression test showing `FakeApi.call` no longer raises."
    }
  end

  defp fake_typed_candidate(path, claim, category, evidence_summary) do
    %{
      "claim" => claim,
      "category" => category,
      "severity" => "medium",
      "confidence" => 0.86,
      "path" => path,
      "start_line" => 1,
      "end_line" => 20,
      "introduced_by_pr" => true,
      "evidence_summary" => evidence_summary,
      "reason_flagged" => "Fake typed proof candidate.",
      "failure_path" => [
        "New changed code creates the typed proof condition.",
        "The repo invariant makes the behavior regress at runtime."
      ],
      "suggested_fix" => "Restore the repo invariant before publishing this behavior.",
      "suggested_test" => "Add a regression test for the typed proof invariant."
    }
  end

  defp fake_validation_response(candidate, evidence) do
    read_ok? =
      Enum.any?(evidence, fn observation ->
        observation.tool == "read_file" and observation.ok == true
      end)

    %{
      verdict: if(read_ok?, do: "validated", else: "uncertain"),
      confidence: if(read_ok?, do: 0.82, else: 0.2),
      evidence_summary: "Fake validator inspected bounded repo evidence from the changed code.",
      counterargument: "",
      failure_path: Map.get(candidate, "failure_path", []),
      suggested_fix: Map.get(candidate, "suggested_fix", ""),
      suggested_test: Map.get(candidate, "suggested_test", ""),
      severity: Map.get(candidate, "severity", "medium"),
      summary: "fake validation response",
      error: nil,
      status: 0,
      duration_ms: 0,
      raw_stdout: "",
      raw_stderr: "",
      output_text: ""
    }
  end

  defp run_codex(prompt, schema, config, phase) do
    tmp = System.tmp_dir!()
    nonce = System.unique_integer([:positive])
    schema_path = Path.join(tmp, "sugary-codex-staged-#{phase}-schema-#{nonce}.json")
    output_path = Path.join(tmp, "sugary-codex-staged-#{phase}-output-#{nonce}.json")
    request_path = Path.join(tmp, "sugary-codex-staged-#{phase}-request-#{nonce}.json")
    File.write!(schema_path, encode(schema))

    args = [
      "exec",
      "-C",
      config.cwd,
      "--sandbox",
      "read-only",
      "-c",
      "approval_policy=\"never\"",
      "--ephemeral",
      "-m",
      config.model,
      "-c",
      "model_reasoning_effort=\"#{config.reasoning_effort}\"",
      "--output-schema",
      schema_path,
      "-o",
      output_path,
      prompt
    ]

    request = %{
      command: config.codex,
      args: args,
      cwd: config.cwd,
      env: %{"NO_COLOR" => "1", "TERM" => "xterm-256color", "CODEX_CI" => "1"},
      input: "",
      timeout_ms: config.inner_timeout_ms,
      stdout_limit: 262_144,
      stderr_limit: 262_144
    }

    started = System.monotonic_time(:millisecond)

    runner_result =
      try do
        File.write!(request_path, encode(request))

        case System.cmd("python3", ["scripts/command_process_runner.py", request_path]) do
          {stdout, 0} ->
            :json.decode(stdout)

          {stdout, status} ->
            %{"stdout" => stdout, "stderr" => "process runner failed", "exit_status" => status}
        end
      rescue
        error ->
          %{"stdout" => "", "stderr" => Exception.message(error), "exit_status" => 1}
      after
        File.rm(schema_path)
        File.rm(request_path)
      end

    duration_ms = System.monotonic_time(:millisecond) - started
    raw_stdout = Map.get(runner_result, "stdout", "")
    raw_stderr = Map.get(runner_result, "stderr", "")
    status = Map.get(runner_result, "exit_status", 1)
    output_text = if File.exists?(output_path), do: File.read!(output_path), else: raw_stdout
    File.rm(output_path)
    parsed = decode_model_json(output_text)

    %{
      parsed: parsed,
      error: model_error(status, parsed, runner_result),
      status: status,
      duration_ms: duration_ms,
      raw_stdout: raw_stdout,
      raw_stderr: raw_stderr,
      output_text: output_text
    }
  end

  defp model_error(status, parsed, runner_result) do
    cond do
      Map.get(runner_result, "timed_out") -> "codex_timeout"
      status != 0 -> "codex_non_zero_exit"
      parsed == :error -> "codex_invalid_json"
      true -> nil
    end
  end

  defp normalize_candidate_response(%{error: error} = response) when is_binary(error) do
    response
    |> Map.put(:candidates, [])
    |> Map.put(:summary, "")
  end

  defp normalize_candidate_response(%{parsed: {:ok, value}} = response) do
    response
    |> Map.put(:candidates, Map.get(value, "candidates", []))
    |> Map.put(:summary, Map.get(value, "summary", ""))
  end

  defp normalize_candidate_response(response) do
    response
    |> Map.put(:candidates, [])
    |> Map.put(:summary, "")
  end

  defp normalize_validation_response(%{error: error} = response) when is_binary(error) do
    response
    |> Map.put(:verdict, "uncertain")
    |> Map.put(:confidence, 0.0)
    |> Map.put(:evidence_summary, "")
    |> Map.put(:counterargument, "")
    |> Map.put(:failure_path, [])
    |> Map.put(:suggested_fix, "")
    |> Map.put(:suggested_test, "")
    |> Map.put(:severity, "medium")
  end

  defp normalize_validation_response(%{parsed: {:ok, value}} = response) do
    response
    |> Map.put(:verdict, Map.get(value, "verdict", "uncertain"))
    |> Map.put(:confidence, clamp_float(Map.get(value, "confidence", 0.0)))
    |> Map.put(:evidence_summary, Map.get(value, "evidence_summary", ""))
    |> Map.put(:counterargument, Map.get(value, "counterargument", ""))
    |> Map.put(:failure_path, Map.get(value, "failure_path", []))
    |> Map.put(:suggested_fix, Map.get(value, "suggested_fix", ""))
    |> Map.put(:suggested_test, Map.get(value, "suggested_test", ""))
    |> Map.put(:severity, normalize_severity(Map.get(value, "severity", "medium")))
    |> Map.put(:summary, Map.get(value, "summary", ""))
  end

  defp normalize_validation_response(response) do
    response
    |> Map.put(:verdict, "uncertain")
    |> Map.put(:confidence, 0.0)
    |> Map.put(:evidence_summary, "")
    |> Map.put(:counterargument, "")
    |> Map.put(:failure_path, [])
    |> Map.put(:suggested_fix, "")
    |> Map.put(:suggested_test, "")
    |> Map.put(:severity, "medium")
  end

  defp candidate_prompt(bundle, role, config) do
    """
    You are #{role.label} inside Sugary's staged code review experiment.

    Return JSON only, following the schema. You are a candidate generator, not the publisher.

    Focus:
    #{role.focus}

    Rules:
    - Review only the sanitized ReviewInputBundle.
    - Do not use fixture oracle data, benchmark names, suite ids, or hidden labels.
    - Do not inspect the local filesystem.
    - Produce at most #{config.max_candidates_per_role} candidate issues.
    - Only suggest issues that appear introduced by this PR.
    - Prefer high-signal correctness/security/regression issues.
    - Do not suggest style, readability, broad maintainability, or weak speculative issues.
    - A later validator will check candidates against bounded repo evidence; include path and line if you can.

    Sanitized ReviewInputBundle JSON:
    #{encode(sanitize_bundle_for_model(bundle))}
    """
  end

  defp validator_prompt(bundle, candidate, evidence, _config) do
    """
    You are an independent validator inside Sugary's staged code review experiment.

    Return JSON only, following the schema. Validate or reject the candidate issue.

    Candidate:
    #{encode(candidate)}

    Bounded repository evidence:
    #{encode(evidence)}

    Sanitized PR context:
    #{encode(sanitize_bundle_for_model(bundle))}

    Validation rules:
    - Mark verdict="validated" only if the candidate is a real defect introduced by this PR with high confidence.
    - Mark verdict="rejected" if the evidence contradicts the candidate, shows it is pre-existing, or shows it is low-impact/style/speculation.
    - Mark verdict="uncertain" if the evidence is insufficient.
    - Do not give credit for issues that are merely plausible. False positives are worse than silence.
    - If validated, explain the concrete failure path and cite the bounded evidence in evidence_summary.
    """
  end

  defp candidate_schema(max_candidates) do
    %{
      type: "object",
      additionalProperties: false,
      required: ["summary", "candidates"],
      properties: %{
        summary: %{type: "string"},
        candidates: %{
          type: "array",
          maxItems: max_candidates,
          items: candidate_item_schema()
        }
      }
    }
  end

  defp candidate_item_schema do
    %{
      type: "object",
      additionalProperties: false,
      required: [
        "claim",
        "category",
        "severity",
        "confidence",
        "path",
        "start_line",
        "end_line",
        "introduced_by_pr",
        "evidence_summary",
        "reason_flagged",
        "failure_path",
        "suggested_fix",
        "suggested_test"
      ],
      properties: %{
        claim: %{type: "string"},
        category: %{type: "string"},
        severity: %{type: "string", enum: ["critical", "high", "medium", "low"]},
        confidence: %{type: "number", minimum: 0, maximum: 1},
        path: %{type: "string"},
        start_line: %{type: ["integer", "null"]},
        end_line: %{type: ["integer", "null"]},
        introduced_by_pr: %{type: "boolean"},
        evidence_summary: %{type: "string"},
        reason_flagged: %{type: "string"},
        failure_path: %{type: "array", items: %{type: "string"}},
        suggested_fix: %{type: "string"},
        suggested_test: %{type: "string"}
      }
    }
  end

  defp validator_schema do
    %{
      type: "object",
      additionalProperties: false,
      required: [
        "summary",
        "verdict",
        "confidence",
        "severity",
        "evidence_summary",
        "counterargument",
        "failure_path",
        "suggested_fix",
        "suggested_test"
      ],
      properties: %{
        summary: %{type: "string"},
        verdict: %{type: "string", enum: ["validated", "rejected", "uncertain"]},
        confidence: %{type: "number", minimum: 0, maximum: 1},
        severity: %{type: "string", enum: ["critical", "high", "medium", "low"]},
        evidence_summary: %{type: "string"},
        counterargument: %{type: "string"},
        failure_path: %{type: "array", items: %{type: "string"}},
        suggested_fix: %{type: "string"},
        suggested_test: %{type: "string"}
      }
    }
  end

  defp evidence_for_candidate(bundle, candidate) do
    observations = [
      %{
        observation_id: "tool-1",
        tool: "changed_files",
        args: %{},
        duration_ms: 0,
        ok: true,
        result: %{changed_files: Enum.take(changed_files(bundle), 80)}
      }
    ]

    path = normalize_path(Map.get(candidate, "path", "unknown"))
    line = positive_int(Map.get(candidate, "start_line"), 1)

    read_observation =
      if path != "unknown" do
        run_tool(
          bundle,
          "read_file",
          %{path: path, start_line: max(line - 30, 1), end_line: line + 90},
          2
        )
      end

    grep_observation =
      case grep_query(candidate) do
        nil -> nil
        query -> run_tool(bundle, "repo_grep", %{query: query}, 3)
      end

    [observations, read_observation, grep_observation]
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
  end

  defp grep_query(candidate) do
    text =
      [
        Map.get(candidate, "claim", ""),
        Map.get(candidate, "evidence_summary", "")
      ]
      |> Enum.join(" ")

    Regex.scan(~r/`([^`]{3,80})`/, text)
    |> Enum.map(fn [_match, value] -> String.trim(value) end)
    |> Enum.reject(&(String.contains?(&1, "\n") or String.length(&1) < 3))
    |> List.first()
  end

  defp run_tool(bundle, tool, args, index) do
    started = System.monotonic_time(:millisecond)

    result =
      case tool do
        "repo_grep" -> repo_grep_tool(bundle, args)
        "read_file" -> read_file_tool(bundle, args)
        other -> %{ok: false, error: "unknown_tool", tool: other}
      end

    %{
      observation_id: "tool-#{index}",
      tool: tool,
      args: redact_tool_args(args),
      duration_ms: System.monotonic_time(:millisecond) - started,
      ok: Map.get(result, :ok, false),
      result: cap_map(result, 18_000)
    }
  end

  defp repo_grep_tool(bundle, args) do
    with {:workspace, head} when is_binary(head) <- {:workspace, workspace_head(bundle)},
         {:query, query} <-
           {:query, valid_grep_query(Map.get(args, "query") || Map.get(args, :query))} do
      request = %{
        command: "rg",
        args: [
          "-n",
          "--no-heading",
          "--color",
          "never",
          "--fixed-strings",
          "--max-count",
          "8",
          "--glob",
          "!.git",
          "--glob",
          "!node_modules/**",
          "--glob",
          "!vendor/**",
          "--",
          query,
          "."
        ],
        cwd: head,
        env: %{"NO_COLOR" => "1"},
        input: "",
        timeout_ms: 5_000,
        stdout_limit: @tool_stdout_limit,
        stderr_limit: @tool_stderr_limit
      }

      runner = run_process(request)
      status = Map.get(runner, "exit_status")
      stdout = Map.get(runner, "stdout", "")
      stderr = Map.get(runner, "stderr", "")

      cond do
        Map.get(runner, "timed_out") ->
          %{ok: false, error: "repo_grep_timeout", query: query}

        status in [0, 1] ->
          matches =
            stdout
            |> String.split("\n", trim: true)
            |> Enum.take(40)
            |> Enum.map(&String.slice(&1, 0, 500))

          %{
            ok: true,
            query: query,
            matches: matches,
            count: length(matches),
            no_matches: status == 1,
            stdout_truncated: Map.get(runner, "stdout_truncated", false)
          }

        true ->
          %{
            ok: false,
            error: "repo_grep_failed",
            status: status,
            stderr: String.slice(stderr, 0, 1000)
          }
      end
    else
      {:workspace, _} -> %{ok: false, error: "workspace_unavailable"}
      {:query, _} -> %{ok: false, error: "invalid_grep_query"}
    end
  end

  defp read_file_tool(bundle, args) do
    with {:workspace, head} when is_binary(head) <- {:workspace, workspace_head(bundle)},
         {:path, {:ok, path}} <-
           {:path, safe_relative_path(Map.get(args, "path") || Map.get(args, :path))} do
      start_line = positive_int(Map.get(args, "start_line") || Map.get(args, :start_line), 1)

      requested_end =
        positive_int(Map.get(args, "end_line") || Map.get(args, :end_line), start_line + 80)

      end_line = min(max(requested_end, start_line), start_line + 119)
      full_path = Path.expand(path, head)
      root = Path.expand(head)

      cond do
        not String.starts_with?(full_path, root <> "/") and full_path != root ->
          %{ok: false, error: "path_outside_workspace", path: path}

        not File.regular?(full_path) ->
          %{ok: false, error: "file_not_found", path: path}

        true ->
          lines =
            full_path
            |> File.stream!()
            |> Stream.with_index(1)
            |> Stream.filter(fn {_line, number} ->
              number >= start_line and number <= end_line
            end)
            |> Enum.map(fn {line, number} -> "#{number}: #{String.trim_trailing(line)}" end)

          %{
            ok: true,
            path: path,
            start_line: start_line,
            end_line: end_line,
            content: lines |> Enum.join("\n") |> String.slice(0, 16_000),
            truncated: requested_end > end_line
          }
      end
    else
      {:workspace, _} -> %{ok: false, error: "workspace_unavailable"}
      {:path, {:error, reason}} -> %{ok: false, error: reason}
    end
  end

  defp run_process(request) do
    request_path =
      Path.join(
        System.tmp_dir!(),
        "sugary-staged-review-tool-request-#{System.unique_integer([:positive])}.json"
      )

    try do
      File.write!(request_path, encode(request))

      case System.cmd("python3", ["scripts/command_process_runner.py", request_path]) do
        {stdout, 0} ->
          :json.decode(stdout)

        {stdout, status} ->
          %{"stdout" => stdout, "stderr" => "tool runner failed", "exit_status" => status}
      end
    rescue
      error ->
        %{"stdout" => "", "stderr" => Exception.message(error), "exit_status" => 1}
    after
      File.rm(request_path)
    end
  end

  defp dedupe_candidates(candidates) do
    candidates
    |> Enum.reduce(%{}, fn candidate, acc ->
      key = candidate_key(candidate)
      existing = Map.get(acc, key)

      if existing == nil or candidate_rank(candidate) > candidate_rank(existing) do
        Map.put(acc, key, candidate)
      else
        acc
      end
    end)
    |> Map.values()
  end

  defp candidate_key(candidate) do
    [
      Map.get(candidate, "category", "bug"),
      normalize_path(Map.get(candidate, "path", "unknown")),
      Map.get(candidate, "claim", "") |> canonical_text() |> String.slice(0, 120)
    ]
    |> Enum.join(":")
  end

  defp candidate_rank(candidate) do
    severity_weight(Map.get(candidate, "severity", "medium")) *
      clamp_float(Map.get(candidate, "confidence", 0.0))
  end

  defp validation_rank(validation, candidate) do
    severity_weight(validation.severity || Map.get(candidate, "severity", "medium")) *
      clamp_float(validation.confidence)
  end

  defp validation_errors(validation_stage) do
    validation_stage
    |> Enum.flat_map(fn row ->
      if row.validation.error do
        [
          %{
            reason: row.validation.error,
            phase: "validator",
            claim: Map.get(row.candidate, "claim", "")
          }
        ]
      else
        []
      end
    end)
  end

  defp validated_row_text(row) do
    [
      Map.get(row.candidate, "claim", ""),
      Map.get(row.candidate, "evidence_summary", ""),
      row.validation.evidence_summary,
      row.validation.failure_path
    ]
    |> List.flatten()
    |> Enum.join(" ")
  end

  defp token_set(text) do
    stop =
      MapSet.new(~w(
        this that with from into will when where then than because before after
        issue issues code file line lines candidate validation evidence
        introduced existing changed change
      ))

    text
    |> canonical_text()
    |> String.split()
    |> Enum.reject(&(String.length(&1) < 4 or MapSet.member?(stop, &1)))
    |> MapSet.new()
  end

  defp proof_decision(row, %{proof_gate?: false} = config) do
    %{
      decision: if(row.validation.verdict == "validated", do: "publish", else: "suppress"),
      publish_score: validation_rank(row.validation, row.candidate),
      reasons:
        if(row.validation.verdict == "validated",
          do: [],
          else: ["validator_#{row.validation.verdict}"]
        ),
      features: proof_features(row, config)
    }
  end

  defp proof_decision(row, config) do
    features = proof_features(row, config)
    score = proof_score(row, features)
    reasons = proof_suppression_reasons(row, features, score, config)

    %{
      decision: if(reasons == [], do: "publish", else: "suppress"),
      publish_score: score,
      reasons: reasons,
      features: features
    }
  end

  defp proof_features(row, config) do
    text = validated_row_text(row)
    evidence_text = row.validation.evidence_summary |> to_string()
    proof_type = proof_type(row, text)
    invariant_matches = invariant_matches(config.invariant_ledger.invariants, text, proof_type)

    repo_observations = Enum.filter(row.evidence, &(&1.tool in ["read_file", "repo_grep"]))
    useful_observations = Enum.filter(repo_observations, &useful_observation?/1)

    failure_path =
      List.wrap(row.validation.failure_path || Map.get(row.candidate, "failure_path", []))

    base = %{
      validator_validated: row.validation.verdict == "validated",
      validation_confidence: clamp_float(row.validation.confidence),
      introduced_by_pr: Map.get(row.candidate, "introduced_by_pr", true) == true,
      has_repo_evidence: useful_observations != [],
      repo_observation_count: length(useful_observations),
      has_read_file: Enum.any?(useful_observations, &(&1.tool == "read_file")),
      has_repo_grep: Enum.any?(useful_observations, &(&1.tool == "repo_grep")),
      has_failure_path: length(failure_path) >= 2,
      has_suggested_fix:
        String.length(String.trim(to_string(row.validation.suggested_fix))) >= 12,
      has_suggested_test:
        String.length(String.trim(to_string(row.validation.suggested_test))) >= 12,
      evidence_mentions_changed_code: evidence_mentions_changed_code?(evidence_text),
      expected_failure_language: expected_failure_language?(text),
      speculative_language: speculative_language?(text),
      counterargument_strength: counterargument_strength(row.validation.counterargument),
      root_cause_key: root_cause_key(row),
      claim_tokens: token_set(text) |> MapSet.size(),
      proof_type: proof_type,
      typed_proof_gates: config.typed_proof_gates?,
      invariant_ledger_id: config.invariant_ledger.id,
      matched_invariants: Enum.map(invariant_matches.support, &Map.get(&1, "id", "unknown")),
      suppressing_invariants: Enum.map(invariant_matches.suppress, &Map.get(&1, "id", "unknown"))
    }

    Map.merge(base, typed_proof_features(row, text, proof_type, invariant_matches, base, config))
  end

  defp useful_observation?(%{ok: false}), do: false

  defp useful_observation?(%{tool: "read_file", result: result}) do
    result |> Map.get(:content, "") |> to_string() |> String.length() > 40
  end

  defp useful_observation?(%{tool: "repo_grep", result: result}) do
    (Map.get(result, :count) || 0) > 0
  end

  defp useful_observation?(_observation), do: false

  defp proof_suppression_reasons(_row, features, score, config) do
    reasons =
      []
      |> maybe_reason(not features.validator_validated, "validator_not_validated")
      |> maybe_reason(
        features.validation_confidence < config.min_validation_confidence,
        "low_validation_confidence"
      )
      |> maybe_reason(score < config.min_proof_score, "low_proof_score")
      |> maybe_reason(not features.introduced_by_pr, "not_introduced_by_pr")
      |> maybe_reason(not features.has_repo_evidence, "missing_repo_evidence")
      |> maybe_reason(not features.has_failure_path, "missing_failure_path")
      |> maybe_reason(
        not features.evidence_mentions_changed_code,
        "missing_introducedness_evidence"
      )
      |> maybe_reason(not features.expected_failure_language, "missing_expected_failure")
      |> maybe_reason(
        features.speculative_language and not features.typed_speculation_allowed,
        "speculative_language"
      )
      |> maybe_reason(features.counterargument_strength == "strong", "strong_counterargument")

    (reasons ++ features.typed_suppression_reasons)
    |> Enum.uniq()
  end

  defp maybe_reason(reasons, true, reason), do: [reason | reasons]
  defp maybe_reason(reasons, false, _reason), do: reasons

  defp proof_score(row, features) do
    severity =
      severity_weight(row.validation.severity || Map.get(row.candidate, "severity", "medium")) / 4

    base =
      0.36 * features.validation_confidence +
        0.16 * severity +
        0.12 * bool_score(features.has_repo_evidence) +
        0.10 * bool_score(features.has_failure_path) +
        0.10 * bool_score(features.evidence_mentions_changed_code) +
        0.08 * bool_score(features.expected_failure_language) +
        0.04 * bool_score(features.has_suggested_fix) +
        0.04 * bool_score(features.has_suggested_test) +
        0.06 * bool_score(features.typed_requirements_met) +
        0.05 * bool_score(features.matched_invariants != [])

    penalty =
      0.18 * bool_score(features.speculative_language and not features.typed_speculation_allowed) +
        0.14 * bool_score(features.typed_suppression_reasons != []) +
        0.12 * bool_score(features.suppressing_invariants != []) +
        case features.counterargument_strength do
          "strong" -> 0.2
          "medium" -> 0.08
          _ -> 0.0
        end

    max(base - penalty, 0.0)
  end

  defp typed_proof_features(_row, _text, _proof_type, _matches, _base, %{
         typed_proof_gates?: false
       }) do
    %{
      typed_requirements_met: false,
      typed_speculation_allowed: false,
      typed_suppression_reasons: [],
      typed_score_bonus: 0.0
    }
  end

  defp typed_proof_features(_row, text, proof_type, matches, base, _config) do
    text = String.downcase(to_string(text))

    typed_reasons =
      []
      |> maybe_reason(
        proof_type == "api_contract" and not api_contract_proof?(text, base),
        "missing_api_contract_proof"
      )
      |> maybe_reason(
        proof_type == "upload_limit_contract" and not upload_limit_contract_proof?(text, matches),
        "missing_upload_limit_contract_proof"
      )
      |> maybe_reason(
        proof_type == "security_injection" and not controllable_input_proof?(text),
        "missing_controllable_input_proof"
      )
      |> maybe_reason(
        proof_type == "resource_exhaustion" and not resource_bound_proof?(text),
        "missing_resource_bound_proof"
      )
      |> maybe_reason(
        proof_type == "state_precondition" and not state_precondition_proof?(text),
        "missing_state_precondition_proof"
      )

    invariant_reasons =
      matches.suppress
      |> Enum.map(&(Map.get(&1, "reason") || "repo_invariant_refuted"))

    support? = matches.support != []

    speculation_allowed? =
      support? and proof_type in ["api_contract", "upload_limit_contract", "state_precondition"]

    all_reasons = Enum.uniq(typed_reasons ++ invariant_reasons)

    %{
      typed_requirements_met: all_reasons == [] and proof_type != "generic",
      typed_speculation_allowed: speculation_allowed?,
      typed_suppression_reasons: all_reasons,
      typed_score_bonus: if(support?, do: 0.05, else: 0.0)
    }
  end

  defp api_contract_proof?(text, base) do
    base.root_cause_key not in [nil, ""] and
      (String.contains?(text, "argument") or
         String.contains?(text, "arity") or
         String.contains?(text, "signature") or
         String.contains?(text, "contract") or
         String.contains?(text, "caller"))
  end

  defp upload_limit_contract_proof?(text, matches) do
    matches.support != [] or
      ((String.contains?(text, "site setting") or String.contains?(text, "sitesetting")) and
         (String.contains?(text, "10 mb") or String.contains?(text, "10mb") or
            String.contains?(text, "hard-code") or String.contains?(text, "hardcode")))
  end

  defp controllable_input_proof?(text) do
    Enum.any?(
      [
        "attacker",
        "user-controlled",
        "user controlled",
        "untrusted",
        "request param",
        "params[",
        "api input",
        "external input",
        "remote input"
      ],
      &String.contains?(text, &1)
    )
  end

  defp state_precondition_proof?(text) do
    Enum.any?(
      ["signed out", "logged out", "unauthenticated", "without requiring", "without checking"],
      &String.contains?(text, &1)
    ) or
      (String.contains?(text, "current_user") and
         Enum.any?(
           ["nil", "dereference", "raises", "raise", "crash"],
           &String.contains?(text, &1)
         ))
  end

  defp resource_bound_proof?(text) do
    Enum.any?(
      ["unbounded", "no limit", "arbitrary size", "amplification", "infinite", "until success"],
      &String.contains?(text, &1)
    )
  end

  defp proof_type(row, text) do
    text = String.downcase(to_string(text))
    category = Map.get(row.candidate, "category", "") |> to_string() |> String.downcase()
    path = Map.get(row.candidate, "path", "") |> to_string() |> String.downcase()

    cond do
      Enum.any?(
        ["imagemagick", "expensive", "conversion", "resource", "cpu", "memory"],
        &String.contains?(text, &1)
      ) ->
        "resource_exhaustion"

      String.contains?(text, "site setting") or String.contains?(text, "sitesetting") or
        String.contains?(text, "size_kb") or String.contains?(text, "10 mb") ->
        "upload_limit_contract"

      String.contains?(text, "sql injection") or
          (String.contains?(text, "sql") and String.contains?(text, "interpolat")) ->
        "security_injection"

      String.contains?(category, "api") or String.contains?(category, "contract") or
        String.contains?(text, "argumenterror") or String.contains?(text, "arity") or
        String.contains?(text, "signature") or String.contains?(text, "api contract") ->
        "api_contract"

      String.contains?(text, "topicuser") and
          (String.contains?(text, "nil") or String.contains?(text, "find_by")) ->
        "runtime_nil"

      String.contains?(text, "nil") or String.contains?(text, "null") or
        String.contains?(text, "nomethoderror") or String.contains?(text, "dereference") ->
        "runtime_nil"

      String.contains?(text, "current_user") or String.contains?(text, "csrf") or
        String.contains?(category, "auth") or String.contains?(category, "state-changing") ->
        "state_precondition"

      String.contains?(path, "db/migrate") or String.contains?(text, "migration") ->
        "migration_contract"

      true ->
        "generic"
    end
  end

  defp invariant_matches(invariants, text, proof_type) do
    text = String.downcase(to_string(text))

    Enum.reduce(invariants, %{support: [], suppress: []}, fn invariant, acc ->
      type = Map.get(invariant, "proof_type", "any")
      type_matches? = type in ["any", proof_type]

      support? =
        type_matches? and
          invariant_terms_match?(text, Map.get(invariant, "support_terms", []))

      suppress? =
        type_matches? and
          invariant_terms_match?(text, Map.get(invariant, "suppress_terms", [])) and
          missing_required_invariant_terms?(text, Map.get(invariant, "missing_any_terms", []))

      acc
      |> update_invariant_matches(:support, support?, invariant)
      |> update_invariant_matches(:suppress, suppress?, invariant)
    end)
  end

  defp update_invariant_matches(matches, key, true, invariant),
    do: Map.update!(matches, key, &[invariant | &1])

  defp update_invariant_matches(matches, _key, false, _invariant), do: matches

  defp invariant_terms_match?(_text, []), do: false

  defp invariant_terms_match?(text, terms) do
    Enum.all?(terms, &String.contains?(text, String.downcase(to_string(&1))))
  end

  defp missing_required_invariant_terms?(_text, []), do: true

  defp missing_required_invariant_terms?(text, terms) do
    not Enum.any?(terms, &String.contains?(text, String.downcase(to_string(&1))))
  end

  defp load_invariant_ledger(nil), do: empty_invariant_ledger(nil)
  defp load_invariant_ledger(""), do: empty_invariant_ledger("")

  defp load_invariant_ledger(path) do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, json} ->
        case :json.decode(json) do
          %{} = data ->
            %{
              id: Map.get(data, "id", Path.basename(path, ".json")),
              path: path,
              error: nil,
              invariants: normalize_invariants(Map.get(data, "invariants", []))
            }

          _other ->
            %{empty_invariant_ledger(path) | error: "ledger_not_object"}
        end

      {:error, reason} ->
        %{empty_invariant_ledger(path) | error: "ledger_read_failed:#{reason}"}
    end
  rescue
    error ->
      %{empty_invariant_ledger(path) | error: "ledger_parse_failed:#{Exception.message(error)}"}
  end

  defp empty_invariant_ledger(path) do
    %{id: nil, path: path, error: nil, invariants: []}
  end

  defp normalize_invariants(invariants) when is_list(invariants) do
    Enum.filter(invariants, &is_map/1)
  end

  defp normalize_invariants(_other), do: []

  defp bool_score(true), do: 1.0
  defp bool_score(false), do: 0.0

  defp publishable_proof?(row) do
    row.proof.decision == "publish"
  end

  defp proof_publish_score(row), do: row.proof.publish_score

  defp suppress_duplicate_root_causes(rows, config) do
    rows
    |> Enum.sort_by(&proof_publish_score/1, :desc)
    |> Enum.reduce(%{kept: [], seen: MapSet.new()}, fn row, acc ->
      keys = duplicate_root_keys(row, config)
      duplicate? = Enum.any?(keys, &MapSet.member?(acc.seen, &1))

      cond do
        row.proof.decision != "publish" ->
          %{acc | kept: acc.kept ++ [row]}

        keys == [] ->
          %{acc | kept: acc.kept ++ [row]}

        duplicate? ->
          duplicate =
            put_in(row.proof.decision, "suppress")
            |> put_in([:proof, :reasons], ["duplicate_root_cause" | row.proof.reasons])

          %{acc | kept: acc.kept ++ [duplicate]}

        true ->
          %{acc | kept: acc.kept ++ [row], seen: Enum.reduce(keys, acc.seen, &MapSet.put(&2, &1))}
      end
    end)
    |> Map.fetch!(:kept)
  end

  defp duplicate_root_keys(row, config) do
    base =
      row.proof.features.root_cause_key
      |> List.wrap()
      |> Enum.reject(&(&1 in [nil, ""]))

    if config.dedupe_version >= 5 do
      (base ++ semantic_duplicate_root_keys(row))
      |> Enum.uniq()
    else
      base
    end
  end

  defp semantic_duplicate_root_keys(row) do
    text = validated_row_text(row)
    proof_type = row.proof.features.proof_type

    []
    |> maybe_semantic_key(
      proof_type == "api_contract",
      api_contract_duplicate_key(text)
    )
    |> maybe_semantic_key(
      theme_color_regression?(text),
      "semantic:theme_color_regression"
    )
  end

  defp maybe_semantic_key(keys, true, key) when key not in [nil, ""], do: [key | keys]
  defp maybe_semantic_key(keys, _condition, _key), do: keys

  defp api_contract_duplicate_key(text) do
    text
    |> root_cause_anchors()
    |> Enum.find(&code_symbol_anchor?/1)
    |> case do
      nil -> nil
      anchor -> "semantic:api_contract:#{anchor}"
    end
  end

  defp code_symbol_anchor?(anchor) do
    anchor = to_string(anchor)

    String.contains?(anchor, ".") and
      not Regex.match?(
        ~r/\.(rb|erb|scss|css|ts|tsx|js|jsx|ex|exs|py|go|rs|java|kt|swift)$/i,
        anchor
      )
  end

  defp theme_color_regression?(text) do
    text = String.downcase(to_string(text))

    color_terms? =
      Enum.any?(
        ["color", "primary", "lightness", "lightened", "scale-color", "shade"],
        &String.contains?(text, &1)
      )

    theme_terms? =
      Enum.any?(
        ["theme", "light-theme", "dark-theme", "sass", "scss", "selector"],
        &String.contains?(text, &1)
      )

    regression_terms? =
      Enum.any?(
        [
          "regression",
          "changes from",
          "changed from",
          "inconsistent",
          "much lighter",
          "much darker"
        ],
        &String.contains?(text, &1)
      )

    color_terms? and theme_terms? and regression_terms?
  end

  defp root_cause_key(row) do
    path = normalize_path(Map.get(row.candidate, "path", "unknown"))
    text = validated_row_text(row)
    anchors = root_cause_anchors(text)
    tokens = token_set(validated_row_text(row))

    root_tokens =
      tokens
      |> Enum.filter(&root_cause_token?/1)
      |> Enum.sort()
      |> Enum.take(5)

    failure_tokens =
      tokens
      |> Enum.filter(&failure_signature_token?/1)
      |> Enum.map(&canonical_failure_signature_token/1)
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.take(4)

    cond do
      anchors != [] ->
        signature =
          if failure_tokens == [] do
            "general"
          else
            Enum.join(failure_tokens, "-")
          end

        "symbol:#{Enum.take(anchors, 2) |> Enum.join("+")}:#{signature}"

      path != "unknown" and root_tokens != [] ->
        "#{path}:#{Enum.join(root_tokens, "-")}"

      true ->
        nil
    end
  end

  defp root_cause_anchors(text) do
    backtick_anchors =
      Regex.scan(~r/`([^`]+)`/, to_string(text))
      |> Enum.map(fn [_match, value] -> value end)
      |> Enum.flat_map(&identifier_anchors/1)

    inline_anchors =
      Regex.scan(~r/\b[A-Z][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_!?]*)+\b/, to_string(text))
      |> Enum.map(fn [value] -> canonical_symbol(value) end)

    (backtick_anchors ++ inline_anchors)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp identifier_anchors(text) do
    Regex.scan(~r/[A-Za-z_][A-Za-z0-9_!?]*(?:\.[A-Za-z_][A-Za-z0-9_!?]*)+/, text)
    |> Enum.map(fn [value] -> canonical_symbol(value) end)
  end

  defp canonical_symbol(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[?!]/, "")
    |> String.trim(".")
  end

  defp root_cause_token?(token) do
    String.length(token) >= 5 and
      not Regex.match?(~r/^\d+$/, token) and
      token not in ~w(
        validation evidence bounded candidate change changed introduced existing issue
        claim defect method return returns line lines file
      )
  end

  defp failure_signature_token?(token) do
    token in ~w(
      arity argument arguments argumenterror auth authorization bypass crash crashes
      csrf dereference dereferences exception fail fails failure injection invalid leak
      nil null overflow panic raise raises regression runtime unsafe unauthorized
    )
  end

  defp canonical_failure_signature_token(token)
       when token in ["raises", "raised"],
       do: "raise"

  defp canonical_failure_signature_token(token)
       when token in ["crashes", "crashed"],
       do: "crash"

  defp canonical_failure_signature_token(token)
       when token in ["fails", "failed", "failure"],
       do: "fail"

  defp canonical_failure_signature_token(token)
       when token in ["arguments"],
       do: "argument"

  defp canonical_failure_signature_token(token)
       when token in ["dereferences"],
       do: "dereference"

  defp canonical_failure_signature_token(token), do: token

  defp evidence_mentions_changed_code?(text) do
    text = String.downcase(to_string(text))

    Enum.any?(
      [
        "diff",
        "pr adds",
        "pr changes",
        "the pr",
        "new code",
        "now ",
        "replaces",
        "changed",
        "newly"
      ],
      &String.contains?(text, &1)
    )
  end

  defp expected_failure_language?(text) do
    text = String.downcase(to_string(text))

    Enum.any?(
      [
        "crash",
        "raises",
        "raise",
        "throws",
        "fails",
        "reject",
        "break",
        "regress",
        "bypass",
        "leak",
        "incorrect",
        "cannot",
        "no longer",
        "will not",
        "500",
        "exception"
      ],
      &String.contains?(text, &1)
    )
  end

  defp speculative_language?(text) do
    text = String.downcase(to_string(text))

    Enum.any?(
      [
        "can crash",
        "could crash",
        "might",
        "may ",
        "possibly",
        "potentially",
        "plausible",
        "if a user",
        "if an attacker",
        "if the"
      ],
      &String.contains?(text, &1)
    )
  end

  defp counterargument_strength(text) do
    text = String.downcase(to_string(text))

    cond do
      text == "" ->
        "none"

      Enum.any?(
        ["does not refute", "not refute", "still", "however"],
        &String.contains?(text, &1)
      ) ->
        "weak"

      Enum.any?(["would not", "cannot", "depends on", "if"], &String.contains?(text, &1)) ->
        "medium"

      String.length(text) > 180 ->
        "medium"

      true ->
        "weak"
    end
  end

  defp normalize_validated_claims(rows, config) do
    rows
    |> Enum.with_index(1)
    |> Enum.map(fn {row, index} ->
      candidate = row.candidate
      validation = row.validation
      path = normalize_path(Map.get(candidate, "path", "unknown"))
      category = Map.get(candidate, "category", "bug")
      summary = Map.get(candidate, "claim", "Staged reviewer finding")

      %{
        id: "#{config.method_id}-claim-#{index}",
        claim: summary,
        category: category,
        severity:
          validation.severity || normalize_severity(Map.get(candidate, "severity", "medium")),
        confidence: clamp_float(validation.confidence),
        path: path,
        start_line: Map.get(candidate, "start_line"),
        end_line: Map.get(candidate, "end_line") || Map.get(candidate, "start_line"),
        introduced_by_pr: Map.get(candidate, "introduced_by_pr", true),
        evidence: [
          %{
            type: "staged_validation",
            tier: 3,
            strength: "strong",
            summary:
              validation.evidence_summary || Map.get(candidate, "evidence_summary", summary)
          }
        ],
        failure_path: validation.failure_path || Map.get(candidate, "failure_path", []),
        suggested_fix: validation.suggested_fix || Map.get(candidate, "suggested_fix", ""),
        suggested_test: validation.suggested_test || Map.get(candidate, "suggested_test", ""),
        counterarguments: [validation.counterargument] |> Enum.reject(&(&1 in [nil, ""])),
        dedupe_key: "#{category}:#{path}:#{String.slice(summary, 0, 80)}",
        source: %{
          method: config.method_id,
          tool: "codex_staged_review",
          model: config.model,
          proof_gate: config.proof_gate?,
          proof_score: row.proof.publish_score,
          proof_reasons: row.proof.reasons,
          proof_features: row.proof.features,
          candidate_role: Map.get(candidate, "source_role"),
          validator_verdict: validation.verdict,
          validator_confidence: validation.confidence,
          tool_observation_ids: Enum.map(row.evidence, & &1.observation_id)
        },
        publish_decision: "candidate"
      }
    end)
  end

  defp sanitize_bundle_for_model(bundle) do
    metadata =
      bundle
      |> Map.get("metadata", %{})
      |> case do
        %{} = value -> value
        _other -> %{}
      end
      |> Map.drop(["workspace", "repo_tools", "evidence_pack"])
      |> Map.put("workspace_available", workspace_head(bundle) != nil)

    Map.put(bundle, "metadata", metadata)
  end

  defp changed_files(bundle) do
    from_context =
      bundle
      |> get_in(["context", "changed_files"])
      |> List.wrap()
      |> Enum.map(&changed_file_path/1)
      |> Enum.reject(&(&1 in ["", "unknown"]))

    if from_context == [] do
      bundle
      |> Map.get("diff", "")
      |> String.split("\n")
      |> Enum.flat_map(fn line ->
        case Regex.run(~r/^diff --git a\/(.+?) b\/(.+)$/, line) do
          [_match, _base, head] -> [head]
          _other -> []
        end
      end)
      |> Enum.uniq()
    else
      Enum.uniq(from_context)
    end
  end

  defp changed_file_path(%{"path" => path}), do: to_string(path)
  defp changed_file_path(%{path: path}), do: to_string(path)
  defp changed_file_path(path) when is_binary(path), do: path
  defp changed_file_path(_other), do: "unknown"

  defp workspace_head(bundle) do
    path = get_in(bundle, ["metadata", "workspace", "head"])

    if is_binary(path) and File.dir?(path), do: Path.expand(path)
  end

  defp safe_relative_path(nil), do: {:error, "missing_path"}

  defp safe_relative_path(path) do
    path = path |> to_string() |> String.trim() |> String.replace("\\", "/")

    cond do
      path == "" ->
        {:error, "missing_path"}

      String.starts_with?(path, "/") ->
        {:error, "absolute_path_forbidden"}

      path |> String.split("/") |> Enum.any?(&(&1 == "..")) ->
        {:error, "path_traversal_forbidden"}

      true ->
        {:ok, path}
    end
  end

  defp valid_grep_query(query) when is_binary(query) do
    query = query |> String.trim() |> String.slice(0, 120)

    if byte_size(query) >= 2 do
      query
    end
  end

  defp valid_grep_query(_query), do: nil

  defp positive_int(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_int(value, default) do
    value
    |> to_string()
    |> String.to_integer()
    |> case do
      number when number > 0 -> number
      _other -> default
    end
  rescue
    _error -> default
  end

  defp normalize_path(path) do
    path = path |> to_string() |> String.trim()

    cond do
      path == "" or path == "unknown" -> "unknown"
      String.contains?(path, "/") or String.contains?(Path.basename(path), ".") -> path
      true -> "unknown"
    end
  end

  defp normalize_severity(value) when value in ["critical", "high", "medium", "low"], do: value
  defp normalize_severity(_value), do: "medium"

  defp severity_weight("critical"), do: 4
  defp severity_weight("high"), do: 3
  defp severity_weight("medium"), do: 2
  defp severity_weight("low"), do: 1
  defp severity_weight(_severity), do: 2

  defp clamp_float(value) when is_number(value), do: min(max(value * 1.0, 0.0), 1.0)
  defp clamp_float(_value), do: 0.0

  defp canonical_text(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, " ")
    |> String.trim()
  end

  defp redact_tool_args(args) when is_map(args) do
    Map.new(args, fn {key, value} -> {key, value |> to_string() |> String.slice(0, 200)} end)
  end

  defp redact_tool_args(_args), do: %{}

  defp cap_map(value, max_bytes) do
    encoded = encode(value)

    if byte_size(encoded) <= max_bytes do
      value
    else
      %{
        ok: Map.get(value, :ok, false),
        truncated: true,
        preview: String.slice(encoded, 0, max_bytes)
      }
    end
  end

  defp decode_model_json(text) do
    try do
      {:ok, :json.decode(text)}
    rescue
      _error ->
        case Regex.run(~r/\{(?:.|\n)*\}/, text || "") do
          [json] ->
            try do
              {:ok, :json.decode(json)}
            rescue
              _error -> :error
            end

          _ ->
            :error
        end
    end
  end

  defp model_call_artifact(phase, role, response) do
    %{
      phase: phase,
      role: role,
      status: response.status,
      duration_ms: response.duration_ms,
      error: response.error,
      summary: Map.get(response, :summary, ""),
      candidates: length(Map.get(response, :candidates, [])),
      raw_stdout_preview:
        response |> Map.get(:raw_stdout, "") |> to_string() |> String.slice(0, 1500),
      raw_stderr_preview:
        response |> Map.get(:raw_stderr, "") |> to_string() |> String.slice(0, 1500),
      output_preview:
        response |> Map.get(:output_text, "") |> to_string() |> String.slice(0, 2500)
    }
  end

  defp artifact(bundle, state, config) do
    %{
      adapter: "codex_staged_review_reviewer",
      staged_review: true,
      workspace_provided: workspace_head(bundle) != nil,
      model: config.model,
      candidate_reasoning_effort: config.candidate_reasoning_effort,
      validator_reasoning_effort: config.validator_reasoning_effort,
      roles: Enum.map(config.roles, & &1.id),
      candidate_count: length(state.candidates),
      validation_count: length(state.validation_stage),
      validated_count: length(state.validated),
      proof_gate: config.proof_gate?,
      typed_proof_gates: config.typed_proof_gates?,
      dedupe_version: config.dedupe_version,
      invariant_ledger: %{
        id: config.invariant_ledger.id,
        path: config.invariant_ledger.path,
        error: config.invariant_ledger.error,
        invariant_count: length(config.invariant_ledger.invariants)
      },
      proof_summary: proof_summary(state.validation_stage),
      candidate_calls: state.candidate_calls,
      validation_stage: compact_validation_stage(state.validation_stage)
    }
  end

  defp proof_summary(rows) do
    rows
    |> Enum.reduce(
      %{
        validator_validated: 0,
        proof_published: 0,
        suppressions: %{},
        duplicate_root_cause: 0,
        cited_tool_observation_claims: 0,
        proof_type_counts: %{},
        matched_invariants: %{},
        suppressing_invariants: %{},
        validation_latency_ms: 0
      },
      fn row, acc ->
        validator_validated = if row.validation.verdict == "validated", do: 1, else: 0
        proof_published = if row.proof.decision == "publish", do: 1, else: 0

        cited =
          if Enum.any?(row.evidence, &(&1.tool in ["read_file", "repo_grep"] and &1.ok)),
            do: 1,
            else: 0

        suppressions =
          row.proof.reasons
          |> Enum.reduce(acc.suppressions, fn reason, counts ->
            Map.update(counts, reason, 1, &(&1 + 1))
          end)

        proof_type_counts =
          Map.update(acc.proof_type_counts, row.proof.features.proof_type, 1, &(&1 + 1))

        matched_invariants =
          row.proof.features.matched_invariants
          |> Enum.reduce(acc.matched_invariants, fn invariant, counts ->
            Map.update(counts, invariant, 1, &(&1 + 1))
          end)

        suppressing_invariants =
          row.proof.features.suppressing_invariants
          |> Enum.reduce(acc.suppressing_invariants, fn invariant, counts ->
            Map.update(counts, invariant, 1, &(&1 + 1))
          end)

        %{
          acc
          | validator_validated: acc.validator_validated + validator_validated,
            proof_published: acc.proof_published + proof_published,
            suppressions: suppressions,
            duplicate_root_cause:
              acc.duplicate_root_cause +
                if("duplicate_root_cause" in row.proof.reasons, do: 1, else: 0),
            cited_tool_observation_claims: acc.cited_tool_observation_claims + cited,
            proof_type_counts: proof_type_counts,
            matched_invariants: matched_invariants,
            suppressing_invariants: suppressing_invariants,
            validation_latency_ms: acc.validation_latency_ms + (row.validation.duration_ms || 0)
        }
      end
    )
  end

  defp compact_validation_stage(rows) do
    Enum.map(rows, fn row ->
      %{
        claim: Map.get(row.candidate, "claim", "") |> String.slice(0, 500),
        path: Map.get(row.candidate, "path"),
        source_role: Map.get(row.candidate, "source_role"),
        evidence_tools:
          Enum.map(row.evidence, &%{id: &1.observation_id, tool: &1.tool, ok: &1.ok}),
        verdict: row.validation.verdict,
        confidence: row.validation.confidence,
        proof_decision: row.proof.decision,
        proof_score: row.proof.publish_score,
        proof_reasons: row.proof.reasons,
        proof_features: row.proof.features,
        evidence_summary: row.validation.evidence_summary |> to_string() |> String.slice(0, 1000),
        counterargument: row.validation.counterargument |> to_string() |> String.slice(0, 1000),
        error: row.validation.error,
        status: row.validation.status,
        duration_ms: row.validation.duration_ms
      }
    end)
  end

  defp encode(data), do: data |> :json.encode() |> IO.iodata_to_binary()
end

SugaryCodexStagedReviewReviewer.main()

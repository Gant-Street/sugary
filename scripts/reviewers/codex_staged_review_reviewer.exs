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
      min_validation_confidence:
        float_env("SUGARY_STAGED_MIN_VALIDATION_CONFIDENCE", 0.72),
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

    validated =
      validation_stage
      |> Enum.filter(fn row ->
        row.validation.verdict == "validated" and
          row.validation.confidence >= config.min_validation_confidence
      end)
      |> dedupe_validated_rows()
      |> Enum.sort_by(fn row -> validation_rank(row.validation, row.candidate) end, :desc)
      |> Enum.take(config.max_claims)

    %{
      candidates: candidate_stage.candidates,
      candidate_calls: candidate_stage.calls,
      validation_stage: validation_stage,
      validated: validated,
      errors: candidate_stage.errors ++ validation_errors(validation_stage)
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
    path =
      bundle
      |> changed_files()
      |> List.first("unknown")

    candidates =
      if role.id == "diff-bug" do
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
      else
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

  defp fake_validation_response(candidate, evidence) do
    read_ok? =
      Enum.any?(evidence, fn observation ->
        observation.tool == "read_file" and observation.ok == true
      end)

    %{
      verdict: if(read_ok?, do: "validated", else: "uncertain"),
      confidence: if(read_ok?, do: 0.82, else: 0.2),
      evidence_summary: "Fake validator inspected bounded repo evidence.",
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
        run_tool(bundle, "read_file", %{path: path, start_line: max(line - 30, 1), end_line: line + 90}, 2)
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
    text = [
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
         {:query, query} <- {:query, valid_grep_query(Map.get(args, "query") || Map.get(args, :query))} do
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
         {:path, {:ok, path}} <- {:path, safe_relative_path(Map.get(args, "path") || Map.get(args, :path))} do
      start_line = positive_int(Map.get(args, "start_line") || Map.get(args, :start_line), 1)
      requested_end = positive_int(Map.get(args, "end_line") || Map.get(args, :end_line), start_line + 80)
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
            |> Stream.filter(fn {_line, number} -> number >= start_line and number <= end_line end)
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
        {stdout, 0} -> :json.decode(stdout)
        {stdout, status} -> %{"stdout" => stdout, "stderr" => "tool runner failed", "exit_status" => status}
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
        [%{reason: row.validation.error, phase: "validator", claim: Map.get(row.candidate, "claim", "")}]
      else
        []
      end
    end)
  end

  defp dedupe_validated_rows(rows) do
    rows
    |> Enum.reduce([], fn row, acc ->
      case Enum.find_index(acc, &duplicate_validated_row?(row, &1)) do
        nil ->
          [row | acc]

        index ->
          existing = Enum.at(acc, index)

          if validation_rank(row.validation, row.candidate) >
               validation_rank(existing.validation, existing.candidate) do
            List.replace_at(acc, index, row)
          else
            acc
          end
      end
    end)
    |> Enum.reverse()
  end

  defp duplicate_validated_row?(left, right) do
    left_path = normalize_path(Map.get(left.candidate, "path", "unknown"))
    right_path = normalize_path(Map.get(right.candidate, "path", "unknown"))

    left_path != "unknown" and left_path == right_path and
      token_jaccard(validated_row_text(left), validated_row_text(right)) >= 0.35
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

  defp token_jaccard(left, right) do
    left = token_set(left)
    right = token_set(right)

    if MapSet.size(left) == 0 or MapSet.size(right) == 0 do
      0.0
    else
      intersection = left |> MapSet.intersection(right) |> MapSet.size()
      union = left |> MapSet.union(right) |> MapSet.size()
      intersection / union
    end
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
        severity: validation.severity || normalize_severity(Map.get(candidate, "severity", "medium")),
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
            summary: validation.evidence_summary || Map.get(candidate, "evidence_summary", summary)
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
      path == "" -> {:error, "missing_path"}
      String.starts_with?(path, "/") -> {:error, "absolute_path_forbidden"}
      path |> String.split("/") |> Enum.any?(&(&1 == "..")) -> {:error, "path_traversal_forbidden"}
      true -> {:ok, path}
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
      %{ok: Map.get(value, :ok, false), truncated: true, preview: String.slice(encoded, 0, max_bytes)}
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
      raw_stdout_preview: response |> Map.get(:raw_stdout, "") |> to_string() |> String.slice(0, 1500),
      raw_stderr_preview: response |> Map.get(:raw_stderr, "") |> to_string() |> String.slice(0, 1500),
      output_preview: response |> Map.get(:output_text, "") |> to_string() |> String.slice(0, 2500)
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
      candidate_calls: state.candidate_calls,
      validation_stage: compact_validation_stage(state.validation_stage)
    }
  end

  defp compact_validation_stage(rows) do
    Enum.map(rows, fn row ->
      %{
        claim: Map.get(row.candidate, "claim", "") |> String.slice(0, 500),
        path: Map.get(row.candidate, "path"),
        source_role: Map.get(row.candidate, "source_role"),
        evidence_tools: Enum.map(row.evidence, &%{id: &1.observation_id, tool: &1.tool, ok: &1.ok}),
        verdict: row.validation.verdict,
        confidence: row.validation.confidence,
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

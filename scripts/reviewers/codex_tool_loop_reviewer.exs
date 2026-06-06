defmodule SugaryCodexToolLoopReviewer do
  @default_max_claims 3
  @default_max_turns 4
  @default_max_tool_calls 3
  @default_timeout_ms 120_000
  @tool_stdout_limit 32_768
  @tool_stderr_limit 8_192

  def main do
    input = IO.read(:stdio, :eof)
    bundle = :json.decode(input)

    if Map.has_key?(bundle, "oracle") or String.contains?(input, "expectedClaims") do
      raise "oracle leaked to Codex tool-loop reviewer"
    end

    config = config()
    started = System.monotonic_time(:millisecond)
    state = run_loop(bundle, input, config)
    duration_ms = System.monotonic_time(:millisecond) - started

    result = %{
      reviewer_id: config.method_id,
      method_id: config.method_id,
      class: "research",
      claims: normalize_claims(state.final_claims, config),
      cost: 0.0,
      latency_ms: duration_ms,
      artifacts: [artifact(bundle, state, config)],
      errors: state.errors
    }

    IO.write(encode(result))
  end

  defp config do
    %{
      method_id: System.get_env("SUGARY_REVIEWER_ID") || "codex-tool-loop-reviewer",
      model: System.get_env("SUGARY_CODEX_MODEL") || "gpt-5.5",
      reasoning_effort: System.get_env("SUGARY_CODEX_REASONING_EFFORT") || "low",
      max_claims: int_env("SUGARY_CODEX_MAX_CLAIMS", @default_max_claims),
      max_turns: int_env("SUGARY_TOOL_LOOP_MAX_TURNS", @default_max_turns),
      max_tool_calls: int_env("SUGARY_TOOL_LOOP_MAX_TOOL_CALLS", @default_max_tool_calls),
      require_tool_before_claims?:
        System.get_env("SUGARY_TOOL_LOOP_REQUIRE_TOOL_BEFORE_CLAIMS") in ["1", "true", "TRUE"],
      inner_timeout_ms: int_env("SUGARY_CODEX_INNER_TIMEOUT_MS", @default_timeout_ms),
      codex: System.get_env("SUGARY_CODEX_BIN") || "codex",
      cwd: System.get_env("SUGARY_CODEX_CWD") || ".",
      fake?: System.get_env("SUGARY_TOOL_LOOP_FAKE_CODEX") in ["1", "true", "TRUE"]
    }
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

  defp run_loop(bundle, raw_input, config) do
    initial = %{
      transcript: [],
      model_calls: [],
      errors: [],
      final_claims: [],
      final_summary: "",
      stopped_reason: nil
    }

    state =
      1..config.max_turns
      |> Enum.reduce_while(initial, fn turn, state ->
        final_only? = tool_call_count(state.transcript) >= config.max_tool_calls or turn == config.max_turns
        response = call_model(bundle, raw_input, state.transcript, config, final_only?)
        state = %{state | model_calls: state.model_calls ++ [model_call_artifact(turn, response)]}

        cond do
          response.error ->
            {:halt,
             %{
               state
               | errors: state.errors ++ [%{reason: response.error, turn: turn}],
                 stopped_reason: response.error
             }}

          response.action == "tool_call" and final_only? ->
            {:halt, force_final(bundle, raw_input, state, config, "tool_budget_exhausted")}

          response.action == "tool_call" ->
            observation = run_tool(bundle, response.tool, response.args || %{}, tool_call_count(state.transcript) + 1)
            {:cont, %{state | transcript: state.transcript ++ [observation]}}

          premature_final_with_claims?(response, state, config) ->
            policy_observation = %{
              observation_id: "policy-#{turn}",
              tool: "policy",
              args: %{},
              duration_ms: 0,
              ok: false,
              result: %{
                error: "final_rejected_tool_evidence_required",
                message:
                  "Non-empty final claims require at least one repo tool observation. Request changed_files, repo_grep, or read_file before finalizing."
              }
            }

            {:cont, %{state | transcript: state.transcript ++ [policy_observation]}}

          response.action == "final" ->
            {:halt,
             %{
               state
               | final_claims: response.claims || [],
                 final_summary: response.summary || "",
                 stopped_reason: "final"
             }}

          true ->
            {:halt,
             %{
               state
               | errors: state.errors ++ [%{reason: "invalid_tool_loop_action", turn: turn}],
                 stopped_reason: "invalid_tool_loop_action"
             }}
        end
      end)

    if state.final_claims == [] and state.errors == [] and state.stopped_reason != "final" do
      force_final(bundle, raw_input, state, config, "no_final_response")
    else
      state
    end
  end

  defp force_final(bundle, raw_input, state, config, reason) do
    response = call_model(bundle, raw_input, state.transcript, config, true)
    state = %{state | model_calls: state.model_calls ++ [model_call_artifact(:final, response)]}

    if response.action == "final" and not response.error do
      %{
        state
        | final_claims: response.claims || [],
          final_summary: response.summary || "",
          stopped_reason: reason
      }
    else
      %{
        state
        | errors: state.errors ++ [%{reason: response.error || "forced_final_failed"}],
          stopped_reason: reason
      }
    end
  end

  defp premature_final_with_claims?(response, state, config) do
    config.require_tool_before_claims? and response.action == "final" and
      tool_call_count(state.transcript) == 0 and List.wrap(response.claims) != []
  end

  defp tool_call_count(transcript) do
    Enum.count(transcript, fn entry -> entry.tool in ["changed_files", "repo_grep", "read_file"] end)
  end

  defp call_model(bundle, raw_input, transcript, config, final_only?) do
    if config.fake? do
      fake_model_response(bundle, transcript, final_only?)
    else
      run_codex(bundle, raw_input, transcript, config, final_only?)
    end
  end

  defp fake_model_response(_bundle, [], false) do
    %{action: "tool_call", tool: "changed_files", args: %{}, claims: [], summary: "", error: nil}
    |> Map.put(:raw_action, "fake_changed_files")
    |> Map.put(:duration_ms, 0)
    |> Map.put(:status, 0)
  end

  defp fake_model_response(_bundle, [first], false) do
    path =
      first
      |> get_in([:result, :changed_files])
      |> List.wrap()
      |> List.first("unknown")
      |> changed_file_path()

    %{
      action: "tool_call",
      tool: "read_file",
      args: %{path: path, start_line: 1, end_line: 20},
      claims: [],
      summary: "",
      error: nil,
      raw_action: "fake_read_file",
      duration_ms: 0,
      status: 0
    }
  end

  defp fake_model_response(_bundle, transcript, _final_only?) do
    %{
      action: "final",
      tool: "none",
      args: %{},
      claims: fake_claims(),
      summary: "Fake tool-loop review completed with #{length(transcript)} tool observations.",
      error: nil,
      raw_action: "fake_final",
      duration_ms: 0,
      status: 0
    }
  end

  defp fake_claims do
    if System.get_env("SUGARY_TOOL_LOOP_FAKE_CLAIM") in ["1", "true", "TRUE"] do
      [
        %{
          "claim" => "Fake tool-loop claim",
          "category" => "bug",
          "severity" => "medium",
          "confidence" => 0.7,
          "path" => "src/reviewer.ts",
          "start_line" => 1,
          "end_line" => 1,
          "introduced_by_pr" => true,
          "evidence_summary" => "Fake claim emitted for wrapper testing.",
          "failure_path" => ["fake"],
          "suggested_fix" => "Fix the fake issue.",
          "suggested_test" => "Add a fake regression test.",
          "tool_observation_ids" => []
        }
      ]
    else
      []
    end
  end

  defp run_codex(bundle, raw_input, transcript, config, final_only?) do
    tmp = System.tmp_dir!()
    nonce = System.unique_integer([:positive])
    schema_path = Path.join(tmp, "sugary-codex-tool-loop-schema-#{nonce}.json")
    output_path = Path.join(tmp, "sugary-codex-tool-loop-output-#{nonce}.json")
    request_path = Path.join(tmp, "sugary-codex-tool-loop-request-#{nonce}.json")
    File.write!(schema_path, encode(turn_schema(config.max_claims)))

    prompt = prompt(bundle, raw_input, transcript, config, final_only?)

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

    case {status, parsed} do
      {0, {:ok, value}} ->
        normalize_model_response(value, %{
          status: status,
          duration_ms: duration_ms,
          raw_stdout: raw_stdout,
          raw_stderr: raw_stderr,
          output_text: output_text
        })

      _other ->
        %{
          action: nil,
          tool: nil,
          args: %{},
          claims: [],
          summary: "",
          error: error_reason(status, parsed, runner_result),
          status: status,
          duration_ms: duration_ms,
          raw_stdout: raw_stdout,
          raw_stderr: raw_stderr,
          output_text: output_text
        }
    end
  end

  defp prompt(bundle, _raw_input, transcript, config, final_only?) do
    sanitized = sanitize_bundle_for_model(bundle)
    tool_policy = if final_only?, do: "Tool calls are disabled now. Return action=\"final\".", else: "You may request exactly one tool call this turn if it will materially confirm or refute a defect."

    required_tool_policy =
      if config.require_tool_before_claims? do
        """
        Required evidence policy:
        - Before returning any non-empty final claims, you must request at least one repository tool and use its observation as evidence.
        - If no repository tool would materially support a claim, return final with zero claims.
        - On the first turn, prefer changed_files or a narrow read_file/repo_grep request for the most relevant changed file or symbol.
        """
      else
        ""
      end

    """
    You are a code review agent inside the Sugary autoresearch harness.

    Return JSON only, following the provided schema.

    This is a bounded tool loop. You do not receive target repository paths. Do not inspect the local filesystem directly. If repository context is needed, request one of the tools below and wait for the next turn.

    Tools:
    - changed_files: returns changed file paths from the sanitized PR input.
    - repo_grep: args { "query": "literal text" }. Runs bounded literal search in the PR head workspace.
    - read_file: args { "path": "relative/file/path", "start_line": 1, "end_line": 80 }. Reads a bounded line range from the PR head workspace.

    Tool budget:
    - At most #{config.max_tool_calls} tool calls total.
    - Ask for narrow evidence. Prefer changed_files, then targeted grep or file reads.
    - Do not call tools for style, nits, or speculative concerns.

    Review policy:
    - Publish only defects that appear introduced by this PR.
    - Prefer concrete bug, security, contract, runtime, or test-gap findings.
    - Avoid style comments and benchmark-shaped guesses.
    - If evidence is weak after tool use, return no claims.
    - Every final claim should cite diff evidence or a tool observation in evidence_summary.
    - Return at most #{config.max_claims} claims.

    #{tool_policy}
    #{required_tool_policy}

    Prior tool observations:
    #{encode(transcript)}

    Sanitized ReviewInputBundle JSON:
    #{encode(sanitized)}
    """
  end

  defp turn_schema(max_claims) do
    claim_schema = %{
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
        "failure_path",
        "suggested_fix",
        "suggested_test",
        "tool_observation_ids"
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
        failure_path: %{type: "array", items: %{type: "string"}},
        suggested_fix: %{type: "string"},
        suggested_test: %{type: "string"},
        tool_observation_ids: %{type: "array", items: %{type: "string"}}
      }
    }

    %{
      type: "object",
      additionalProperties: false,
      required: ["action", "tool", "args", "rationale", "summary", "claims"],
      properties: %{
        action: %{type: "string", enum: ["tool_call", "final"]},
        tool: %{type: "string", enum: ["none", "changed_files", "repo_grep", "read_file"]},
        args: %{
          type: "object",
          additionalProperties: false,
          required: ["query", "path", "start_line", "end_line"],
          properties: %{
            query: %{type: ["string", "null"]},
            path: %{type: ["string", "null"]},
            start_line: %{type: ["integer", "null"]},
            end_line: %{type: ["integer", "null"]}
          }
        },
        rationale: %{type: "string"},
        summary: %{type: "string"},
        claims: %{type: "array", maxItems: max_claims, items: claim_schema}
      }
    }
  end

  defp normalize_model_response(value, metadata) do
    %{
      action: Map.get(value, "action"),
      tool: Map.get(value, "tool"),
      args: Map.get(value, "args", %{}),
      rationale: Map.get(value, "rationale", ""),
      summary: Map.get(value, "summary", ""),
      claims: Map.get(value, "claims", []),
      error: nil,
      status: metadata.status,
      duration_ms: metadata.duration_ms,
      raw_stdout: metadata.raw_stdout,
      raw_stderr: metadata.raw_stderr,
      output_text: metadata.output_text
    }
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

  defp error_reason(status, parsed, runner_result) do
    cond do
      Map.get(runner_result, "timed_out") -> "codex_timeout"
      status != 0 -> "codex_non_zero_exit"
      parsed == :error -> "codex_invalid_json"
      true -> "codex_tool_loop_error"
    end
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

    bundle
    |> Map.put("metadata", metadata)
  end

  defp run_tool(bundle, tool, args, index) do
    started = System.monotonic_time(:millisecond)
    id = "tool-#{index}"

    result =
      case tool do
        "changed_files" -> changed_files_tool(bundle)
        "repo_grep" -> repo_grep_tool(bundle, args)
        "read_file" -> read_file_tool(bundle, args)
        other -> %{ok: false, error: "unknown_tool", tool: other}
      end

    %{
      observation_id: id,
      tool: tool,
      args: redact_tool_args(args),
      duration_ms: System.monotonic_time(:millisecond) - started,
      ok: Map.get(result, :ok, false),
      result: cap_map(result, 18_000)
    }
  end

  defp changed_files_tool(bundle) do
    changed_files = changed_files(bundle)

    %{
      ok: true,
      changed_files: Enum.take(changed_files, 80),
      count: length(changed_files),
      truncated: length(changed_files) > 80
    }
  end

  defp repo_grep_tool(bundle, args) do
    with {:workspace, head} when is_binary(head) <- {:workspace, workspace_head(bundle)},
         {:query, query} <- {:query, valid_grep_query(Map.get(args, "query") || Map.get(args, :query))} do
      query = query |> String.trim() |> String.slice(0, 120)

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

  defp valid_grep_query(query) when is_binary(query) do
    query = String.trim(query)

    if byte_size(query) >= 2 do
      query
    end
  end

  defp valid_grep_query(_query), do: nil

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
        "sugary-tool-loop-tool-request-#{System.unique_integer([:positive])}.json"
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

  defp normalize_claims(claims, config) do
    claims
    |> List.wrap()
    |> Enum.take(config.max_claims)
    |> Enum.with_index(1)
    |> Enum.map(fn {claim, index} ->
      path = normalize_path(Map.get(claim, "path", "unknown"))
      summary = Map.get(claim, "claim", "Codex tool-loop finding")
      category = Map.get(claim, "category", "bug")

      %{
        id: "#{config.method_id}-claim-#{index}",
        claim: summary,
        category: category,
        severity: normalize_severity(Map.get(claim, "severity", "medium")),
        confidence: clamp_float(Map.get(claim, "confidence", 0.5)),
        path: path,
        start_line: Map.get(claim, "start_line"),
        end_line: Map.get(claim, "end_line") || Map.get(claim, "start_line"),
        introduced_by_pr: Map.get(claim, "introduced_by_pr", true),
        evidence: [
          %{
            type: "codex_tool_loop_review",
            tier: 3,
            strength: "medium",
            summary: Map.get(claim, "evidence_summary", summary)
          }
        ],
        failure_path: Map.get(claim, "failure_path", []),
        suggested_fix: Map.get(claim, "suggested_fix", ""),
        suggested_test: Map.get(claim, "suggested_test", ""),
        dedupe_key: "#{category}:#{path}:#{String.slice(summary, 0, 80)}",
        source: %{
          method: config.method_id,
          tool: "codex_tool_loop",
          model: config.model,
          reasoning_effort: config.reasoning_effort,
          tool_observation_ids: Map.get(claim, "tool_observation_ids", [])
        },
        publish_decision: "candidate"
      }
    end)
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

  defp clamp_float(value) when is_number(value), do: min(max(value * 1.0, 0.0), 1.0)
  defp clamp_float(_value), do: 0.5

  defp model_call_artifact(turn, response) do
    %{
      turn: turn,
      action: response.action,
      tool: response.tool,
      rationale: Map.get(response, :rationale, ""),
      status: response.status,
      duration_ms: response.duration_ms,
      error: response.error,
      raw_stdout_preview: response |> Map.get(:raw_stdout, "") |> to_string() |> String.slice(0, 2000),
      raw_stderr_preview: response |> Map.get(:raw_stderr, "") |> to_string() |> String.slice(0, 2000),
      raw_stderr_tail:
        response
        |> Map.get(:raw_stderr, "")
        |> to_string()
        |> then(fn text -> String.slice(text, max(byte_size(text) - 4000, 0), 4000) end),
      output_preview: response |> Map.get(:output_text, "") |> to_string() |> String.slice(0, 4000),
      raw_action: Map.get(response, :raw_action)
    }
  end

  defp artifact(bundle, state, config) do
    %{
      adapter: "codex_tool_loop_reviewer",
      tool_loop: true,
      workspace_provided: workspace_head(bundle) != nil,
      model: config.model,
      reasoning_effort: config.reasoning_effort,
      max_turns: config.max_turns,
      max_tool_calls: config.max_tool_calls,
      require_tool_before_claims: config.require_tool_before_claims?,
      model_calls: length(state.model_calls),
      tool_calls: tool_call_count(state.transcript),
      stopped_reason: state.stopped_reason,
      final_summary: state.final_summary,
      transcript: state.transcript,
      model_call_artifacts: state.model_calls
    }
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

  defp encode(data), do: data |> :json.encode() |> IO.iodata_to_binary()
end

SugaryCodexToolLoopReviewer.main()

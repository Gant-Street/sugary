input = IO.read(:stdio, :eof)
bundle = :json.decode(input)

if Map.has_key?(bundle, "oracle") or String.contains?(input, "expectedClaims") do
  raise "oracle leaked to Codex reviewer"
end

method_id = System.get_env("SUGARY_REVIEWER_ID") || "codex-cli-reviewer"
model = System.get_env("SUGARY_CODEX_MODEL") || "gpt-5.5"
reasoning_effort = System.get_env("SUGARY_CODEX_REASONING_EFFORT") || "low"
max_claims = String.to_integer(System.get_env("SUGARY_CODEX_MAX_CLAIMS") || "3")
inner_timeout_ms = String.to_integer(System.get_env("SUGARY_CODEX_INNER_TIMEOUT_MS") || "120000")
codex = System.get_env("SUGARY_CODEX_BIN") || "codex"
review_focus = System.get_env("SUGARY_CODEX_REVIEW_FOCUS") || ""

bundle_workspace_head = get_in(bundle, ["metadata", "workspace", "head"])
bundle_workspace_base = get_in(bundle, ["metadata", "workspace", "base"])

cwd =
  cond do
    configured = System.get_env("SUGARY_CODEX_CWD") ->
      configured

    is_binary(bundle_workspace_head) and File.dir?(bundle_workspace_head) ->
      bundle_workspace_head

    true ->
      "."
  end

workspace_summary =
  if is_binary(bundle_workspace_head) and File.dir?(bundle_workspace_head) do
    """
    Target repository context:
    - Current working directory is the PR head checkout.
    - Base checkout path, for introducedness checks only: #{bundle_workspace_base || "unavailable"}
    - You may inspect repository files and run read-only search commands.
    - Do not modify files.
    """
  else
    """
    Target repository context:
    - No materialized checkout was provided.
    - Review from the sanitized diff and PR metadata only.
    """
  end

focus_section =
  if String.trim(review_focus) == "" do
    ""
  else
    """
    Specialist focus:
    #{review_focus}
    """
  end

schema = %{
  type: "object",
  additionalProperties: false,
  required: ["claims", "summary"],
  properties: %{
    summary: %{type: "string"},
    claims: %{
      type: "array",
      maxItems: max_claims,
      items: %{
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
          failure_path: %{type: "array", items: %{type: "string"}},
          suggested_fix: %{type: "string"},
          suggested_test: %{type: "string"}
        }
      }
    }
  }
}

tmp = System.tmp_dir!()
nonce = System.unique_integer([:positive])
schema_path = Path.join(tmp, "sugary-codex-reviewer-schema-#{nonce}.json")
output_path = Path.join(tmp, "sugary-codex-reviewer-output-#{nonce}.json")
File.write!(schema_path, :json.encode(schema))

prompt = """
You are an external code review tool inside the Sugary autoresearch harness.

Return JSON only, following the provided schema.

Review the sanitized ReviewInputBundle below and, when available, the materialized target repository checkout. Do not use fixture oracle data. Do not infer a bug solely from case_id, suite, tags, benchmark-looking names, or benchmark metadata.

#{workspace_summary}
#{focus_section}

Publish only defects that appear introduced by this PR. Prefer concrete bug, security, contract, runtime, or test-gap findings. Avoid style comments and speculative edge cases. If evidence is weak, return no claims.

For each claim:
- explain the failure path in evidence_summary or failure_path
- use the most specific path present in context.changed_files or the diff; if no real source path is present, use "unknown"
- keep confidence calibrated
- return at most #{max_claims} claims

ReviewInputBundle JSON:
#{input}
"""

args = [
  "exec",
  "-C",
  cwd,
  "--sandbox",
  "read-only",
  "-c",
  "approval_policy=\"never\"",
  "--ephemeral",
  "-m",
  model,
  "-c",
  "model_reasoning_effort=\"#{reasoning_effort}\"",
  "--output-schema",
  schema_path,
  "-o",
  output_path,
  prompt
]

started = System.monotonic_time(:millisecond)
request_path = Path.join(tmp, "sugary-codex-reviewer-request-#{nonce}.json")

request = %{
  command: codex,
  args: args,
  cwd: cwd,
  env: %{"NO_COLOR" => "1", "TERM" => "xterm-256color", "CODEX_CI" => "1"},
  input: "",
  timeout_ms: inner_timeout_ms,
  stdout_limit: 262_144,
  stderr_limit: 262_144
}

File.write!(request_path, :json.encode(request))

runner_result =
  try do
    case System.cmd("python3", ["scripts/command_process_runner.py", request_path]) do
      {stdout, 0} ->
        :json.decode(stdout)

      {stdout, status} ->
        %{"stdout" => stdout, "stderr" => "process runner failed", "exit_status" => status}
    end
  rescue
    error ->
      %{
        "stdout" => "",
        "stderr" => Exception.message(error),
        "exit_status" => 1,
        "timed_out" => false
      }
  end

duration_ms = System.monotonic_time(:millisecond) - started
raw_stdout = Map.get(runner_result, "stdout", "")
raw_stderr = Map.get(runner_result, "stderr", "")
status = Map.get(runner_result, "exit_status", 1)
output_text = if File.exists?(output_path), do: File.read!(output_path), else: raw_stdout

decode_json = fn text ->
  try do
    {:ok, :json.decode(text)}
  rescue
    _error -> :error
  end
end

parsed =
  case decode_json.(output_text) do
    {:ok, value} ->
      {:ok, value}

    :error ->
      output_text
      |> then(&Regex.run(~r/\{(?:.|\n)*\}/, &1))
      |> case do
        [json] -> decode_json.(json)
        _ -> :error
      end
  end

claims =
  case {status, parsed} do
    {0, {:ok, %{"claims" => claims}}} when is_list(claims) ->
      claims
      |> Enum.take(max_claims)
      |> Enum.with_index(1)
      |> Enum.map(fn {claim, index} ->
        normalize_path = fn path ->
          path = path |> to_string() |> String.trim()

          cond do
            path == "" or path == "unknown" -> "unknown"
            String.contains?(path, "/") or String.contains?(Path.basename(path), ".") -> path
            true -> "unknown"
          end
        end

        path = claim |> Map.get("path", "unknown") |> normalize_path.()
        summary = Map.get(claim, "claim", "Codex reviewer finding")
        category = Map.get(claim, "category", "bug")
        severity = Map.get(claim, "severity", "medium")

        %{
          id: "#{method_id}-claim-#{index}",
          claim: summary,
          category: category,
          severity: severity,
          confidence: Map.get(claim, "confidence", 0.5),
          path: path,
          start_line: Map.get(claim, "start_line"),
          end_line: Map.get(claim, "end_line") || Map.get(claim, "start_line"),
          introduced_by_pr: Map.get(claim, "introduced_by_pr", true),
          evidence: [
            %{
              type: "codex_cli_review",
              tier: 4,
              strength: "medium",
              summary: Map.get(claim, "evidence_summary", summary)
            }
          ],
          failure_path: Map.get(claim, "failure_path", []),
          suggested_fix: Map.get(claim, "suggested_fix", ""),
          suggested_test: Map.get(claim, "suggested_test", ""),
          dedupe_key: "#{category}:#{path}:#{String.slice(summary, 0, 80)}",
          source: %{
            method: method_id,
            tool: "codex_repo",
            model: model,
            reasoning_effort: reasoning_effort,
            workspace_provided:
              is_binary(bundle_workspace_head) and File.dir?(bundle_workspace_head),
            raw_finding_ref: index
          },
          publish_decision: "candidate"
        }
      end)

    _other ->
      []
  end

errors =
  cond do
    status != 0 ->
      [
        %{
          reason:
            if(Map.get(runner_result, "timed_out"),
              do: "codex_timeout",
              else: "codex_non_zero_exit"
            ),
          status: status
        }
      ]

    parsed == :error ->
      [%{reason: "codex_invalid_json"}]

    true ->
      []
  end

artifacts = [
  %{
    adapter: "codex_repo_reviewer",
    repo_aware: true,
    cwd: cwd,
    workspace_head: bundle_workspace_head,
    workspace_base: bundle_workspace_base,
    model: model,
    reasoning_effort: reasoning_effort,
    status: status,
    timed_out: Map.get(runner_result, "timed_out", false),
    raw_stdout_preview: String.slice(raw_stdout || "", 0, 4000),
    raw_stderr_preview: String.slice(raw_stderr || "", 0, 4000),
    output_preview: String.slice(output_text || "", 0, 4000)
  }
]

File.rm(schema_path)
File.rm(output_path)
File.rm(request_path)

IO.write(
  :json.encode(%{
    reviewer_id: method_id,
    method_id: method_id,
    class: "research",
    claims: claims,
    cost: 0.0,
    latency_ms: duration_ms,
    artifacts: artifacts,
    errors: errors
  })
)

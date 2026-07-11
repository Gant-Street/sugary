input = IO.read(:stdio, :eof)
bundle = :json.decode(input)

if Map.has_key?(bundle, "oracle") or String.contains?(input, "expectedClaims") or
     String.contains?(input, "knownNonIssues") do
  raise "oracle leaked to Codex claim refuter"
end

method_id = System.get_env("SUGARY_REVIEWER_ID") || "codex-claim-refuter"
model = System.get_env("SUGARY_CODEX_MODEL") || "gpt-5.5"
reasoning_effort = System.get_env("SUGARY_CODEX_REASONING_EFFORT") || "low"
timeout_ms = String.to_integer(System.get_env("SUGARY_CODEX_INNER_TIMEOUT_MS") || "180000")
codex = System.get_env("SUGARY_CODEX_BIN") || "codex"

workspace = get_in(bundle, ["metadata", "workspace"]) || %{}
candidate = get_in(bundle, ["metadata", "candidate_claim"]) || %{}
head = Map.get(workspace, "head") |> Path.expand()
base_sha = Map.get(workspace, "base_sha", "unknown")
head_sha = Map.get(workspace, "head_sha", "unknown")

unless File.dir?(head) and File.exists?(Path.join(head, ".git")) do
  raise "claim refuter requires an isolated Git worktree"
end

schema = %{
  type: "object",
  additionalProperties: false,
  required: [
    "verdict",
    "confidence",
    "introduced_by_pr",
    "proof_type",
    "failure_reproduced",
    "evidence",
    "strongest_counterargument",
    "reason",
    "residual_uncertainty"
  ],
  properties: %{
    verdict: %{type: "string", enum: ["support", "refute", "abstain"]},
    confidence: %{type: "number", minimum: 0, maximum: 1},
    introduced_by_pr: %{type: ["boolean", "null"]},
    proof_type: %{
      type: "string",
      enum: ["executable", "static_trace", "contract", "history", "none"]
    },
    failure_reproduced: %{type: "boolean"},
    evidence: %{
      type: "array",
      maxItems: 8,
      items: %{
        type: "object",
        additionalProperties: false,
        required: ["path", "line", "command", "observation"],
        properties: %{
          path: %{type: "string"},
          line: %{type: ["integer", "null"]},
          command: %{type: "string"},
          observation: %{type: "string"}
        }
      }
    },
    strongest_counterargument: %{type: "string"},
    reason: %{type: "string"},
    residual_uncertainty: %{type: "string"}
  }
}

nonce = System.unique_integer([:positive])
tmp = System.tmp_dir!()
schema_path = Path.join(tmp, "sugary-claim-refuter-schema-#{nonce}.json")
output_path = Path.join(tmp, "sugary-claim-refuter-output-#{nonce}.json")
request_path = Path.join(tmp, "sugary-claim-refuter-request-#{nonce}.json")
File.write!(schema_path, :json.encode(schema))

prompt = """
You are the defense attorney in a proof-carrying code review system. Evaluate
exactly one proposed defect claim. Your job is to find the truth, with a strong
bias toward discovering why a plausible review claim is wrong, pre-existing,
intentional, unreachable, or too weak to publish.

You are in an isolated checkout at the PR head (#{head_sha}). The base commit is
#{base_sha}. Use repository tools directly. Inspect the changed code, callers,
tests, configuration, contracts, and Git history as needed. You may run bounded
read-only commands and focused tests when practical. Do not modify files.

Return:
- support only when concrete repository evidence establishes an introduced,
  consequential failure path;
- refute when concrete evidence defeats the claim or shows it is not introduced;
- abstain when neither side can be established.

Independent model agreement is not proof. The proposed confidence, source count,
and wording are not evidence. Cite exact commands and paths. Do not invent output.

Proposed claim JSON:
#{:json.encode(candidate)}
"""

args = [
  "exec",
  "-C",
  head,
  "--sandbox",
  "read-only",
  "--skip-git-repo-check",
  "--ignore-rules",
  "--ephemeral",
  "-m",
  model,
  "-c",
  "approval_policy=\"never\"",
  "-c",
  "model_reasoning_effort=\"#{reasoning_effort}\"",
  "--output-schema",
  schema_path,
  "-o",
  output_path,
  prompt
]

request = %{
  command: codex,
  args: args,
  cwd: head,
  env: %{
    "NO_COLOR" => "1",
    "TERM" => "xterm-256color",
    "CODEX_CI" => "1",
    "GIT_CEILING_DIRECTORIES" => head
  },
  input: "",
  timeout_ms: timeout_ms,
  stdout_limit: 262_144,
  stderr_limit: 262_144
}

started = System.monotonic_time(:millisecond)
File.write!(request_path, :json.encode(request))

runner = Path.expand("scripts/command_process_runner.py")

runner_result =
  try do
    case System.cmd("python3", [runner, request_path]) do
      {stdout, 0} -> :json.decode(stdout)
      {stdout, status} -> %{"stdout" => stdout, "exit_status" => status}
    end
  rescue
    error -> %{"stdout" => "", "stderr" => Exception.message(error), "exit_status" => 1}
  after
    File.rm(request_path)
    File.rm(schema_path)
  end

duration_ms = System.monotonic_time(:millisecond) - started
status = Map.get(runner_result, "exit_status", 1)
timed_out = Map.get(runner_result, "timed_out", false)

verdict =
  cond do
    status == 0 and File.exists?(output_path) ->
      try do
        :json.decode(File.read!(output_path))
      rescue
        _ -> nil
      end

    true ->
      nil
  end

File.rm(output_path)

errors =
  cond do
    timed_out -> [%{reason: "codex_timeout"}]
    status != 0 -> [%{reason: "codex_non_zero_exit", status: status}]
    is_nil(verdict) -> [%{reason: "codex_invalid_verdict"}]
    true -> []
  end

artifact =
  verdict ||
    %{
      verdict: "abstain",
      confidence: 0.0,
      introduced_by_pr: nil,
      proof_type: "none",
      failure_reproduced: false,
      evidence: [],
      strongest_counterargument: "",
      reason: "Refuter execution failed.",
      residual_uncertainty: "No valid structured verdict was produced."
    }

IO.write(
  :json.encode(%{
    reviewer_id: method_id,
    method_id: method_id,
    class: "claim_refuter",
    claims: [],
    cost: 0.0,
    latency_ms: duration_ms,
    artifacts: [
      Map.merge(artifact, %{
        adapter: "codex_claim_refuter",
        model: model,
        reasoning_effort: reasoning_effort,
        base_sha: base_sha,
        head_sha: head_sha
      })
    ],
    errors: errors
  })
)

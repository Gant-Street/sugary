input = IO.read(:stdio, :eof)
bundle = :json.decode(input)

if Map.has_key?(bundle, "oracle") or String.contains?(input, "expectedClaims") do
  raise "oracle leaked to Codex repo-grep reviewer"
end

method_id = System.get_env("SUGARY_REVIEWER_ID") || "codex-repo-grep-reviewer"
inner_timeout_ms = String.to_integer(System.get_env("SUGARY_CODEX_INNER_TIMEOUT_MS") || "120000")

inner_script =
  System.get_env("SUGARY_CODEX_REPO_INNER_SCRIPT") || "scripts/reviewers/codex_repo_reviewer.exs"

max_diff_chars = String.to_integer(System.get_env("SUGARY_CODEX_GREP_MAX_DIFF_CHARS") || "18000")
max_grep_lines = String.to_integer(System.get_env("SUGARY_CODEX_GREP_MAX_LINES") || "120")

workspace_head = get_in(bundle, ["metadata", "workspace", "head"])
changed_files = get_in(bundle, ["context", "changed_files"]) || []
diff = Map.get(bundle, "diff", "")

identifier_stopwords =
  MapSet.new(~w(
    import export default return const let var class function true false null undefined from this
    public private protected static final async await if else case when then with without
  ))

identifiers =
  diff
  |> String.split("\n")
  |> Enum.filter(&(String.starts_with?(&1, "+") and not String.starts_with?(&1, "+++")))
  |> Enum.flat_map(&Regex.scan(~r/[A-Za-z_][A-Za-z0-9_!?]{3,}/, &1))
  |> Enum.map(&hd/1)
  |> Enum.map(&String.trim_trailing(&1, "!?"))
  |> Enum.reject(&MapSet.member?(identifier_stopwords, String.downcase(&1)))
  |> Enum.frequencies()
  |> Enum.sort_by(fn {_identifier, count} -> -count end)
  |> Enum.map(&elem(&1, 0))
  |> Enum.take(24)

existing_changed_files =
  if is_binary(workspace_head) and File.dir?(workspace_head) do
    changed_files
    |> Enum.map(&to_string/1)
    |> Enum.filter(&File.regular?(Path.join(workspace_head, &1)))
    |> Enum.take(80)
  else
    []
  end

grep_context =
  if existing_changed_files == [] or identifiers == [] do
    []
  else
    pattern =
      identifiers
      |> Enum.map(&Regex.escape/1)
      |> Enum.join("|")

    args =
      ["-n", "--no-heading", "--color", "never", "-e", pattern] ++ existing_changed_files

    case System.cmd("rg", args, cd: workspace_head, stderr_to_stdout: true) do
      {output, _status} ->
        output
        |> String.split("\n", trim: true)
        |> Enum.take(max_grep_lines)

      _ ->
        []
    end
  end

compact_diff =
  if String.length(diff) > max_diff_chars do
    String.slice(diff, 0, max_diff_chars) <>
      "\n\n[diff truncated by repo-grep reviewer from #{String.length(diff)} chars]"
  else
    diff
  end

compact_bundle =
  bundle
  |> Map.put("diff", compact_diff)
  |> put_in(["context", "repo_grep"], %{
    "strategy" => "changed-file identifier grep",
    "identifiers" => identifiers,
    "lines" => grep_context
  })

tmp = System.tmp_dir!()
nonce = System.unique_integer([:positive])
request_path = Path.join(tmp, "sugary-codex-repo-grep-request-#{nonce}.json")

request = %{
  command: "elixir",
  args: [inner_script],
  cwd: ".",
  env: %{
    "NO_COLOR" => "1",
    "TERM" => "xterm-256color",
    "CODEX_CI" => "1"
  },
  input: compact_bundle |> :json.encode() |> IO.iodata_to_binary(),
  timeout_ms: inner_timeout_ms,
  stdout_limit: 262_144,
  stderr_limit: 262_144
}

started = System.monotonic_time(:millisecond)
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
      %{"stdout" => "", "stderr" => Exception.message(error), "exit_status" => 1}
  end

duration_ms = System.monotonic_time(:millisecond) - started
raw_stdout = Map.get(runner_result, "stdout", "")
raw_stderr = Map.get(runner_result, "stderr", "")
status = Map.get(runner_result, "exit_status", 1)

result =
  try do
    :json.decode(raw_stdout)
  rescue
    _error ->
      %{
        "method_id" => method_id,
        "claims" => [],
        "errors" => [
          %{
            "reason" =>
              if(Map.get(runner_result, "timed_out"),
                do: "repo_grep_timeout",
                else: "repo_grep_invalid_json"
              ),
            "status" => status
          }
        ],
        "artifacts" => []
      }
  end

artifacts =
  Map.get(result, "artifacts", []) ++
    [
      %{
        "adapter" => "codex_repo_grep_reviewer",
        "inner_script" => inner_script,
        "duration_ms" => duration_ms,
        "status" => status,
        "timed_out" => Map.get(runner_result, "timed_out", false),
        "changed_files" => length(changed_files),
        "existing_changed_files" => length(existing_changed_files),
        "identifiers" => identifiers,
        "grep_lines" => length(grep_context),
        "compact_diff_chars" => String.length(compact_diff),
        "raw_stderr_preview" => String.slice(raw_stderr || "", 0, 4000)
      }
    ]

result
|> Map.put("method_id", method_id)
|> Map.put("artifacts", artifacts)
|> then(&IO.write(:json.encode(&1)))

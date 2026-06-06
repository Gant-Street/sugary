defmodule Sugary.CommandReviewerTest do
  use ExUnit.Case

  alias Sugary.Protocol.ReviewInputBundle

  defp input_bundle do
    ReviewInputBundle.new(%{
      case_id: "command-test",
      suite: "local-fixtures",
      pr: %{title: "Command adapter test", body: ""},
      diff: "route_admin",
      context: %{symbols: ["route_admin"]},
      method: %{id: "command-reviewer"},
      metadata: %{tags: ["test"]}
    })
  end

  defp command_method(attrs) do
    Map.merge(
      %{
        id: "command-reviewer",
        type: "command",
        class: "research",
        context: "external_command",
        candidate_generation: "command",
        evidence: "none",
        refutation: "none",
        ranking: "fixed_threshold",
        command: "elixir",
        args: [],
        timeout_ms: 5_000,
        cwd: ".",
        env: [],
        env_allowlist: []
      },
      attrs
    )
  end

  defp write_script(name, body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-command-reviewer-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, name)
    File.write!(path, body)
    path
  end

  defp success_script(extra \\ "") do
    """
    input = IO.read(:stdio, :eof)
    bundle = :json.decode(input)

    if Map.has_key?(bundle, "oracle") or Map.has_key?(bundle, "expectedClaims") do
      raise "oracle leaked to command reviewer"
    end

    #{extra}

    result = %{
      reviewer_id: "external-script",
      method_id: "external-script",
      class: "research",
      claims: [
        %{
          id: "command-claim",
          claim: "Command reviewer claim for " <> Map.fetch!(bundle, "case_id"),
          category: "security",
          severity: "high",
          confidence: 0.82,
          path: "src/router.ex",
          introduced_by_pr: true,
          evidence: [
            %{
              type: "command_reviewer",
              tier: 4,
              strength: "medium",
              summary: "The external command saw the sanitized input bundle."
            }
          ],
          dedupe_key: "command-claim",
          source: %{method: "external-script", class: "research"},
          publish_decision: "candidate"
        }
      ],
      cost: 0.01,
      latency_ms: 7,
      artifacts: [],
      errors: []
    }

    IO.write(:json.encode(result))
    """
  end

  defp run_script(body, attrs \\ %{}) do
    script = write_script("reviewer.exs", body)
    method = command_method(Map.merge(%{args: [script]}, attrs))
    Sugary.CommandReviewer.run(method, input_bundle())
  end

  defp artifact(result), do: result.artifacts |> List.first()

  test "successful command reviewer output returns claims and captures artifacts" do
    result = run_script(success_script())
    adapter = artifact(result)

    assert result.reviewer_id == "command-reviewer"
    assert result.method_id == "command-reviewer"
    assert length(result.claims) == 1
    assert hd(result.claims).claim =~ "command-test"
    assert adapter.adapter == "command"
    assert adapter.exit_status == 0
    assert adapter.timed_out == false
    assert adapter.failure_reason == nil
    assert adapter.raw_stdout =~ "command-claim"
    assert adapter.raw_stderr == ""
  end

  test "successful command reviewer preserves compact self-reported artifacts" do
    result =
      run_script("""
      result = %{
        reviewer_id: "external-script",
        method_id: "external-script",
        class: "research",
        claims: [],
        cost: 0.0,
        latency_ms: 7,
        artifacts: [
          %{
            adapter: "inner-tool-loop",
            tool_calls: 2,
            transcript: [
              %{tool: "read_file", result: %{content: String.duplicate("x", 3000)}}
            ],
            raw_stdout_preview: "drop me"
          }
        ],
        errors: []
      }

      IO.write(:json.encode(result))
      """)

    [inner] = artifact(result).reviewer_artifacts

    assert inner.adapter == "inner-tool-loop"
    assert inner.tool_calls == 2
    refute Map.has_key?(inner, :raw_stdout_preview)
    assert inner.transcript |> hd() |> get_in([:result, :content]) |> String.length() == 2_000
  end

  test "invalid JSON output becomes a reviewer failure" do
    result = run_script(~S|IO.write("not json")|)

    assert result.claims == []
    assert [%{reason: "invalid_json"}] = result.errors
    assert artifact(result).raw_stdout == "not json"
  end

  test "schema-invalid ReviewerResult JSON becomes a reviewer failure" do
    result = run_script(~S|IO.write(:json.encode(%{reviewer_id: "missing-required-fields"}))|)

    assert result.claims == []
    assert [%{reason: "schema_invalid_json"}] = result.errors
  end

  test "timeout kills the command and isolates the reviewer failure" do
    result =
      run_script(
        """
        Process.sleep(1_000)
        IO.write("late")
        """,
        %{timeout_ms: 50}
      )

    assert result.claims == []
    assert [%{reason: "timeout"}] = result.errors
    assert artifact(result).timed_out == true
  end

  test "non-zero exit captures stderr without crashing the experiment" do
    result =
      run_script("""
      IO.puts(:stderr, "external reviewer failed")
      System.halt(7)
      """)

    assert result.claims == []
    assert [%{reason: "non_zero_exit"}] = result.errors
    assert artifact(result).exit_status == 7
    assert artifact(result).raw_stderr =~ "external reviewer failed"
  end

  test "stderr is captured on successful reviewer runs" do
    result = run_script(success_script(~S|IO.puts(:stderr, "diagnostic log")|))

    assert length(result.claims) == 1
    assert artifact(result).raw_stderr =~ "diagnostic log"
  end

  test "configured and environment-like secrets are redacted from captured logs" do
    secret = "sk-test-command-redaction"

    result =
      run_script(
        success_script(~S|IO.puts(:stderr, "secret=" <> System.fetch_env!("OPENAI_API_KEY"))|),
        %{env: ["OPENAI_API_KEY=#{secret}"]}
      )

    assert artifact(result).raw_stderr =~ "[REDACTED]"
    refute artifact(result).raw_stderr =~ secret
  end

  test "stdout and stderr capture obey size limits" do
    result =
      run_script(
        """
        IO.write(String.duplicate("o", 128))
        IO.write(:stderr, String.duplicate("e", 128))
        """,
        %{stdout_limit: 16, stderr_limit: 16}
      )

    adapter = artifact(result)
    assert result.claims == []
    assert [%{reason: "invalid_json"}] = result.errors
    assert adapter.stdout_truncated == true
    assert adapter.stderr_truncated == true
    assert String.length(adapter.raw_stdout) <= 16
    assert String.length(adapter.raw_stderr) <= 16
  end

  test "missing executable is recorded as command_not_found" do
    method =
      command_method(%{
        command: "definitely-not-a-real-sugary-command",
        args: []
      })

    result = Sugary.CommandReviewer.run(method, input_bundle())

    assert result.claims == []
    assert [%{reason: "command_not_found"}] = result.errors
    assert artifact(result).exit_status == 127
    assert artifact(result).raw_stderr =~ "command not found"
  end

  test "explicit env map and metadata manifest fields are parsed" do
    manifest =
      Sugary.Toml.parse!("""
      id = "command-env-map"
      suite = "local-fixtures"

      [[reviewers]]
      id = "env-command"
      type = "command"
      command = "elixir"
      args = ["scripts/sample_command_reviewer.exs"]
      env = { OPENAI_API_KEY = "local-secret" }
      metadata = { provider = "sample" }
      artifact_fields = ["raw_stdout", "raw_stderr"]
      """)

    [reviewer] = manifest["reviewers"]
    method = Sugary.Methods.from_manifest_reviewer(reviewer)

    assert method.env == %{"OPENAI_API_KEY" => "local-secret"}
    assert method.metadata == %{"provider" => "sample"}
    assert method.artifact_fields == ["raw_stdout", "raw_stderr"]
  end

  test "reviewer failure is isolated inside an experiment run" do
    script = write_script("invalid_json_reviewer.exs", ~S|IO.write("not json")|)
    id = "command-failure-isolation-#{System.unique_integer([:positive])}"

    manifest_path =
      write_script(
        "failure_manifest.toml",
        """
        id = "#{id}"
        suite = "local-fixtures"

        [[reviewers]]
        id = "bad-command"
        type = "command"
        command = "elixir"
        args = ["#{script}"]
        timeout_ms = 1000
        cwd = "."
        """
      )

    run_dir = Sugary.Runner.run_experiment_file!(manifest_path)
    on_exit(fn -> File.rm_rf(run_dir) end)

    assert File.exists?(Path.join(run_dir, "report.md"))

    [result_path | _] =
      Path.wildcard(Path.join([run_dir, "reviewer-results", "bad-command--*.json"]))

    result = Sugary.Json.read!(result_path)

    assert result["claims"] == []
    assert [%{"reason" => "invalid_json"}] = result["errors"]
  end

  test "sample command reviewer runs through an experiment manifest" do
    run_dir = Sugary.Runner.run_experiment_file!("experiments/sample-command-reviewer.toml")
    on_exit(fn -> File.rm_rf(run_dir) end)

    assert File.exists?(Path.join(run_dir, "report.md"))
    assert Path.wildcard(Path.join([run_dir, "adapter-artifacts", "*.json"])) != []

    result_paths =
      Path.wildcard(Path.join([run_dir, "reviewer-results", "sample-command-reviewer--*.json"]))

    assert result_paths != []

    assert Enum.any?(result_paths, fn path ->
             result = Sugary.Json.read!(path)
             result["reviewer_id"] == "sample-command-reviewer"
           end)
  end
end

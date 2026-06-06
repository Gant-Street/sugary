defmodule Sugary.CodexToolLoopReviewerTest do
  use ExUnit.Case

  alias Sugary.Protocol.ReviewInputBundle

  defp run_reviewer(input, env \\ %{}) do
    request_path =
      Path.join(
        System.tmp_dir!(),
        "sugary-tool-loop-wrapper-test-#{System.unique_integer([:positive])}.json"
      )

    request = %{
      command: "elixir",
      args: ["scripts/reviewers/codex_tool_loop_reviewer.exs"],
      cwd: File.cwd!(),
      env:
        Map.merge(
          %{
            "SUGARY_TOOL_LOOP_FAKE_CODEX" => "1",
            "SUGARY_REVIEWER_ID" => "tool-loop-wrapper-test"
          },
          env
        ),
      input: Sugary.Json.encode!(input),
      timeout_ms: 5_000,
      stdout_limit: 131_072,
      stderr_limit: 65_536
    }

    try do
      File.write!(request_path, Sugary.Json.encode!(request))
      {stdout, 0} = System.cmd("python3", ["scripts/command_process_runner.py", request_path])
      runner = Sugary.Json.decode!(stdout)
      assert runner["exit_status"] == 0
      Sugary.Json.decode!(runner["stdout"])
    after
      File.rm(request_path)
    end
  end

  test "fake mode exercises bounded repo tools and emits ReviewerResult JSON" do
    workspace = tmp_dir("tool-loop-workspace")

    on_exit(fn -> File.rm_rf(workspace) end)

    File.mkdir_p!(Path.join(workspace, "src"))

    File.write!(
      Path.join(workspace, "src/reviewer.ts"),
      "export function review(value) {\n  return value.user.canReview;\n}\n"
    )

    input =
      ReviewInputBundle.new(%{
        case_id: "blind-case",
        suite: "blind",
        pr: %{title: "Reviewer change", body: "Tighten review checks"},
        diff: """
        diff --git a/src/reviewer.ts b/src/reviewer.ts
        -  return true;
        +  return value.user.canReview;
        """,
        context: %{changed_files: [%{path: "src/reviewer.ts"}]},
        method: %{id: "tool-loop-wrapper-test"},
        metadata: %{workspace: %{head: workspace, base: workspace}}
      })

    result = run_reviewer(input)
    [artifact] = result["artifacts"]
    transcript = artifact["transcript"]

    assert result["reviewer_id"] == "tool-loop-wrapper-test"
    assert result["claims"] == []
    assert artifact["adapter"] == "codex_tool_loop_reviewer"
    assert artifact["tool_loop"] == true
    assert artifact["workspace_provided"] == true
    assert artifact["tool_calls"] == 2
    assert Enum.map(transcript, & &1["tool"]) == ["changed_files", "read_file"]

    read_observation = Enum.at(transcript, 1)
    assert get_in(read_observation, ["result", "path"]) == "src/reviewer.ts"
    assert get_in(read_observation, ["result", "content"]) =~ "value.user.canReview"
  end

  test "fake mode can emit a schema-valid claim after tool use" do
    workspace = tmp_dir("tool-loop-claim-workspace")

    on_exit(fn -> File.rm_rf(workspace) end)

    File.mkdir_p!(Path.join(workspace, "src"))
    File.write!(Path.join(workspace, "src/reviewer.ts"), "export const value = 1;\n")

    input =
      ReviewInputBundle.new(%{
        case_id: "blind-case",
        suite: "blind",
        pr: %{title: "Reviewer change", body: ""},
        diff: "diff --git a/src/reviewer.ts b/src/reviewer.ts\n+export const value = 1;\n",
        context: %{changed_files: [%{path: "src/reviewer.ts"}]},
        method: %{id: "tool-loop-wrapper-test"},
        metadata: %{workspace: %{head: workspace, base: workspace}}
      })

    result = run_reviewer(input, %{"SUGARY_TOOL_LOOP_FAKE_CLAIM" => "1"})
    [claim] = result["claims"]

    assert claim["id"] == "tool-loop-wrapper-test-claim-1"
    assert claim["evidence"] |> hd() |> Map.get("type") == "codex_tool_loop_review"
    assert claim["source"]["tool"] == "codex_tool_loop"
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "sugary-#{name}-#{System.unique_integer([:positive])}")
  end
end

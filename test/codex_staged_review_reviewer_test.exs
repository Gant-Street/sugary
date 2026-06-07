defmodule Sugary.CodexStagedReviewReviewerTest do
  use ExUnit.Case

  alias Sugary.Protocol.ReviewInputBundle

  defp run_reviewer(input, env \\ %{}) do
    request_path =
      Path.join(
        System.tmp_dir!(),
        "sugary-staged-review-wrapper-test-#{System.unique_integer([:positive])}.json"
      )

    request = %{
      command: "elixir",
      args: ["scripts/reviewers/codex_staged_review_reviewer.exs"],
      cwd: File.cwd!(),
      env:
        Map.merge(
          %{
            "SUGARY_STAGED_FAKE_CODEX" => "1",
            "SUGARY_REVIEWER_ID" => "staged-wrapper-test"
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

  test "fake mode generates candidates, validates with repo evidence, and emits claims" do
    workspace = tmp_dir("staged-review-workspace")

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
        method: %{id: "staged-wrapper-test"},
        metadata: %{workspace: %{head: workspace, base: workspace}}
      })

    result = run_reviewer(input)
    [artifact] = result["artifacts"]
    [claim] = result["claims"]

    assert result["reviewer_id"] == "staged-wrapper-test"
    assert artifact["adapter"] == "codex_staged_review_reviewer"
    assert artifact["staged_review"] == true
    assert artifact["workspace_provided"] == true
    assert artifact["candidate_count"] == 1
    assert artifact["validation_count"] == 1
    assert artifact["validated_count"] == 1
    assert artifact["validation_stage"] |> hd() |> Map.get("verdict") == "validated"

    assert artifact["validation_stage"]
           |> hd()
           |> Map.get("evidence_tools")
           |> Enum.map(& &1["tool"]) == [
             "changed_files",
             "read_file"
           ]

    assert claim["id"] == "staged-wrapper-test-claim-1"
    assert claim["source"]["tool"] == "codex_staged_review"
    assert claim["source"]["validator_verdict"] == "validated"
    assert claim["evidence"] |> hd() |> Map.get("type") == "staged_validation"
  end

  test "fake mode does not validate without a materialized workspace" do
    input =
      ReviewInputBundle.new(%{
        case_id: "blind-case",
        suite: "blind",
        pr: %{title: "Reviewer change", body: ""},
        diff: "diff --git a/src/reviewer.ts b/src/reviewer.ts\n+export const value = 1;\n",
        context: %{changed_files: [%{path: "src/reviewer.ts"}]},
        method: %{id: "staged-wrapper-test"},
        metadata: %{}
      })

    result = run_reviewer(input)
    [artifact] = result["artifacts"]

    assert result["claims"] == []
    assert artifact["candidate_count"] == 1
    assert artifact["validation_count"] == 1
    assert artifact["validated_count"] == 0
    assert artifact["validation_stage"] |> hd() |> Map.get("verdict") == "uncertain"
  end

  defp tmp_dir(name) do
    Path.join(System.tmp_dir!(), "sugary-#{name}-#{System.unique_integer([:positive])}")
  end
end

defmodule Sugary.ToolGauntletTest do
  use ExUnit.Case

  defp with_env(name, value, fun) do
    previous = System.get_env(name)
    System.put_env(name, value)

    try do
      fun.()
    after
      if previous do
        System.put_env(name, previous)
      else
        System.delete_env(name)
      end
    end
  end

  defp write_case(dir, id) do
    Sugary.Json.write!(Path.join(dir, "#{id}.json"), %{
      id: id,
      repo: "example/repo",
      title: "Admin route auth",
      diff:
        "diff --git a/src/app.ex b/src/app.ex\n--- a/src/app.ex\n+++ b/src/app.ex\n+get \"/admin\", AdminController, :index\n",
      changed_files: ["src/app.ex"],
      expectedClaims: [
        %{
          id: "missing-auth",
          description: "Admin route does not check authorization.",
          category: "security",
          severity: "high",
          path: "src/app.ex"
        }
      ],
      knownNonIssues: []
    })
  end

  defp claim(attrs) do
    Map.merge(
      %{
        id: "hit",
        claim: "Admin route does not check authorization.",
        category: "security",
        severity: "high",
        confidence: 0.9,
        path: "src/app.ex",
        start_line: 1,
        end_line: 1,
        introduced_by_pr: true,
        failure_path: ["PR adds route", "route has no authorization", "admin data is exposed"],
        evidence: [
          %{
            type: "codex_cli_review",
            tier: 4,
            strength: "medium",
            summary: "Route has no authorization guard."
          }
        ],
        suggested_fix: "Require authorization.",
        suggested_test: "Add an unauthorized request test.",
        dedupe_key: "missing-auth",
        source: %{method: "candidate"},
        publish_decision: "candidate"
      },
      attrs
    )
  end

  test "keeps a read-changed-files tool when it removes outside-file noise" do
    bench_dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-tool-gauntlet-bench-#{System.unique_integer([:positive])}"
      )

    source_run =
      Path.join(
        System.tmp_dir!(),
        "sugary-tool-gauntlet-run-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(bench_dir)
    on_exit(fn -> File.rm_rf(bench_dir) end)
    on_exit(fn -> File.rm_rf(source_run) end)

    write_case(bench_dir, "case-one")
    case_id = "martian-offline-1-case-one"

    noisy_style =
      claim(%{
        id: "noise",
        claim: "License header style is inconsistent in an unrelated file.",
        category: "style",
        severity: "high",
        confidence: 0.98,
        path: "src/other.ex",
        failure_path: ["Unrelated file has a style concern"],
        dedupe_key: "style-noise"
      })

    Sugary.Json.write!(
      Path.join([source_run, "candidate-team", "claims", "#{case_id}.json"]),
      [claim(%{}), noisy_style]
    )

    Sugary.Json.write!(Path.join([source_run, "raw-baseline", "claims", "#{case_id}.json"]), [
      claim(%{id: "raw-hit", publish_decision: "publish"})
    ])

    with_env("MARTIAN_BENCH_DIR", bench_dir, fn ->
      out_dir =
        Sugary.ToolGauntlet.run!(
          source_run: source_run,
          method_id: "candidate-team",
          baseline_id: "raw-baseline",
          limit: 1,
          id: "tool-gauntlet-test",
          capabilities: ["read_changed_files", "repo_rg"],
          max_published: 2,
          min_score: 2.0
        )

      on_exit(fn -> File.rm_rf(out_dir) end)

      decision = Sugary.Json.read!(Path.join(out_dir, "decision.json"))
      assert decision["kept_capabilities"] == ["read_changed_files"]

      [first, second] = decision["steps"]
      assert get_in(first, ["decision", "decision"]) == "keep"
      assert get_in(first, ["candidate", "score", "noise"]) == 0
      assert get_in(second, ["decision", "decision"]) == "discard"

      assert File.read!(Path.join(out_dir, "tool-gauntlet-report.md")) =~ "Tool Gauntlet v0"
      assert File.read!(Path.join(out_dir, "tool-transcripts.jsonl")) =~ "read_changed_files"
    end)
  end

  test "base preexisting check can suppress introducedness-refuted noise" do
    bench_dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-tool-gauntlet-quarantine-bench-#{System.unique_integer([:positive])}"
      )

    source_run =
      Path.join(
        System.tmp_dir!(),
        "sugary-tool-gauntlet-quarantine-run-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(bench_dir)
    on_exit(fn -> File.rm_rf(bench_dir) end)
    on_exit(fn -> File.rm_rf(source_run) end)

    write_case(bench_dir, "case-one")
    case_id = "martian-offline-1-case-one"

    noisy_new_hit =
      claim(%{
        id: "maybe-hit",
        claim: "Admin route does not check authorization.",
        confidence: 0.91,
        path: "unknown",
        dedupe_key: "missing-auth-alt"
      })

    noisy_false_positive =
      claim(%{
        id: "noise",
        claim: "Preexisting unrelated route might need style cleanup.",
        category: "style",
        severity: "high",
        confidence: 0.99,
        path: "src/app.ex",
        introduced_by_pr: false,
        dedupe_key: "preexisting-style"
      })

    Sugary.Json.write!(
      Path.join([source_run, "candidate-team", "claims", "#{case_id}.json"]),
      [noisy_new_hit, noisy_false_positive]
    )

    Sugary.Json.write!(Path.join([source_run, "raw-baseline", "claims", "#{case_id}.json"]), [])

    with_env("MARTIAN_BENCH_DIR", bench_dir, fn ->
      out_dir =
        Sugary.ToolGauntlet.run!(
          source_run: source_run,
          method_id: "candidate-team",
          baseline_id: "raw-baseline",
          limit: 1,
          id: "tool-gauntlet-quarantine-test",
          capabilities: ["base_preexisting_check"],
          max_published: 2,
          min_score: 1.8
        )

      on_exit(fn -> File.rm_rf(out_dir) end)

      decision = Sugary.Json.read!(Path.join(out_dir, "decision.json"))
      [step] = decision["steps"]
      assert get_in(step, ["decision", "decision"]) == "keep"
      assert get_in(step, ["candidate", "score", "noise"]) == 0
      assert File.read!(Path.join(out_dir, "tool-transcripts.jsonl")) =~ "base_preexisting_check"
    end)
  end
end

defmodule Sugary.MartianOrchestratorGateTest do
  use ExUnit.Case

  defp with_env(name, value, fun) do
    previous = System.get_env(name)

    if value in [nil, ""] do
      System.delete_env(name)
    else
      System.put_env(name, value)
    end

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

  defp mock_martian_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-martian-orchestrator-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    Sugary.Json.write!(Path.join(dir, "case-one.json"), %{
      id: "martian-source-case-001",
      repo: "example/repo",
      title: "Add generated admin route",
      body: "Local public benchmark smoke fixture.",
      diff:
        "diff --git a/src/router.ex b/src/router.ex\n+ route_admin hard_generated_api_hallucination",
      changed_files: ["src/router.ex"],
      expectedClaims: [
        %{
          id: "admin-route-missing-auth",
          description: "Generated admin route does not check authorization.",
          category: "security",
          severity: "high",
          path: "src/router.ex",
          line: 42,
          difficulty: "hard",
          specialist: "security",
          required_context: ["route", "middleware"]
        }
      ],
      knownNonIssues: [
        %{
          id: "style-only-route-name",
          description: "Route naming is style-only.",
          trapCategory: "stylistic_preference",
          path: "src/router.ex"
        }
      ]
    })

    dir
  end

  defp test_team_path do
    dir = Path.join(System.tmp_dir!(), "sugary-test-teams-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "orchestrator-test-team.toml")

    File.write!(path, """
    id = "orchestrator-test-team"
    description = "Deterministic test team for Martian orchestration gate."
    failure_policy = "continue"
    merge_strategy = "dedupe_by_key_location_and_claim"
    max_published_claims = 3

    [[reviewers]]
    id = "public-static-proof-gate"
    type = "method"
    method = "public-static-proof-gate"
    """)

    path
  end

  test "Martian orchestrator gate writes bus, scorecard, report, and leakage artifacts" do
    bench_dir = mock_martian_dir()
    team_path = test_team_path()

    with_env("MARTIAN_BENCH_DIR", bench_dir, fn ->
      gate_dir =
        Sugary.MartianOrchestratorGate.run!(%{
          "id" => "orchestrator-gate-test",
          "limit" => "1",
          "team" => team_path,
          "agent-bus" => "local-jsonl",
          "replay-mode" => "cache-first"
        })

      scorecard = Sugary.Json.read!(Path.join(gate_dir, "orchestrator-scorecard.json"))
      experiment_run_dir = scorecard["experiment_run_dir"]

      on_exit(fn ->
        File.rm_rf(gate_dir)
        File.rm_rf(experiment_run_dir)
      end)

      assert File.exists?(Path.join(gate_dir, "agent-messages.jsonl"))
      assert File.exists?(Path.join(gate_dir, "orchestrator-scorecard.json"))
      assert File.exists?(Path.join(gate_dir, "orchestrator-report.md"))

      report = File.read!(Path.join(gate_dir, "orchestrator-report.md"))
      messages = File.read!(Path.join(gate_dir, "agent-messages.jsonl"))

      assert get_in(scorecard, ["agent_bus", "effective_backend"]) == "local-jsonl"
      assert get_in(scorecard, ["agent_bus_leakage", "fatal?"]) == false
      assert get_in(scorecard, ["leakage", "fatal?"]) == false

      assert scorecard["decision"] in [
               "orchestrated_team_beats_best_single_on_martian_smoke",
               "transport_validated_no_quality_lift"
             ]

      assert report =~ "Martian Orchestrator Gate"
      assert report =~ "unofficial local Martian smoke comparison"
      assert messages =~ "REVIEW_REQUEST"
      assert messages =~ "PUBLISH_DECISION"
      refute messages =~ "expectedClaims"
      refute messages =~ "martian-source-case-001"
    end)
  end
end

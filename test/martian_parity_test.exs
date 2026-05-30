defmodule Sugary.MartianParityTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

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

  defp mock_martian_root do
    root =
      Path.join(System.tmp_dir!(), "sugary-martian-parity-#{System.unique_integer([:positive])}")

    File.mkdir_p!(Path.join([root, "offline", "results"]))

    Sugary.Json.write!(Path.join([root, "offline", "results", "benchmark_data.json"]), %{
      "https://example.test/org/repo/pull/1" => %{
        "pr_title" => "Add generated admin route",
        "original_url" => "https://example.test/org/repo/pull/1",
        "source_repo" => "org/repo",
        "golden_comments" => [
          %{
            "comment" => "Generated admin route does not check authorization.",
            "severity" => "High"
          }
        ],
        "reviews" => [
          %{
            "tool" => "existing-tool",
            "repo_name" => "repo",
            "pr_url" => "https://example.test/pr",
            "review_comments" => []
          }
        ]
      }
    })

    root
  end

  defp claim(attrs) do
    Map.merge(
      %{
        id: "claim",
        claim: "Generated admin route does not check authorization.",
        category: "security",
        severity: "high",
        confidence: 0.9,
        path: "src/router.ex",
        start_line: 42,
        end_line: 42,
        introduced_by_pr: true,
        evidence: [
          %{type: "fixture", tier: 3, strength: "strong", summary: "route has no auth guard"}
        ],
        failure_path: ["generated route is reachable", "handler performs admin action"],
        dedupe_key: "missing-auth",
        source: %{method: "candidate"},
        publish_decision: "publish",
        suggested_fix: "Check authorization before calling the handler.",
        suggested_test: "Add an unauthorized request regression test."
      },
      attrs
    )
  end

  test "exports ranked Sugary claims into Martian benchmark data, candidates, and dedup groups" do
    File.rm_rf(".sugary/research/martian-parity")
    root = mock_martian_root()

    source_run =
      Path.join(System.tmp_dir!(), "sugary-parity-source-#{System.unique_integer([:positive])}")

    method_id = "candidate"

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(source_run)
      File.rm_rf(".sugary/research/martian-parity")
    end)

    with_env("MARTIAN_API_KEY", nil, fn ->
      with_env("MARTIAN_BENCH_DIR", root, fn ->
        [bench_case] = Sugary.PublicBenchmarks.load_cases!("martian-offline", limit: 1)

        Sugary.Json.write!(
          Path.join([source_run, "claims", "#{method_id}--#{bench_case.id}.json"]),
          [
            claim(%{id: "hit-high", severity: "high", confidence: 0.9}),
            claim(%{id: "hit-medium", severity: "medium", confidence: 0.85}),
            claim(%{id: "suppressed-low", severity: "low", confidence: 0.5})
          ]
        )

        out_dir =
          Sugary.MartianParity.export!(
            source_run: source_run,
            method: method_id,
            tool: "sugary-test",
            policy: "team-ev-max-2",
            martian_dir: root,
            model_dir: "sugary_test_model",
            limit: 1,
            id: "martian-parity-test"
          )

        summary = Sugary.Json.read!(Path.join(out_dir, "summary.json"))
        assert summary["cases_exported"] == 1
        assert summary["candidate_count"] == 2
        assert summary["credentials_present"] == false

        assert summary["official_pipeline_status"]["martian_step3_judge_comments"] ==
                 "blocked_missing_MARTIAN_API_KEY"

        benchmark_data =
          Sugary.Json.read!(Path.join([root, "offline", "results", "benchmark_data.json"]))

        entry = benchmark_data["https://example.test/org/repo/pull/1"]
        review = Enum.find(entry["reviews"], &(&1["tool"] == "sugary-test"))
        assert length(review["review_comments"]) == 2
        assert hd(review["review_comments"])["body"] =~ "Evidence:"
        assert Enum.any?(entry["reviews"], &(&1["tool"] == "existing-tool"))

        candidates =
          Sugary.Json.read!(
            Path.join([root, "offline", "results", "sugary_test_model", "candidates.json"])
          )

        assert length(candidates["https://example.test/org/repo/pull/1"]["sugary-test"]) == 2

        dedup =
          Sugary.Json.read!(
            Path.join([root, "offline", "results", "sugary_test_model", "dedup_groups.json"])
          )

        assert dedup["https://example.test/org/repo/pull/1"]["sugary-test"] == [[0], [1]]

        report = File.read!(Path.join(out_dir, "report.md"))
        assert report =~ "not an official Martian score"
        assert report =~ "singleton `dedup_groups.json`"
      end)
    end)
  end

  test "CLI exposes the Martian parity export command" do
    File.rm_rf(".sugary/research/martian-parity")
    root = mock_martian_root()

    source_run =
      Path.join(
        System.tmp_dir!(),
        "sugary-parity-cli-source-#{System.unique_integer([:positive])}"
      )

    method_id = "candidate"

    on_exit(fn ->
      File.rm_rf(root)
      File.rm_rf(source_run)
      File.rm_rf(".sugary/research/martian-parity")
    end)

    with_env("MARTIAN_BENCH_DIR", root, fn ->
      [bench_case] = Sugary.PublicBenchmarks.load_cases!("martian-offline", limit: 1)

      Sugary.Json.write!(Path.join([source_run, method_id, "claims", "#{bench_case.id}.json"]), [
        claim(%{id: "hit-high"})
      ])

      output =
        capture_io(fn ->
          Sugary.CLI.main([
            "martian",
            "parity",
            "export",
            "--source-run",
            source_run,
            "--method",
            method_id,
            "--tool",
            "sugary-cli-test",
            "--policy",
            "team-ev-max-1",
            "--martian-dir",
            Path.join(root, "offline"),
            "--model-dir",
            "sugary_cli_model",
            "--limit",
            "1",
            "--id",
            "martian-parity-cli-test"
          ])
        end)

      assert output =~ ".sugary/research/martian-parity/"

      benchmark_data =
        Sugary.Json.read!(Path.join([root, "offline", "results", "benchmark_data.json"]))

      entry = benchmark_data["https://example.test/org/repo/pull/1"]
      assert Enum.any?(entry["reviews"], &(&1["tool"] == "sugary-cli-test"))
    end)
  end
end

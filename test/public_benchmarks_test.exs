defmodule Sugary.PublicBenchmarksTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

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

  defp mock_benchmark_dir(benchmark) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-#{benchmark}-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    Sugary.Json.write!(Path.join(dir, "case-one.json"), %{
      id: "#{benchmark}-source-case-001",
      repo: "example/repo",
      title: "Add generated admin route",
      body: "Local public benchmark smoke fixture.",
      diff: "route_admin hard_generated_api_hallucination",
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

  defp mock_aacr_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-aacr-bench-#{System.unique_integer([:positive])}"
      )

    dataset_dir = Path.join(dir, "dataset")
    File.mkdir_p!(dataset_dir)
    on_exit(fn -> File.rm_rf(dir) end)

    sample = %{
      "category" => "Bug Fix",
      "project_main_language" => "JavaScript",
      "source_commit" => "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
      "target_commit" => "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
      "change_line_count" => 12,
      "githubPrUrl" => "https://github.com/example/repo/pull/123",
      "diff" => """
      diff --git a/app/assets/javascripts/discourse/lib/utilities.js b/app/assets/javascripts/discourse/lib/utilities.js
      --- a/app/assets/javascripts/discourse/lib/utilities.js
      +++ b/app/assets/javascripts/discourse/lib/utilities.js
      -    var maxSizeKB = Discourse.SiteSettings['max_' + type + '_size_kb'];
      +    var maxSizeKB = 10 * 1024; // 10MB
      """,
      "comments" => [
        %{
          "is_ai_comment" => true,
          "note" =>
            "Hardcoding maxSizeKB = 10 * 1024 ignores Discourse.SiteSettings upload limits.",
          "path" => "app/assets/javascripts/discourse/lib/utilities.js",
          "side" => "right",
          "source_model" => "fixture",
          "from_line" => 4,
          "to_line" => 4,
          "category" => "Code Defect",
          "context" => "Diff Level"
        }
      ]
    }

    negative = %{
      sample
      | "comments" => [
          %{
            "is_ai_comment" => false,
            "note" => "The variable name could be shorter, but this is style-only.",
            "path" => "app/assets/javascripts/discourse/lib/utilities.js",
            "side" => "right",
            "source_model" => "",
            "from_line" => 4,
            "to_line" => 4,
            "category" => "Maintainability and Readability",
            "context" => "Diff Level"
          }
        ]
    }

    Sugary.Json.write!(Path.join(dataset_dir, "positive_samples.json"), [sample])
    Sugary.Json.write!(Path.join(dataset_dir, "negative_samples.json"), [negative])
    dir
  end

  test "public benchmark registry lists implemented and planned adapters" do
    rows = Sugary.PublicBenchmarks.list()

    assert Enum.find(rows, &(&1.benchmark == "martian-offline")).adapter == "local-smoke"
    assert Enum.find(rows, &(&1.benchmark == "cr-bench")).adapter == "local-smoke"
    assert Enum.find(rows, &(&1.benchmark == "aacr-bench")).adapter == "local-smoke"
    assert Enum.find(rows, &(&1.benchmark == "c-crab")).status == "planned"

    assert Sugary.PublicBenchmarks.render_list(rows) =~ "unofficial local scoring"
  end

  test "Martian adapter fails clearly when local data is unavailable" do
    with_env("MARTIAN_BENCH_DIR", "/tmp/sugary-missing-martian", fn ->
      assert {:error, message} = Sugary.Martian.fetch_local_only()
      assert message =~ "Martian offline benchmark not found"
      assert message =~ "No network fetch"
    end)
  end

  test "Martian adapter normalizes local mock data with source metadata" do
    dir = mock_benchmark_dir("martian-offline")

    with_env("MARTIAN_BENCH_DIR", dir, fn ->
      assert {:ok, [bench_case]} = Sugary.Martian.list_cases(1)

      assert bench_case.suite == "martian-offline"
      assert bench_case.public_benchmark == true
      assert bench_case.source_metadata.benchmark == "martian-offline"
      assert bench_case.source_metadata.original_case_id == "martian-offline-source-case-001"
      assert hd(bench_case.oracle.expectedClaims).id == "admin-route-missing-auth"
    end)
  end

  test "CR-Bench adapter fails clearly when local data is unavailable" do
    with_env("CR_BENCH_DIR", "/tmp/sugary-missing-cr-bench", fn ->
      assert {:error, message} = Sugary.CRBench.fetch_local_only()
      assert message =~ "CR-Bench data not found"
      assert message =~ "No network fetch"
    end)
  end

  test "CR-Bench adapter normalizes local mock data with source metadata" do
    dir = mock_benchmark_dir("cr-bench")

    with_env("CR_BENCH_DIR", dir, fn ->
      assert {:ok, [bench_case]} = Sugary.CRBench.list_cases(1)

      assert bench_case.suite == "cr-bench"
      assert bench_case.public_benchmark == true
      assert bench_case.source_metadata.benchmark == "cr-bench"
      assert bench_case.source_metadata.source_url =~ "2603.11078"
    end)
  end

  test "AACR-Bench adapter normalizes local mock data with comments and negative traps" do
    dir = mock_aacr_dir()

    with_env("AACR_BENCH_DIR", dir, fn ->
      assert {:ok, [bench_case]} = Sugary.AACRBench.list_cases(1)

      assert bench_case.suite == "aacr-bench"
      assert bench_case.public_benchmark == true
      assert bench_case.source_metadata.benchmark == "aacr-bench"
      assert bench_case.source_metadata.repo == "example/repo"
      assert hd(bench_case.oracle.expectedClaims).description =~ "Hardcoding maxSizeKB"
      assert hd(bench_case.oracle.knownNonIssues).trapCategory == "aacr_negative_reference"
      assert bench_case.diff =~ "diff --git"
    end)
  end

  test "public benchmark reviewer input excludes oracle and original case identifiers" do
    dir = mock_benchmark_dir("martian-offline")

    with_env("MARTIAN_BENCH_DIR", dir, fn ->
      {:ok, [bench_case]} = Sugary.Martian.list_cases(1)
      input = Sugary.Fixtures.input_bundle(bench_case, Sugary.Methods.get!("baseline-diff-only"))
      json = Sugary.Json.encode!(input)

      refute String.contains?(json, "expectedClaims")
      refute String.contains?(json, "knownNonIssues")
      refute String.contains?(json, "oracle")
      refute String.contains?(json, "martian-offline-source-case-001")
      refute String.contains?(json, "\"benchmark\":\"martian-offline\"")
      assert String.contains?(json, "public_benchmark")
      assert input.suite == "blind"
    end)
  end

  test "AACR-Bench reviewer input excludes oracle and original PR URL" do
    dir = mock_aacr_dir()

    with_env("AACR_BENCH_DIR", dir, fn ->
      {:ok, [bench_case]} = Sugary.AACRBench.list_cases(1)

      input =
        Sugary.Fixtures.input_bundle(bench_case, Sugary.Methods.get!("public-static-proof-gate"))

      json = Sugary.Json.encode!(input)

      refute String.contains?(json, "expectedClaims")
      refute String.contains?(json, "knownNonIssues")
      refute String.contains?(json, "oracle")
      refute String.contains?(json, "https://github.com/example/repo/pull/123")
      assert input.suite == "blind"
    end)
  end

  test "public benchmark input includes materialized workspace only for repo-aware methods" do
    dir = mock_benchmark_dir("martian-offline")

    with_env("MARTIAN_BENCH_DIR", dir, fn ->
      {:ok, [bench_case]} = Sugary.Martian.list_cases(1)
      workspace = Sugary.RepoMaterializer.workspace_paths(bench_case.id)
      File.mkdir_p!(workspace.base)
      File.mkdir_p!(workspace.head)

      on_exit(fn -> File.rm_rf(workspace.root) end)

      {:ok, [bench_case]} = Sugary.Martian.list_cases(1)

      diff_only =
        Sugary.Fixtures.input_bundle(bench_case, Sugary.Methods.get!("baseline-diff-only"))

      repo_aware =
        Sugary.Fixtures.input_bundle(bench_case, %{
          id: "repo-aware",
          include_workspace: true
        })

      refute Map.has_key?(diff_only.metadata, :workspace)
      assert File.dir?(repo_aware.metadata.workspace.head)
      assert File.dir?(repo_aware.metadata.workspace.base)
      assert repo_aware.metadata.workspace.head != Path.expand(workspace.head)
      assert repo_aware.metadata.workspace.base != Path.expand(workspace.base)
      assert repo_aware.metadata.workspace.head =~ "/.sugary/research/blind-workspaces/"

      json = Sugary.Json.encode!(repo_aware)
      refute String.contains?(json, "expectedClaims")
      refute String.contains?(json, "martian-offline-source-case-001")
    end)
  end

  test "public leakage detector catches oracle and source case id leaks" do
    dir = mock_benchmark_dir("martian-offline")

    with_env("MARTIAN_BENCH_DIR", dir, fn ->
      {:ok, [bench_case]} = Sugary.Martian.list_cases(1)

      run_dir =
        Path.join(System.tmp_dir!(), "sugary-public-leak-#{System.unique_integer([:positive])}")

      on_exit(fn -> File.rm_rf(run_dir) end)

      File.mkdir_p!(Path.join(run_dir, "input-bundles"))

      File.write!(
        Path.join([run_dir, "input-bundles", "leak.json"]),
        "expectedClaims martian-offline-source-case-001"
      )

      leakage = Sugary.PublicBenchmarks.leakage_report(run_dir, [bench_case])
      assert leakage.fatal? == true
      assert "martian-offline-source-case-001" in leakage.input_case_id_leaks
      assert length(leakage.oracle_input_files) == 1
    end)
  end

  test "public smoke run writes unofficial report artifacts" do
    File.rm_rf(".sugary/research/public-smoke")
    dir = mock_benchmark_dir("martian-offline")

    with_env("MARTIAN_BENCH_DIR", dir, fn ->
      run_dir = Sugary.Runner.run_bench!("martian-offline", "baseline-diff-only", limit: 1)
      on_exit(fn -> File.rm_rf(run_dir) end)

      public_dir = Path.join(".sugary/research/public-smoke", Path.basename(run_dir))
      on_exit(fn -> File.rm_rf(public_dir) end)

      assert File.exists?(Path.join(public_dir, "benchmark-metadata.json"))
      assert File.exists?(Path.join(public_dir, "leakage-report.json"))
      assert File.exists?(Path.join(public_dir, "public-smoke-report.md"))

      report = File.read!(Path.join(public_dir, "public-smoke-report.md"))
      assert report =~ "Unofficial local smoke run. Not an official benchmark score."
      assert report =~ "Source Metadata"
    end)
  end

  test "public smoke experiment supports command reviewer replay metadata" do
    File.rm_rf(".sugary/research/public-smoke")
    File.rm_rf(".sugary/research/replay-cache")
    dir = mock_benchmark_dir("martian-offline")

    with_env("MARTIAN_BENCH_DIR", dir, fn ->
      manifest = Sugary.Toml.parse_file!("experiments/public-hybrid-smoke-v0.toml")
      run_dir = Sugary.Runner.run_experiment_manifest!(%{manifest | replay_mode: "cache-first"})
      on_exit(fn -> File.rm_rf(run_dir) end)

      public_dir = Path.join(".sugary/research/public-smoke", Path.basename(run_dir))
      on_exit(fn -> File.rm_rf(public_dir) end)

      assert File.exists?(Path.join(public_dir, "reviewer-results"))
      report = File.read!(Path.join(run_dir, "report.md"))
      assert report =~ "External Reviewer Execution"
      assert report =~ "live"
    end)
  end

  test "benchmark compare command renders local and unofficial run summaries" do
    run_a = mock_run_dir("agent-written-hard-fixtures", "local-method", 0.4)
    run_b = mock_run_dir("martian-offline", "public-method", 0.5, "public-smoke")

    output =
      capture_io(fn ->
        Sugary.CLI.main(["bench", "compare", "--run", run_a, "--run", run_b])
      end)

    assert output =~ "Benchmark Comparison"
    assert output =~ "local-method"
    assert output =~ "public-method"
    assert output =~ "unofficial"
  end

  test "locked transfer gate writes a truthful AACR report" do
    File.rm_rf(".sugary/research/transfer-gates")
    dir = mock_aacr_dir()

    with_env("AACR_BENCH_DIR", dir, fn ->
      transfer_dir =
        Sugary.TransferGate.run!(%{
          "id" => "transfer-gate-test",
          "suite" => "aacr-bench",
          "limit" => 1,
          "static-run" => "/tmp/sugary-missing-static-run",
          "publisher-run" => "/tmp/sugary-missing-publisher-run"
        })

      on_exit(fn -> File.rm_rf(transfer_dir) end)

      assert File.exists?(Path.join(transfer_dir, "transfer-scorecard.json"))
      report = File.read!(Path.join(transfer_dir, "generalization-report.md"))
      assert report =~ "Locked PCRS v3 Transfer Gate"
      assert report =~ "Static proof candidate"
      assert report =~ "does not claim benchmark rank"
    end)
  end

  test "portable transfer gate reports candidate pool and leakage status" do
    File.rm_rf(".sugary/research/transfer-gates")
    dir = mock_benchmark_dir("martian-offline")

    with_env("MARTIAN_BENCH_DIR", dir, fn ->
      transfer_dir =
        Sugary.PortableTransferGate.run!(%{
          "id" => "portable-transfer-gate-test",
          "suites" => "martian-offline",
          "limit" => 1,
          "publisher" => false,
          "required-executable" => "elixir",
          "args" => ["scripts/sample_command_reviewer.exs"]
        })

      on_exit(fn -> File.rm_rf(transfer_dir) end)

      scorecard = Sugary.Json.read!(Path.join(transfer_dir, "portable-transfer-scorecard.json"))
      report = File.read!(Path.join(transfer_dir, "portable-transfer-report.md"))

      assert report =~ "PCRS v4 Portable Transfer Gate"
      assert report =~ "Portable candidate source"
      assert get_in(scorecard, ["suites", Access.at(0), "leakage", "fatal?"]) == false

      portable =
        get_in(scorecard, [
          "suites",
          Access.at(0),
          "methods",
          "pcrs-v4-portable-codex-repo-low"
        ])

      assert get_in(portable, ["candidate_pool", "claims"]) == 1
      assert is_integer(get_in(portable, ["candidate_pool", "hits"]))
    end)
  end

  defp mock_run_dir(suite, method_id, f1, prefix \\ "runs") do
    dir =
      Path.join([
        System.tmp_dir!(),
        "sugary-#{prefix}-#{System.unique_integer([:positive])}"
      ])

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    Sugary.Json.write!(Path.join(dir, "manifest.json"), %{suite: suite})

    Sugary.Json.write!(Path.join(dir, "scores.json"), [
      %{
        method_id: method_id,
        score: %{f1: f1, usefulness: 1.0, snr: 1.0}
      }
    ])

    dir
  end
end

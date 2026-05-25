defmodule Sugary.RankingPolicyAblationTest do
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

  defp write_case(dir, id, title) do
    Sugary.Json.write!(Path.join(dir, "#{id}.json"), %{
      id: id,
      repo: "example/repo",
      title: title,
      diff: "admin route missing auth",
      changed_files: ["src/router.ex"],
      expectedClaims: [
        %{
          id: "missing-auth",
          description: "Generated admin route does not check authorization.",
          category: "public_benchmark",
          severity: "high",
          path: "unknown"
        }
      ],
      knownNonIssues: []
    })
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
        start_line: 1,
        end_line: 1,
        introduced_by_pr: true,
        evidence: [%{type: "fixture", tier: 4, strength: "medium", summary: "route has no auth"}],
        dedupe_key: "missing-auth",
        source: %{method: "candidate"},
        publish_decision: "publish"
      },
      attrs
    )
  end

  test "Martian adapter supports offset slices" do
    dir = Path.join(System.tmp_dir!(), "sugary-offset-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    write_case(dir, "case-one", "One")
    write_case(dir, "case-two", "Two")

    with_env("MARTIAN_BENCH_DIR", dir, fn ->
      cases = Sugary.PublicBenchmarks.load_cases!("martian-offline", limit: 1, offset: 1)

      assert [bench_case] = cases
      assert bench_case.id == "martian-offline-2-case-two"
      assert bench_case.source_metadata.original_case_id == "case-two"
    end)
  end

  test "replay ablation promotes the highest utility policy that clears raw guardrails" do
    bench_dir =
      Path.join(System.tmp_dir!(), "sugary-ranking-bench-#{System.unique_integer([:positive])}")

    source_run =
      Path.join(System.tmp_dir!(), "sugary-ranking-run-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bench_dir)
    on_exit(fn -> File.rm_rf(bench_dir) end)
    on_exit(fn -> File.rm_rf(source_run) end)

    write_case(bench_dir, "case-one", "One")
    case_id = "martian-offline-1-case-one"

    Sugary.Json.write!(Path.join([source_run, "candidate", "claims", "#{case_id}.json"]), [
      claim(%{id: "hit", confidence: 0.9, dedupe_key: "missing-auth"}),
      claim(%{
        id: "noise",
        claim: "Route name style looks inconsistent.",
        category: "style",
        severity: "low",
        confidence: 0.8,
        dedupe_key: "style-noise"
      })
    ])

    Sugary.Json.write!(Path.join([source_run, "raw-baseline", "claims", "#{case_id}.json"]), [
      claim(%{
        id: "raw-noise",
        claim: "Route name style looks inconsistent.",
        category: "style",
        severity: "low",
        confidence: 0.8,
        dedupe_key: "raw-style-noise"
      })
    ])

    with_env("MARTIAN_BENCH_DIR", bench_dir, fn ->
      out_dir =
        Sugary.RankingPolicyAblation.run!(
          source_run: source_run,
          method_id: "candidate",
          baselines: ["raw-baseline"],
          limit: 1,
          id: "ranking-policy-ablation-test"
        )

      on_exit(fn -> File.rm_rf(out_dir) end)

      decision = Sugary.Json.read!(Path.join(out_dir, "decision.json"))
      assert decision["decision"] == "promote"
      assert decision["policy_id"] == "team-ev-max-1"

      report = File.read!(Path.join(out_dir, "report.md"))
      assert report =~ "Ranking Policy Ablation v1"
      assert report =~ "team-ev-max-1"
    end)
  end
end

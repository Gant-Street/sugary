defmodule Sugary.EvidenceRefutationRankerTest do
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
        "diff --git a/src/router.ex b/src/router.ex\n+get \"/admin\", AdminController, :index\n",
      changed_files: ["src/router.ex"],
      expectedClaims: [
        %{
          id: "missing-auth",
          description: "Generated admin route does not check authorization.",
          category: "security",
          severity: "high",
          path: "src/router.ex"
        }
      ],
      knownNonIssues: []
    })
  end

  defp claim(attrs) do
    Map.merge(
      %{
        id: "claim-hit",
        claim: "Generated admin route does not check authorization.",
        category: "security",
        severity: "high",
        confidence: 0.92,
        path: "src/router.ex",
        start_line: 1,
        end_line: 1,
        introduced_by_pr: true,
        failure_path: [
          "PR adds admin route",
          "route has no local auth check",
          "unauthorized user can reach handler"
        ],
        evidence: [
          %{
            type: "static_diff_proof",
            tier: 3,
            strength: "high",
            summary: "The diff adds an admin route without checking authorization."
          }
        ],
        suggested_fix: "Require admin authorization before dispatching the route.",
        suggested_test: "Add an unauthorized request test for /admin.",
        dedupe_key: "missing-auth",
        source: %{method: "candidate", agreement_count: 1},
        publish_decision: "publish"
      },
      attrs
    )
  end

  test "tunes and locks a dev-only evidence/refutation ranker" do
    bench_dir =
      Path.join(System.tmp_dir!(), "sugary-ranker-bench-#{System.unique_integer([:positive])}")

    source_run =
      Path.join(System.tmp_dir!(), "sugary-ranker-run-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bench_dir)
    on_exit(fn -> File.rm_rf(bench_dir) end)
    on_exit(fn -> File.rm_rf(source_run) end)

    write_case(bench_dir, "case-one")
    case_id = "martian-offline-1-case-one"

    Sugary.Json.write!(Path.join([source_run, "candidate-team", "claims", "#{case_id}.json"]), [
      claim(%{}),
      claim(%{
        id: "claim-noise",
        claim: "Maybe route naming style could be clearer.",
        category: "style",
        severity: "low",
        confidence: 0.8,
        path: "unknown",
        start_line: nil,
        failure_path: [],
        evidence: [%{type: "heuristic", tier: 5, strength: "weak", summary: "Maybe style issue"}],
        dedupe_key: "style-noise"
      })
    ])

    Sugary.Json.write!(Path.join([source_run, "raw-baseline", "claims", "#{case_id}.json"]), [
      claim(%{id: "raw-hit"}),
      claim(%{
        id: "raw-noise",
        claim: "Maybe route naming style could be clearer.",
        category: "style",
        severity: "low",
        path: "unknown",
        dedupe_key: "style-noise"
      })
    ])

    with_env("MARTIAN_BENCH_DIR", bench_dir, fn ->
      out_dir =
        Sugary.EvidenceRefutationRanker.tune_and_lock!(
          source_run: source_run,
          method_id: "candidate-team",
          baseline_id: "raw-baseline",
          limit: 1,
          id: "evidence-ranker-test"
        )

      on_exit(fn -> File.rm_rf(out_dir) end)

      lock = Sugary.Json.read!(Path.join(out_dir, "ranker-lock.json"))
      assert lock["version"] == "evidence-refutation-ranker-v1"
      assert get_in(lock, ["policy", "threshold"])

      decision = Sugary.Json.read!(Path.join(out_dir, "decision.json"))
      assert decision["policy_id"]

      report = File.read!(Path.join(out_dir, "report.md"))
      assert report =~ "Evidence/Refutation Ranker v1 Tuning"
    end)
  end

  test "evaluates a locked ranker and aggregates fresh slices" do
    bench_dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-ranker-eval-bench-#{System.unique_integer([:positive])}"
      )

    source_run =
      Path.join(System.tmp_dir!(), "sugary-ranker-eval-run-#{System.unique_integer([:positive])}")

    File.mkdir_p!(bench_dir)
    on_exit(fn -> File.rm_rf(bench_dir) end)
    on_exit(fn -> File.rm_rf(source_run) end)

    write_case(bench_dir, "case-one")
    case_id = "martian-offline-1-case-one"

    Sugary.Json.write!(Path.join([source_run, "candidate-team", "claims", "#{case_id}.json"]), [
      claim(%{})
    ])

    Sugary.Json.write!(Path.join([source_run, "raw-baseline", "claims", "#{case_id}.json"]), [])

    lock_path = Path.join(source_run, "ranker-lock.json")

    Sugary.Json.write!(lock_path, %{
      version: "evidence-refutation-ranker-v1",
      method_id: "candidate-team",
      policy: %{
        id: "test-policy",
        version: "evidence-refutation-ranker-v1",
        profile: "test",
        max_published: 1,
        threshold: 2.0,
        weights: %{
          confidence: 1.0,
          severity: 1.0,
          evidence_tier: 1.0,
          failure_path: 1.0,
          grounding: 1.0,
          introducedness: 1.0,
          agreement: 0.0,
          fix_test: 0.0,
          specificity: 0.0,
          static_proof: 0.0,
          refutation: 1.0
        }
      }
    })

    with_env("MARTIAN_BENCH_DIR", bench_dir, fn ->
      eval_dir =
        Sugary.EvidenceRefutationRanker.evaluate!(
          lock_path: lock_path,
          source_run: source_run,
          baseline_id: "raw-baseline",
          limit: 1,
          id: "evidence-ranker-eval-test"
        )

      aggregate_dir =
        Sugary.EvidenceRefutationRanker.aggregate!(
          evaluation_dirs: [eval_dir],
          id: "evidence-ranker-aggregate-test"
        )

      on_exit(fn -> File.rm_rf(eval_dir) end)
      on_exit(fn -> File.rm_rf(aggregate_dir) end)

      decision = Sugary.Json.read!(Path.join(eval_dir, "decision.json"))
      assert decision["unique_hits_over_baseline"] == 1

      aggregate = Sugary.Json.read!(Path.join(aggregate_dir, "aggregate-scorecard.json"))
      assert aggregate["unique_hits_over_baseline"] == 1
      assert File.read!(Path.join(aggregate_dir, "aggregate-report.md")) =~ "Aggregate"
    end)
  end
end

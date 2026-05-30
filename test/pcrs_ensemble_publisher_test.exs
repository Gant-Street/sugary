defmodule Sugary.PCRSEnsemblePublisherTest do
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

  defp write_case(dir) do
    Sugary.Json.write!(Path.join(dir, "case-one.json"), %{
      id: "case-one",
      repo: "example/repo",
      title: "Add generated admin route",
      body: "Mock public benchmark case.",
      diff: """
      diff --git a/src/router.ex b/src/router.ex
      +get "/admin", AdminController, :show
      """,
      changed_files: ["src/router.ex"],
      expectedClaims: [
        %{
          id: "missing-auth",
          description: "Generated admin route does not check authorization.",
          category: "security",
          severity: "high",
          path: "src/router.ex",
          line: 42
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
        start_line: 42,
        end_line: 42,
        introduced_by_pr: true,
        evidence: [
          %{type: "fixture", tier: 4, strength: "medium", summary: "route has no auth guard"}
        ],
        failure_path: ["route is reachable", "handler performs admin action"],
        suggested_test: "Assert anonymous users receive 403.",
        dedupe_key: "missing-auth",
        source: %{method: "fixture"},
        publish_decision: "suppress"
      },
      attrs
    )
  end

  defp write_claims(run, method, case_id, claims) do
    Sugary.Json.write!(Path.join([run, method, "claims", "#{case_id}.json"]), claims)
  end

  test "runs ensemble publisher and includes the no-triad consensus policy" do
    File.rm_rf(".sugary/research/pcrs-ensemble-publisher")

    bench_dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-pcrs-ensemble-bench-#{System.unique_integer([:positive])}"
      )

    baseline_run =
      Path.join(
        System.tmp_dir!(),
        "sugary-pcrs-ensemble-baseline-#{System.unique_integer([:positive])}"
      )

    candidate_run =
      Path.join(
        System.tmp_dir!(),
        "sugary-pcrs-ensemble-candidate-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(bench_dir)
    write_case(bench_dir)

    case_id = "martian-offline-1-case-one"
    write_claims(baseline_run, "pcrs-codex-repo-low-strict", case_id, [])

    triad_noise =
      claim(%{
        id: "triad-noise",
        claim: "Route naming should be shorter before merging.",
        category: "security",
        severity: "high",
        confidence: 0.99,
        dedupe_key: "triad-noise"
      })

    true_claim = claim(%{id: "true-auth", confidence: 0.8})

    write_claims(candidate_run, "pcrs-codex-repo-low-strict", case_id, [triad_noise])
    write_claims(candidate_run, "pcrs-codex-repo-low", case_id, [triad_noise, true_claim])

    write_claims(candidate_run, "martian-pcrs-repo-plus-codex-low", case_id, [
      triad_noise,
      true_claim
    ])

    write_claims(candidate_run, "pcrs-codex-proof-low", case_id, [true_claim])
    write_claims(candidate_run, "codex-gpt-5.5-repo-low", case_id, [true_claim])

    on_exit(fn ->
      File.rm_rf(bench_dir)
      File.rm_rf(baseline_run)
      File.rm_rf(candidate_run)
      File.rm_rf(".sugary/research/pcrs-ensemble-publisher")
    end)

    with_env("MARTIAN_BENCH_DIR", bench_dir, fn ->
      out_dir =
        Sugary.PCRSEnsemblePublisher.run!(
          baseline_run: baseline_run,
          candidate_run: candidate_run,
          limit: 1,
          id: "pcrs-ensemble-publisher-test"
        )

      policies = Sugary.Json.read!(Path.join(out_dir, "policy-scorecards.json"))

      no_triad =
        Enum.find(policies, &(&1["id"] == "posterior-max1-plus-source5-no-triad-budget52"))

      assert no_triad["score"]["hits"] == 1
      assert no_triad["score"]["noise"] == 0
      assert no_triad["policy"]["exclude_source_counts"] == [3]

      frontier = Sugary.Json.read!(Path.join(out_dir, "budget-frontier.json"))
      assert frontier["objective"] == "budget_f1_pareto_frontier"
      assert Map.has_key?(frontier["decision_rules"], "product_default_retained")

      assert File.exists?(Path.join(out_dir, "bootstrap.json"))
      assert File.exists?(Path.join(out_dir, "suppressed-true-positives.json"))
      assert File.exists?(Path.join(out_dir, "admitted-false-positives.json"))
      assert File.exists?(Path.join(out_dir, "calibration-by-policy.json"))
      assert File.exists?(Path.join([out_dir, no_triad["id"], "claims", "#{case_id}.json"]))
      assert File.exists?(Path.join(out_dir, "candidate-details.jsonl"))
      assert File.read!(Path.join(out_dir, "report.md")) =~ "not an official Martian score"
    end)
  end

  test "CLI exposes the PCRS ensemble publisher command" do
    File.rm_rf(".sugary/research/pcrs-ensemble-publisher")

    bench_dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-pcrs-ensemble-cli-bench-#{System.unique_integer([:positive])}"
      )

    baseline_run =
      Path.join(
        System.tmp_dir!(),
        "sugary-pcrs-ensemble-cli-baseline-#{System.unique_integer([:positive])}"
      )

    candidate_run =
      Path.join(
        System.tmp_dir!(),
        "sugary-pcrs-ensemble-cli-candidate-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(bench_dir)
    write_case(bench_dir)

    case_id = "martian-offline-1-case-one"
    write_claims(baseline_run, "pcrs-codex-repo-low-strict", case_id, [])
    write_claims(candidate_run, "pcrs-codex-repo-low", case_id, [claim(%{id: "true-auth"})])

    on_exit(fn ->
      File.rm_rf(bench_dir)
      File.rm_rf(baseline_run)
      File.rm_rf(candidate_run)
      File.rm_rf(".sugary/research/pcrs-ensemble-publisher")
    end)

    with_env("MARTIAN_BENCH_DIR", bench_dir, fn ->
      output =
        capture_io(fn ->
          Sugary.CLI.main([
            "pcrs",
            "ensemble",
            "publisher",
            "--baseline-run",
            baseline_run,
            "--candidate-run",
            candidate_run,
            "--limit",
            "1",
            "--id",
            "pcrs-ensemble-publisher-cli-test"
          ])
        end)

      assert output =~ ".sugary/research/pcrs-ensemble-publisher/"
    end)
  end
end

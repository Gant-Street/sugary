defmodule Sugary.StagedPublisherReplayTest do
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

  defp baseline_claim(attrs) do
    Map.merge(
      %{
        id: "raw-noise",
        claim: "Maybe route naming style could be clearer.",
        category: "style",
        severity: "low",
        confidence: 0.8,
        path: "unknown",
        introduced_by_pr: true,
        evidence: [%{type: "heuristic", tier: 5, strength: "weak", summary: "Maybe style issue"}],
        dedupe_key: "style-noise",
        source: %{method: "raw-baseline"},
        publish_decision: "publish"
      },
      attrs
    )
  end

  test "replays staged validation rows through publisher policies" do
    bench_dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-staged-replay-bench-#{System.unique_integer([:positive])}"
      )

    source_run =
      Path.join(
        System.tmp_dir!(),
        "sugary-staged-replay-run-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(bench_dir)
    on_exit(fn -> File.rm_rf(bench_dir) end)
    on_exit(fn -> File.rm_rf(source_run) end)

    write_case(bench_dir, "case-one")
    case_id = "martian-offline-1-case-one"

    Sugary.Json.write!(
      Path.join([source_run, "staged-method", "adapter-artifacts", "#{case_id}.json"]),
      [
        %{
          reviewer_artifacts: [
            %{
              adapter: "codex_staged_review_reviewer",
              validation_stage: [
                %{
                  claim: "Generated admin route does not check authorization.",
                  path: "src/router.ex",
                  confidence: 0.94,
                  evidence_summary:
                    "The PR adds an admin route in src/router.ex without an authorization guard.",
                  counterargument:
                    "No middleware authorization evidence was present in the diff.",
                  proof_decision: "publish",
                  proof_score: 0.94,
                  verdict: "validated",
                  source_role: "changed-code-security",
                  proof_features: %{
                    proof_type: "auth_security",
                    root_cause_key: "missing-auth",
                    introduced_by_pr: true,
                    has_repo_evidence: true,
                    has_read_file: true,
                    has_repo_grep: true,
                    has_failure_path: true,
                    expected_failure_language: true,
                    typed_requirements_met: true,
                    suppressing_invariants: [],
                    speculative_language: false
                  }
                },
                %{
                  claim: "Maybe the route name style is inconsistent.",
                  path: "src/router.ex",
                  confidence: 0.78,
                  evidence_summary: "The route name looks different from nearby code.",
                  proof_decision: "publish",
                  proof_score: 0.55,
                  verdict: "validated",
                  source_role: "diff-bug",
                  proof_features: %{
                    proof_type: "style",
                    root_cause_key: "style-noise",
                    introduced_by_pr: true,
                    has_repo_evidence: false,
                    has_read_file: true,
                    has_repo_grep: false,
                    has_failure_path: false,
                    expected_failure_language: false,
                    typed_requirements_met: false,
                    suppressing_invariants: [],
                    speculative_language: true
                  }
                }
              ]
            }
          ]
        }
      ]
    )

    Sugary.Json.write!(Path.join([source_run, "raw-baseline", "claims", "#{case_id}.json"]), [
      baseline_claim(%{})
    ])

    with_env("MARTIAN_BENCH_DIR", bench_dir, fn ->
      out_dir =
        Sugary.StagedPublisherReplay.run!(%{
          "source-run" => source_run,
          "method" => "staged-method",
          "baseline" => "raw-baseline",
          "limit" => "1",
          "id" => "staged-publisher-replay-test"
        })

      on_exit(fn -> File.rm_rf(out_dir) end)

      decision = Sugary.Json.read!(Path.join(out_dir, "decision.json"))
      assert decision["decision"] == "promote_for_live_check"
      assert decision["f1"] > 0.0

      [first_policy | _] = Sugary.Json.read!(Path.join(out_dir, "policy-scorecards.json"))
      assert first_policy["candidate_diagnostics"]["candidates"] == 2
      assert first_policy["candidate_diagnostics"]["candidate_hits"] == 1

      report = File.read!(Path.join(out_dir, "report.md"))
      assert report =~ "Staged Publisher Replay v0"
      assert report =~ "fixed staged `validation_stage`"
    end)
  end
end

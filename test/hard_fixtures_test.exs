defmodule Sugary.HardFixturesTest do
  use ExUnit.Case

  alias Sugary.Protocol

  @pack_path "reviewer-packs/baseline-pack-v0.toml"

  defp hard_cases(split \\ nil) do
    Sugary.Fixtures.load_suite!("agent-written-hard-fixtures", split: split)
  end

  defp case_by_id(id) do
    hard_cases()
    |> Enum.find(&(&1.id == id))
  end

  defp reviewer_method(id) do
    pack = Sugary.TeamSearch.load_pack!(@pack_path)
    reviewer = Enum.find(pack.reviewers, &(&1["id"] == id))
    Sugary.Methods.from_team_reviewer(reviewer)
  end

  defp method_report(method, cases) do
    results = Enum.map(cases, &Sugary.Pipeline.run_case(&1, method))

    %{
      method: method,
      score: Sugary.Scorer.score(method.id, results),
      failures: Sugary.Scorer.failures(method.id, results),
      results: results
    }
  end

  defp published_claim(id, attrs) do
    Protocol.ReviewClaim.new(
      Map.merge(
        %{
          id: id,
          claim: "Synthetic claim #{id}",
          category: "bug",
          severity: "medium",
          confidence: 0.7,
          path: "src/example.ex",
          introduced_by_pr: true,
          evidence: [],
          dedupe_key: id,
          source: %{method: "synthetic"},
          publish_decision: "publish"
        },
        Map.new(attrs)
      )
    )
  end

  test "suite manifest parses train, dev, holdout, and smoke splits" do
    manifest = Sugary.Fixtures.suite_manifest!("agent-written-hard-fixtures")

    assert manifest.suite.id == "agent-written-hard-fixtures"
    assert length(manifest.split.train.cases) == 4
    assert length(manifest.split.dev.cases) == 4
    assert length(manifest.split.holdout.cases) == 4
    assert manifest.split.smoke.cases == ["cross-file-null-contract", "tenant-isolation-leak"]
  end

  test "hard fixture suite loads all cases and split-specific subsets" do
    all = hard_cases()
    holdout = hard_cases("holdout")

    assert length(all) == 12
    assert length(holdout) == 4
    assert Enum.all?(holdout, &(&1.split == "holdout"))
    assert Enum.any?(all, &(&1.id == "cross-file-null-contract"))
  end

  test "holdout input bundles blind case id, suite, and split metadata" do
    bench_case = case_by_id("async-race-condition")
    method = Sugary.Methods.get!("baseline-diff-only")
    input = Sugary.Fixtures.input_bundle(bench_case, method)
    json = Sugary.Json.encode!(input)

    assert input.case_id =~ "holdout-case-"
    refute input.case_id == bench_case.id
    assert input.suite == "blind"
    assert input.metadata == %{holdout: true}
    refute json =~ "async-race-condition"
    refute json =~ "agent-written-hard-fixtures"
    refute json =~ "\"split\""
    refute json =~ "expectedClaims"
    refute json =~ "knownNonIssues"
  end

  test "hard fixtures include difficulty metadata and false-positive traps" do
    bench_case = case_by_id("tenant-isolation-leak")
    [claim] = bench_case.oracle.expectedClaims
    [trap] = bench_case.oracle.knownNonIssues

    assert bench_case.code_before =~ "export"
    assert bench_case.code_after =~ "export"
    assert claim.difficulty == "hard"
    assert claim.required_context == ["route", "middleware", "tenant_model"]
    assert claim.expected_evidence_tier == 3
    assert claim.specialist == "security"
    assert trap.trapCategory == "auth_check_elsewhere"
  end

  test "false-positive traps are scored with their trap category" do
    bench_case = case_by_id("tenant-isolation-leak")
    [trap] = bench_case.oracle.knownNonIssues
    claim = published_claim(trap.id, category: "security")

    result = %{
      case: bench_case,
      input: Sugary.Fixtures.input_bundle(bench_case, %{id: "synthetic"}),
      reviewer_result:
        Protocol.ReviewerResult.new(%{
          reviewer_id: "synthetic",
          method_id: "synthetic",
          class: "research",
          claims: [Protocol.to_map(claim)],
          cost: 0.0,
          latency_ms: 1,
          artifacts: [],
          errors: []
        }),
      candidate_claims: [claim],
      final_claims: [claim]
    }

    failures = Sugary.Scorer.failures("synthetic", [result])
    failure = Enum.find(failures, &(&1.type == "false_positive"))
    score = Sugary.Scorer.score("synthetic", [result])

    assert failure.category == "auth_check_elsewhere"
    assert score.noise == 1
  end

  test "saturation diagnostics flag saturated perfect-reviewer runs" do
    cases = hard_cases("smoke")
    method = Sugary.Methods.get!("golden-perfect-reviewer")
    report = method_report(method, cases)
    diagnostics = Sugary.Diagnostics.saturation([report], cases, "smoke")

    assert diagnostics.fixture_saturated == true
    assert diagnostics.any_perfect_reviewer == true
    assert diagnostics.complementarity_headroom == 0.0
    assert diagnostics.message =~ "This suite is saturated"
  end

  test "complementarity headroom is positive when reviewer union beats the best individual" do
    cases = hard_cases("dev")

    reports =
      [
        reviewer_method("security-specialist-reviewer"),
        reviewer_method("static-analysis-reviewer"),
        reviewer_method("adversarial-edge-case-reviewer")
      ]
      |> Enum.map(&method_report(&1, cases))

    diagnostics = Sugary.Diagnostics.saturation(reports, cases, "dev")

    refute diagnostics.fixture_saturated
    assert diagnostics.oracle_union_upper_bound.hits > 0
    assert diagnostics.complementarity_headroom > 0.0
  end

  test "score slices include category, difficulty, context, specialist, and evidence tier" do
    cases = hard_cases("dev")
    method = reviewer_method("security-specialist-reviewer")
    results = Enum.map(cases, &Sugary.Pipeline.run_case(&1, method))
    slices = Sugary.Scorer.slices(method.id, results)

    assert slices.category["security"].expected == 1
    assert slices.category["security"].hits == 1
    assert slices.difficulty["hard"].expected == 4
    assert slices.required_context["authorization_model"].expected == 1
    assert slices.specialist["security"].expected == 1
    assert slices.evidence_tier["3"].expected >= 1
  end

  test "anti-overfitting diagnostics warn on perfect tunable split runs" do
    cases = hard_cases("train")
    method = Sugary.Methods.get!("golden-perfect-reviewer")
    report = method_report(method, cases)
    warnings = Sugary.Diagnostics.anti_overfitting_warnings([report], cases, "train")

    assert Enum.any?(warnings, &(&1.type == "perfect_train_or_dev"))
    assert Enum.any?(warnings, &(&1.type == "exact_oracle_wording"))
    assert Enum.any?(warnings, &(&1.type == "no_failures_across_hard_cases"))
  end

  test "anti-overfitting diagnostics warn when hits depend on path category coupling" do
    bench_case = case_by_id("tenant-isolation-leak")

    claim =
      published_claim("tenant-isolation-leak",
        category: "security",
        path: "src/security/export.ex",
        dedupe_key: "tenant-isolation-leak"
      )

    result = %{
      case: bench_case,
      input: Sugary.Fixtures.input_bundle(bench_case, %{id: "path-shaped"}),
      reviewer_result:
        Protocol.ReviewerResult.new(%{
          reviewer_id: "path-shaped",
          method_id: "path-shaped",
          class: "research",
          claims: [Protocol.to_map(claim)],
          cost: 0.0,
          latency_ms: 1,
          artifacts: [],
          errors: []
        }),
      candidate_claims: [claim],
      final_claims: [claim]
    }

    report = %{
      method: %{id: "path-shaped", class: "research"},
      score: Sugary.Scorer.score("path-shaped", [result]),
      failures: Sugary.Scorer.failures("path-shaped", [result]),
      results: [result]
    }

    warnings = Sugary.Diagnostics.anti_overfitting_warnings([report], [bench_case], "dev")

    assert Enum.any?(warnings, &(&1.type == "path_category_coupling"))
  end

  test "hard-suite experiment writes diagnostics artifacts and report sections" do
    run_dir = Sugary.Runner.run_experiment_file!("experiments/pcrs-hard-fixtures-v0.toml")
    on_exit(fn -> File.rm_rf(run_dir) end)

    assert File.exists?(Path.join(run_dir, "saturation-diagnostics.json"))
    assert File.exists?(Path.join(run_dir, "anti-overfitting-warnings.json"))
    assert File.exists?(Path.join(run_dir, "coverage-matrix-v2.json"))
    assert File.exists?(Path.join(run_dir, "score-slices.json"))

    report = File.read!(Path.join(run_dir, "report.md"))

    assert report =~ "split: `dev`"
    assert report =~ "Saturation Diagnostics"
    assert report =~ "Anti-Overfitting Warnings"
  end

  test "team search runs against a split-specific hard suite" do
    run_dir =
      Sugary.TeamSearch.run!(
        @pack_path,
        "agent-written-hard-fixtures",
        split: "holdout",
        max_team_size: 2
      )

    on_exit(fn -> File.rm_rf(run_dir) end)

    summary = Sugary.Json.read!(Path.join(run_dir, "complementarity-summary.json"))
    report = File.read!(Path.join(run_dir, "report.md"))

    assert summary["suite"] == "agent-written-hard-fixtures"
    assert summary["split"] == "holdout"
    assert summary["holdout_warning"] =~ "Holdout warning"
    assert report =~ "split: `holdout`"
    assert report =~ "Holdout warning"
  end
end

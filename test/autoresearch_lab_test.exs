defmodule Sugary.AutoresearchLabTest do
  use ExUnit.Case

  alias Sugary.Protocol

  test "protocol schemas validate required fields" do
    assert_raise ArgumentError, fn ->
      Protocol.ReviewClaim.new(%{})
    end

    claim =
      Protocol.ReviewClaim.new(%{
        id: "claim-1",
        claim: "A claim",
        category: "bug",
        severity: "high",
        confidence: 0.9,
        path: "src/a.ex",
        introduced_by_pr: true,
        evidence: [],
        dedupe_key: "claim-1",
        source: %{method: "test"}
      })

    assert claim.id == "claim-1"
  end

  test "fixture loader loads local and agent-written suites" do
    local = Sugary.Fixtures.load_suite!("local-fixtures")
    agent = Sugary.Fixtures.load_suite!("agent-written-pr")

    assert length(local) == 6
    assert length(agent) == 6
    assert Enum.any?(local, &(&1.id == "null-guard"))
    assert Enum.any?(agent, &(&1.id == "hallucinated-api"))
  end

  test "review input bundle enforces no oracle leakage" do
    bench_case = Sugary.Fixtures.load_suite!("local-fixtures") |> hd()
    method = Sugary.Methods.get!("a-diff-only-single-shot")
    input = Sugary.Fixtures.input_bundle(bench_case, method)
    json = Sugary.Json.encode!(input)

    refute String.contains?(json, "oracle")
    refute String.contains?(json, "expectedClaims")
    refute String.contains?(json, "knownNonIssues")
    refute String.contains?(json, "final-review")
  end

  test "golden harness reviewers exercise scoring paths" do
    [bench_case] =
      Enum.filter(Sugary.Fixtures.load_suite!("local-fixtures"), &(&1.id == "duplicate-claims"))

    method = Sugary.Methods.get!("golden-duplicate-reviewer")
    result = Sugary.Pipeline.run_case(bench_case, method)
    score = Sugary.Scorer.score(method.id, [result])
    failures = Sugary.Scorer.failures(method.id, [result])

    assert score.hits == 1
    assert score.noise == 1
    assert Enum.any?(failures, &(&1.category == "duplicate_comment"))
  end

  test "failure analyzer classifies preexisting false positives" do
    [bench_case] =
      Enum.filter(Sugary.Fixtures.load_suite!("local-fixtures"), &(&1.id == "preexisting-bug"))

    method = Sugary.Methods.get!("a-diff-only-single-shot")
    result = Sugary.Pipeline.run_case(bench_case, method)
    failures = Sugary.Scorer.failures(method.id, [result])

    assert Enum.any?(failures, &(&1.category == "preexisting_bug"))
  end

  test "manifest parser reads experiment methods" do
    manifest = Sugary.Toml.parse_file!("experiments/pcrs-first-ablation.toml")

    assert manifest.id == "pcrs-first-ablation"
    assert manifest.suite == "local-fixtures"
    assert Enum.any?(manifest.methods, &(&1["id"] == "golden-perfect-reviewer"))
  end

  test "report generation produces lab-success language without theory validation" do
    score =
      Protocol.Scorecard.new(%{
        method_id: "golden-perfect-reviewer",
        cases: 1,
        expected_claims: 1,
        published_claims: 1,
        hits: 1,
        valid_suggestions: 0,
        noise: 0,
        suppressed_true_claims: 0,
        precision: 1.0,
        recall: 1.0,
        f1: 1.0,
        usefulness: 1.0,
        snr: 1.0,
        avg_comments_per_pr: 1.0,
        cost: 0.0,
        latency_ms: 1
      })

    manifest =
      Protocol.ExperimentManifest.new(%{id: "test", suite: "local-fixtures", methods: []})

    report =
      Sugary.Reporter.render_report(manifest, [
        %{
          method: %{id: "golden-perfect-reviewer", class: "harness_test"},
          score: score,
          failures: []
        }
      ])

    assert report =~ "Lab success"
    assert report =~ "does not validate PCRS"
  end
end

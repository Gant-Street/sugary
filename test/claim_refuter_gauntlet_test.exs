defmodule Sugary.ClaimRefuterGauntletTest do
  use ExUnit.Case

  test "zero-refutation replay exactly preserves the source policy" do
    root =
      Path.join(
        System.tmp_dir!(),
        "sugary-refuter-gauntlet-#{System.unique_integer([:positive])}"
      )

    bench = Path.join(root, "bench")
    source = Path.join(root, "source")
    materialization = Path.join(root, "materialization")
    output = Path.join(root, "output")
    File.mkdir_p!(bench)
    File.mkdir_p!(Path.join(materialization, "cases"))

    Sugary.Json.write!(Path.join(bench, "case.json"), %{
      id: "case",
      repo: "example/repo",
      title: "Fixture PR",
      body: "",
      diff: "+def risky(), do: :error",
      changed_files: ["src/example.ex"],
      expectedClaims: [
        %{
          id: "defect",
          description: "The new risky function always returns an error.",
          category: "bug",
          severity: "high",
          path: "src/example.ex",
          line: 1
        }
      ],
      knownNonIssues: []
    })

    case_id = "martian-offline-1-case"

    claim = %{
      id: "claim-1",
      claim: "The new risky function always returns an error.",
      category: "bug",
      severity: "high",
      confidence: 0.9,
      path: "src/example.ex",
      start_line: 1,
      end_line: 1,
      introduced_by_pr: true,
      evidence: [%{type: "static", tier: 3, strength: "strong", summary: "Direct return."}],
      failure_path: ["caller invokes risky", "risky returns error"],
      suggested_fix: "Return the expected value.",
      suggested_test: "Assert the successful result.",
      dedupe_key: "defect",
      source: %{method: "fixture"},
      publish_decision: "publish"
    }

    for policy <- ["online-qualified-max2-t70", "online-qualified-max1-t55"] do
      Sugary.Json.write!(Path.join([source, policy, "claims", "#{case_id}.json"]), [claim])
    end

    score = %{
      cases: 1,
      expected_claims: 1,
      published_claims: 1,
      hits: 1,
      noise: 0,
      precision: 1.0,
      recall: 1.0,
      f1: 1.0,
      usefulness: 1.0,
      snr: 1.0,
      avg_comments_per_pr: 1.0
    }

    Sugary.Json.write!(Path.join(source, "policy-scorecards.json"), [
      %{id: "online-qualified-max2-t70", score: score},
      %{id: "online-qualified-max1-t55", score: score}
    ])

    previous = System.get_env("MARTIAN_BENCH_DIR")
    System.put_env("MARTIAN_BENCH_DIR", bench)

    on_exit(fn ->
      if previous,
        do: System.put_env("MARTIAN_BENCH_DIR", previous),
        else: System.delete_env("MARTIAN_BENCH_DIR")

      File.rm_rf!(root)
    end)

    run =
      Sugary.ClaimRefuterGauntlet.run!(
        source_run: source,
        materialization_run: materialization,
        output_root: output,
        claim_limit: 0,
        limit: 1,
        id: "zero-refutation"
      )

    reports = Sugary.Json.read!(Path.join(run, "policy-scorecards.json"))

    assert Enum.all?(reports, &(&1["score"]["f1"] == 1.0))
    assert Enum.all?(reports, &(&1["score"]["hits"] == 1))
    assert Enum.all?(reports, &(&1["score"]["noise"] == 0))
  end
end

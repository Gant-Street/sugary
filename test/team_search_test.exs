defmodule Sugary.TeamSearchTest do
  use ExUnit.Case

  @pack_path "reviewer-packs/baseline-pack-v0.toml"

  setup_all do
    run_dir =
      Sugary.TeamSearch.run!(
        @pack_path,
        "agent-written-fixtures",
        max_team_size: 3
      )

    on_exit(fn -> File.rm_rf(run_dir) end)
    {:ok, run_dir: run_dir}
  end

  defp read!(run_dir, file), do: run_dir |> Path.join(file) |> Sugary.Json.read!()

  defp reviewer(scorecards, id), do: Enum.find(scorecards, &(&1["id"] == id))

  test "reviewer pack parsing and capability tags" do
    pack = Sugary.TeamSearch.load_pack!(@pack_path)

    assert pack.id == "baseline-pack-v0"
    assert length(pack.reviewers) == 8

    security = Enum.find(pack.reviewers, &(&1["id"] == "security-specialist-reviewer"))
    assert security["capabilities"] == ["security", "auth"]
  end

  test "team subset generation includes individuals, pairs, teams of three, and full team" do
    pack = Sugary.TeamSearch.load_pack!(@pack_path)
    subsets = Sugary.TeamSearch.reviewer_subsets(pack.reviewers, 3)

    assert length(subsets) == 93
    assert Enum.count(subsets, &(length(&1) == 1)) == 8
    assert Enum.count(subsets, &(length(&1) == 2)) == 28
    assert Enum.count(subsets, &(length(&1) == 3)) == 56
    assert Enum.count(subsets, &(length(&1) == 8)) == 1
  end

  test "best individual, best pair, and best team of 3 are calculated", %{run_dir: run_dir} do
    summary = read!(run_dir, "complementarity-summary.json")

    assert summary["best_single_reviewer"]["id"] == "symbol-graph-reviewer"
    assert summary["best_single_reviewer"]["score"]["f1"] == 1.0
    assert summary["best_pair"]["size"] == 2
    assert summary["best_team_of_3"]["size"] == 3
    assert summary["full_team"]["full_team"] == true
  end

  test "unique and duplicate hit attribution are reported", %{run_dir: run_dir} do
    scorecards = read!(run_dir, "reviewer-scorecards.json")
    symbol = reviewer(scorecards, "symbol-graph-reviewer")
    static = reviewer(scorecards, "static-analysis-reviewer")

    assert symbol["unique_hits"] == 6
    assert static["duplicate_hits"] == 2
  end

  test "oracle union upper bound and avoidable noise are written", %{run_dir: run_dir} do
    oracle = read!(run_dir, "oracle-union-upper-bound.json")
    summary = read!(run_dir, "complementarity-summary.json")

    assert oracle["hits"] == 6
    assert oracle["f1"] == 1.0
    assert summary["avoidable_noise_from_union"] == 0
  end

  test "team promotion policy rejects non-complementary teams", %{run_dir: run_dir} do
    promotion = read!(run_dir, "promotion.json")

    assert promotion["promoted_team"] == nil

    assert promotion["summary"] ==
             "No team promoted. Best individual reviewer remains the default."
  end

  test "complementarity report is generated", %{run_dir: run_dir} do
    report = File.read!(Path.join(run_dir, "report.md"))

    assert report =~ "Reviewer Complementarity"
    assert report =~ "Team Search"
    assert report =~ "Fixture Coverage Matrix"
    assert report =~ "No team promoted"
  end

  test "fixture coverage matrix shows reviewer coverage", %{run_dir: run_dir} do
    coverage = read!(run_dir, "coverage-matrix.json")

    route =
      Enum.find(
        coverage,
        &(&1["case_id"] == "weak-auth-generated-route" and
            &1["expected_claim"] == "weak-auth-generated-route")
      )

    assert route["reviewers"]["security-specialist-reviewer"] == true
    assert route["reviewers"]["diff-only-baseline"] == false
  end

  test "command reviewer fixtures receive no oracle data" do
    pack = Sugary.TeamSearch.load_pack!(@pack_path)
    [bench_case | _] = Sugary.Fixtures.load_suite!("agent-written-fixtures")

    pack.reviewers
    |> Enum.filter(&(&1["type"] == "command"))
    |> Enum.each(fn reviewer ->
      [script] = reviewer["args"]
      source = File.read!(script)

      refute source =~ "fixtures/review"
      assert source =~ "oracle leaked"

      method = Sugary.Methods.from_team_reviewer(reviewer)
      input = Sugary.Fixtures.input_bundle(bench_case, method)
      result = Sugary.CommandReviewer.run(method, input)

      assert result.errors == []
    end)
  end

  test "capability tags appear in reviewer scorecards", %{run_dir: run_dir} do
    scorecards = read!(run_dir, "reviewer-scorecards.json")

    contract = reviewer(scorecards, "integration-contract-reviewer")
    assert contract["capabilities"] == ["contract", "schema"]
  end
end

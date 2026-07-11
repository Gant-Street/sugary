defmodule Sugary.IncumbentLadderTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  @trust "posterior-max1-plus-source5-qualified-triad-budget52"
  @qualified "qualified-f1-judge-risk-budget84-max3"
  @diagnostic "raw-recall-diagnostic-budget160-deduped-max6"
  @online "online-qualified-max2-t70"

  setup do
    source =
      Path.join(
        System.tmp_dir!(),
        "sugary-incumbent-source-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(source)

    output_root =
      Path.join(
        System.tmp_dir!(),
        "sugary-incumbent-output-#{System.unique_integer([:positive])}"
      )

    score = fn id, f1, precision, recall, snr, hits, noise, comments ->
      %{
        id: id,
        policy: %{mode: id},
        score: %{
          cases: 50,
          f1: f1,
          precision: precision,
          recall: recall,
          usefulness: precision,
          snr: snr,
          hits: hits,
          noise: noise,
          published_claims: comments,
          avg_comments_per_pr: comments / 50
        }
      }
    end

    Sugary.Json.write!(Path.join(source, "policy-scorecards.json"), [
      score.(@trust, 0.46, 0.84, 0.32, 5.5, 44, 8, 52),
      score.(@online, 0.516, 0.724, 0.401, 2.62, 55, 21, 76)
      |> put_in([:policy, :mode], "online_qualified_f1"),
      score.(@qualified, 0.552, 0.726, 0.445, 2.65, 61, 23, 84),
      score.(@diagnostic, 0.595, 0.566, 0.628, 1.30, 86, 66, 152)
    ])

    Sugary.Json.write!(Path.join(source, "candidate-pool.json"), %{
      expected_claims: 137,
      pool_hits: 101,
      oracle_recall: 101 / 137,
      raw_claims: 1184,
      merged_candidates: 340
    })

    Sugary.Json.write!(Path.join(source, "decision.json"), %{
      trust_default: @trust,
      qualified_f1: @qualified,
      raw_f1_diagnostic: @diagnostic
    })

    on_exit(fn ->
      File.rm_rf!(source)
      File.rm_rf!(output_root)
    end)

    %{source: source, output_root: output_root}
  end

  test "builds a locked incumbent ladder from a publisher run", %{
    source: source,
    output_root: output_root
  } do
    out =
      Sugary.IncumbentLadder.report!(
        source_run: source,
        output_root: output_root,
        id: "incumbent-ladder-test",
        target_f1: 0.70
      )

    report = Sugary.Json.read!(Path.join(out, "incumbent-ladder.json"))

    assert report["target"]["f1"] == 0.70
    assert report["incumbents"]["online_product"]["policy_id"] == @online
    assert report["incumbents"]["offline_qualified_f1"]["policy_id"] == @qualified
    assert report["gaps"]["online_product_f1_to_target"] == 0.184
    assert report["gaps"]["qualified_f1_to_target"] == 0.148
    assert report["candidate_pool"]["missing_expected_claims"] == 36
    assert report["diagnosis"] =~ "verification and ranking"
    assert File.read!(Path.join(out, "incumbent-ladder.md")) =~ "F1 > 70.0%"
  end

  test "CLI exposes incumbent reporting", %{source: source, output_root: output_root} do
    output =
      capture_io(fn ->
        Sugary.CLI.main([
          "incumbent",
          "report",
          "--source-run",
          source,
          "--output-root",
          output_root,
          "--id",
          "incumbent-ladder-cli-test",
          "--target-f1",
          "0.70"
        ])
      end)

    assert output =~ output_root
  end
end

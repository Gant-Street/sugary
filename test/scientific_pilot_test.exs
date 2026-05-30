defmodule Sugary.ScientificPilotTest do
  use ExUnit.Case

  import ExUnit.CaptureIO

  defp cleanup_run!(out_dir) do
    underlying =
      out_dir
      |> Path.join("underlying-run.txt")
      |> File.read!()
      |> String.trim()

    on_exit(fn ->
      File.rm_rf(out_dir)
      File.rm_rf(underlying)
    end)
  end

  defp tmp_file(name, body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-scientific-pilot-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, name)
    File.write!(path, body)
    path
  end

  test "direct pilot writes paired deltas, bootstrap intervals, and decision artifacts" do
    out_dir =
      Sugary.ScientificPilot.run!(%{
        "id" => "scientific-pilot-test",
        "suite" => "local-fixtures",
        "candidate" => "golden-perfect-reviewer",
        "baseline" => ["golden-missing-context-reviewer", "golden-noisy-reviewer"],
        "min-cases" => "1",
        "bootstrap-iterations" => "50",
        "require-positive-ci" => "false"
      })

    cleanup_run!(out_dir)

    decision = Sugary.Json.read!(Path.join(out_dir, "decision.json"))
    bootstrap = Sugary.Json.read!(Path.join(out_dir, "bootstrap.json"))
    report = File.read!(Path.join(out_dir, "scientific-pilot-report.md"))
    deltas = File.read!(Path.join(out_dir, "paired-deltas.jsonl"))

    assert decision["decision"] == "promote_to_locked_workflow"
    assert decision["checks"]["positive_primary_delta"] == true
    assert bootstrap["f1"]["low"] <= bootstrap["f1"]["high"]
    assert bootstrap["cases"] > 0
    assert deltas =~ "case_id"
    assert report =~ "Scientific Pilot v0"
    assert report =~ "Bootstrap 95% Intervals"
  end

  test "pilot returns insufficient evidence when sample size is below the configured bar" do
    out_dir =
      Sugary.ScientificPilot.run!(%{
        "id" => "scientific-pilot-small-sample-test",
        "suite" => "local-fixtures",
        "candidate" => "golden-perfect-reviewer",
        "baseline" => ["golden-missing-context-reviewer"],
        "min-cases" => "999",
        "bootstrap-iterations" => "25"
      })

    cleanup_run!(out_dir)

    decision = Sugary.Json.read!(Path.join(out_dir, "decision.json"))
    analysis = Sugary.Json.read!(Path.join(out_dir, "analysis.json"))

    assert decision["decision"] == "insufficient_evidence"
    assert decision["checks"]["enough_cases"] == false
    assert analysis["sample_diagnostics"]["level"] == "too_small"
  end

  test "pilot can require a minimum primary delta and no added comments" do
    out_dir =
      Sugary.ScientificPilot.run!(%{
        "id" => "scientific-pilot-target-gate-test",
        "suite" => "local-fixtures",
        "candidate" => "golden-perfect-reviewer",
        "baseline" => ["golden-missing-context-reviewer"],
        "min-cases" => "1",
        "bootstrap-iterations" => "25",
        "require-positive-ci" => "false",
        "min-primary-delta" => "999.0",
        "max-added-comments-per-pr" => "-1.0"
      })

    cleanup_run!(out_dir)

    decision = Sugary.Json.read!(Path.join(out_dir, "decision.json"))

    assert decision["decision"] == "reject"
    assert decision["checks"]["primary_delta_target"] == false
    assert decision["checks"]["no_added_comments"] == false
    assert decision["reason"] =~ "primary paired delta missed target"
    assert decision["reason"] =~ "candidate increased average comments per PR"
  end

  test "pilot can run from an experiment manifest and compare named reports" do
    manifest =
      tmp_file(
        "pilot.toml",
        """
        id = "scientific-pilot-manifest-test"
        suite = "local-fixtures"

        [[methods]]
        id = "candidate-perfect"
        reviewer = "golden-perfect-reviewer"

        [[methods]]
        id = "baseline-missing"
        reviewer = "golden-missing-context-reviewer"

        [[methods]]
        id = "baseline-noisy"
        reviewer = "golden-noisy-reviewer"

        [[methods]]
        id = "unused-extra"
        reviewer = "golden-duplicate-reviewer"
        """
      )

    out_dir =
      Sugary.ScientificPilot.run!(%{
        "id" => "scientific-pilot-manifest-test",
        "experiment" => manifest,
        "candidate" => "candidate-perfect",
        "baseline" => ["baseline-missing", "baseline-noisy"],
        "min-cases" => "1",
        "bootstrap-iterations" => "30",
        "require-positive-ci" => "false"
      })

    cleanup_run!(out_dir)

    scorecards = Sugary.Json.read!(Path.join(out_dir, "method-scorecards.json"))
    decision = Sugary.Json.read!(Path.join(out_dir, "decision.json"))

    assert Enum.map(scorecards, & &1["method_id"]) == [
             "candidate-perfect",
             "baseline-missing",
             "baseline-noisy"
           ]

    refute Enum.any?(scorecards, &(&1["method_id"] == "unused-extra"))
    assert decision["decision"] in ["promote_to_locked_workflow", "reject"]
  end

  test "CLI dispatches scientific pilot" do
    output =
      capture_io(fn ->
        Sugary.CLI.main([
          "scientific",
          "pilot",
          "--id",
          "scientific-pilot-cli-test",
          "--suite",
          "local-fixtures",
          "--candidate",
          "golden-perfect-reviewer",
          "--baseline",
          "golden-missing-context-reviewer",
          "--min-cases",
          "1",
          "--bootstrap-iterations",
          "10",
          "--require-positive-ci",
          "false"
        ])
      end)

    out_dir = String.trim(output)
    cleanup_run!(out_dir)

    assert out_dir =~ ".sugary/research/scientific-pilots/"
    assert File.exists?(Path.join(out_dir, "scientific-pilot-report.md"))
  end
end

defmodule Sugary.PromotionTest do
  use ExUnit.Case

  @ledger ".sugary/research/holdout-ledger.jsonl"

  setup_all do
    dev_run = Sugary.Runner.run_experiment_file!("experiments/pcrs-hard-fixtures-v0.toml")
    on_exit(fn -> File.rm_rf(dev_run) end)
    {:ok, dev_run: dev_run}
  end

  setup do
    File.rm(@ledger)
    :ok
  end

  defp lock_path(id), do: "promotions/#{id}.toml"
  defp promotion_dir(id), do: ".sugary/research/promotions/#{id}"

  defp lock!(dev_run, id, attrs \\ %{}) do
    out = lock_path(id)

    opts =
      Map.merge(
        %{
          "candidate" => "teams/hard-specialist-team.toml",
          "baseline-method" => ["baseline-diff-only", "symbol-graph-reflexion"],
          "baseline-team" => ["teams/proof-carrying-team.toml"],
          "suite" => "agent-written-hard-fixtures",
          "dev-run" => dev_run,
          "out" => out
        },
        attrs
      )

    on_exit(fn ->
      File.rm(out)
      File.rm_rf(promotion_dir(Path.basename(out, ".toml")))
    end)

    Sugary.Promotion.lock!(opts)
  end

  defp read_json!(dir, file), do: dir |> Path.join(file) |> Sugary.Json.read!()

  defp tmp_file(name, body) do
    dir =
      Path.join(System.tmp_dir!(), "sugary-promotion-test-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, name)
    File.write!(path, body)
    path
  end

  test "lock file creation records manifests, hashes, suite, dev run, and thresholds", %{
    dev_run: dev_run
  } do
    id = "promotion-lock-test-#{System.unique_integer([:positive])}"
    path = lock!(dev_run, id)
    lock = Sugary.Toml.parse_file_raw!(path)

    assert lock["id"] == id
    assert lock["candidate_id"] == "hard-specialist-team"
    assert lock["candidate_type"] == "team"
    assert lock["baseline_methods"] == ["baseline-diff-only", "symbol-graph-reflexion"]
    assert lock["baseline_team_ids"] == ["proof-carrying-team"]
    assert lock["suite"] == "agent-written-hard-fixtures"
    assert lock["dev_split"] == "dev"
    assert lock["dev_run"] == dev_run
    assert String.length(lock["candidate_manifest_hash"]) == 64
    assert String.length(lock["fixture_suite_hash"]) == 64
    assert lock["min_snr_ratio"] == 0.9
  end

  test "manifest and suite hashing are deterministic and sensitive to content changes" do
    path = tmp_file("candidate.toml", File.read!("teams/hard-specialist-team.toml"))
    first = Sugary.Promotion.manifest_hash(path)
    second = Sugary.Promotion.manifest_hash(path)
    File.write!(path, "\n# changed\n", [:append])
    changed = Sugary.Promotion.manifest_hash(path)

    assert first == second
    assert first != changed
    assert String.length(Sugary.Promotion.fixture_suite_hash("agent-written-hard-fixtures")) == 64
  end

  test "promotion run executes locked holdout candidate and baselines", %{dev_run: dev_run} do
    id = "promotion-run-test-#{System.unique_integer([:positive])}"
    lock = lock!(dev_run, id)
    dir = Sugary.Promotion.run!(lock, split: "holdout")

    decision = read_json!(dir, "decision.json")
    scorecard = read_json!(dir, "promotion-scorecard.json")
    bootstrap = read_json!(dir, "bootstrap.json")
    leakage = read_json!(dir, "leakage-report.json")

    assert decision["decision"] == "promote"
    assert decision["unique_hits_over_baseline"] >= 1
    assert scorecard["candidate"]["id"] == "hard-specialist-team"

    assert scorecard["baseline_winner"]["id"] in [
             "symbol-graph-reflexion",
             "proof-carrying-team",
             "baseline-diff-only"
           ]

    assert scorecard["generalization_gap"]["f1"] >= 0.0
    assert bootstrap["candidate"]["f1"]["low"] <= bootstrap["candidate"]["f1"]["high"]
    assert leakage["fatal?"] == false
    assert File.exists?(Path.join(dir, "holdout-run/report.md"))
    assert File.exists?(Path.join(dir, "baseline-runs/locked-baselines/report.md"))
    assert File.exists?(Path.join(dir, "generalization-report.md"))
  end

  test "changed candidate manifest invalidates promotion before holdout execution", %{
    dev_run: dev_run
  } do
    team_path =
      tmp_file("hard-specialist-team.toml", File.read!("teams/hard-specialist-team.toml"))

    id = "promotion-changed-manifest-test-#{System.unique_integer([:positive])}"
    lock = lock!(dev_run, id, %{"candidate" => team_path})
    File.write!(team_path, "\n# changed after lock\n", [:append])

    dir = Sugary.Promotion.run!(lock, split: "holdout")
    decision = read_json!(dir, "decision.json")
    leakage = read_json!(dir, "leakage-report.json")

    assert decision["decision"] == "invalid_due_to_changed_manifest"

    assert Enum.any?(
             leakage["fatal_reasons"],
             &String.contains?(&1, "candidate manifest changed")
           )

    refute File.exists?(Path.join(dir, "holdout-run"))
  end

  test "changed suite hash invalidates promotion", %{dev_run: dev_run} do
    id = "promotion-changed-suite-test-#{System.unique_integer([:positive])}"
    lock = lock!(dev_run, id)

    body =
      lock
      |> File.read!()
      |> String.replace(
        ~r/fixture_suite_hash = "[^"]+"/,
        ~s(fixture_suite_hash = "bad-suite-hash")
      )

    File.write!(lock, body)

    dir = Sugary.Promotion.run!(lock, split: "holdout")
    decision = read_json!(dir, "decision.json")
    leakage = read_json!(dir, "leakage-report.json")

    assert decision["decision"] == "invalid_due_to_changed_manifest"
    assert Enum.any?(leakage["fatal_reasons"], &String.contains?(&1, "fixture suite changed"))
  end

  test "repeated holdout runs append ledger and warn", %{dev_run: dev_run} do
    id = "promotion-ledger-test-#{System.unique_integer([:positive])}"
    lock = lock!(dev_run, id)

    Sugary.Promotion.run!(lock, split: "holdout")
    dir = Sugary.Promotion.run!(lock, split: "holdout")

    leakage = read_json!(dir, "leakage-report.json")
    ledger = File.read!(@ledger) |> String.split("\n", trim: true)

    assert length(ledger) == 2
    assert Enum.any?(leakage["warnings"], &String.contains?(&1, "already been run"))
  end

  test "promotion decision logic can reject regressions" do
    candidate =
      score_report("candidate", %{
        f1: 0.4,
        usefulness: 1.0,
        recall: 0.3,
        snr: 0.5,
        noise: 2,
        avg_comments_per_pr: 4.0
      })

    baseline =
      score_report("baseline", %{
        f1: 0.7,
        usefulness: 1.0,
        recall: 0.7,
        snr: 2.0,
        noise: 0,
        avg_comments_per_pr: 1.0
      })

    decision =
      Sugary.Promotion.promotion_decision(
        candidate,
        baseline,
        %{fixture_saturated: false},
        %{fatal?: false, fatal_reasons: []},
        %{fatal?: false, warnings: []},
        %{
          min_snr_ratio: 0.9,
          max_comments_per_pr: 3.0,
          min_unique_hits: 1,
          material_recall_regression: 0.05,
          max_category_regression: 0.35,
          min_holdout_cases: 1
        }
      )

    assert decision.decision == "reject"
    assert decision.reason =~ "candidate did not beat best locked baseline"
  end

  defp score_report(id, attrs) do
    score =
      Sugary.Protocol.Scorecard.new(%{
        method_id: id,
        cases: 3,
        expected_claims: 3,
        published_claims: 1,
        hits: 1,
        valid_suggestions: 0,
        noise: attrs.noise,
        suppressed_true_claims: 0,
        precision: attrs.usefulness,
        recall: attrs.recall,
        f1: attrs.f1,
        usefulness: attrs.usefulness,
        snr: attrs.snr,
        avg_comments_per_pr: attrs.avg_comments_per_pr,
        cost: 0.0,
        latency_ms: 1
      })

    %{method: %{id: id, class: "research"}, score: score, failures: [], results: []}
  end
end

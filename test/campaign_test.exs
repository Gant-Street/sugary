defmodule Sugary.CampaignTest do
  use ExUnit.Case

  alias Sugary.Protocol

  @campaign "campaigns/evidence-refutation-campaign-v0.toml"

  defp score(id, attrs) do
    Protocol.Scorecard.new(
      Map.merge(
        %{
          method_id: id,
          cases: 4,
          expected_claims: 4,
          published_claims: 1,
          hits: 1,
          valid_suggestions: 0,
          noise: 0,
          suppressed_true_claims: 0,
          precision: 1.0,
          recall: 0.25,
          f1: 0.4,
          usefulness: 1.0,
          snr: 1.0,
          avg_comments_per_pr: 0.25,
          cost: 0.0,
          latency_ms: 1
        },
        attrs
      )
    )
  end

  defp entry(id, role, attrs) do
    attrs = Map.new(attrs)
    score_attrs = Map.get(attrs, :score, %{})

    %{
      id: id,
      role: role,
      type: Map.get(attrs, :type, "method"),
      method: Map.get(attrs, :method, %{"id" => id, "context" => "symbol_graph_stub"}),
      run_dir: ".sugary/research/runs/#{id}",
      score: score(id, score_attrs),
      research_utility: Map.get(attrs, :research_utility, 1.0),
      failures: Map.get(attrs, :failures, []),
      completed_at: Map.get(attrs, :completed_at, "2026-05-25T00:00:00Z")
    }
  end

  defp temp_campaign(body) do
    path =
      Path.join(
        System.tmp_dir!(),
        "sugary-campaign-test-#{System.unique_integer([:positive])}.toml"
      )

    File.write!(path, body)
    on_exit(fn -> File.rm(path) end)
    path
  end

  test "campaign manifest parses bounded search schema" do
    manifest = Sugary.Campaign.load_manifest!(@campaign)

    assert manifest.id == "evidence-refutation-campaign-v0"
    assert manifest.split == "dev"
    assert manifest.primary_metric == "research_utility"

    assert manifest.fixed_baselines["method_ids"] == [
             "baseline-diff-only",
             "symbol-graph-reflexion"
           ]

    assert manifest.search_space["contexts"] == ["changed_files", "symbol_graph_stub"]
    assert manifest.budget["max_experiments"] == 12
  end

  test "queue generation starts with baselines and includes architecture variants" do
    manifest = Sugary.Campaign.load_manifest!(@campaign)
    queue = Sugary.Campaign.generate_queue(manifest)

    assert [%{role: "baseline"}, %{role: "baseline"} | _] = queue
    assert Enum.any?(queue, &(&1.id == "baseline-baseline-diff-only"))

    assert Enum.any?(
             queue,
             &(&1.type == "method" and
                 get_in(&1, [:method, "refutation"]) == "generic_refuter_stub")
           )

    assert Enum.any?(queue, &(&1.type == "team"))
  end

  test "next variant runs baselines first, then targets failure clusters" do
    manifest = Sugary.Campaign.load_manifest!(@campaign)
    queue = Sugary.Campaign.generate_queue(manifest)

    assert %{role: "baseline"} = Sugary.Campaign.next_variant(queue, [])

    queue =
      Enum.map(queue, fn item ->
        if item.role == "baseline", do: %{item | status: "completed"}, else: item
      end)

    leaderboard = [
      entry("baseline", "baseline",
        failures: [%{type: "false_positive", category: "false_positive"}]
      )
    ]

    next = Sugary.Campaign.next_variant(queue, leaderboard)
    assert get_in(next, [:method, "refutation"]) == "generic_refuter_stub"
  end

  test "leaderboard ranking applies guardrails against best baseline" do
    manifest = Sugary.Campaign.load_manifest!(@campaign)

    baseline =
      entry("baseline", "baseline",
        research_utility: 2.0,
        score: %{recall: 0.75, snr: 4.0, avg_comments_per_pr: 0.5}
      )

    noisy =
      entry("noisy", "search",
        research_utility: 3.0,
        score: %{recall: 0.25, snr: 0.1, avg_comments_per_pr: 4.0, noise: 3}
      )

    [first | ranked] = Sugary.Campaign.rank_leaderboard([baseline, noisy], manifest)
    ranked_noisy = Enum.find([first | ranked], &(&1.id == "noisy"))

    assert first.id == "noisy"
    assert ranked_noisy.guardrails[:pass?] == false
    assert "recall_ok failed" in ranked_noisy.guardrails.warnings
    assert "snr_ok failed" in ranked_noisy.guardrails.warnings
    assert "comments_ok failed" in ranked_noisy.guardrails.warnings
  end

  test "final decision recommends candidates only after baseline improvement and guardrail pass" do
    manifest = Sugary.Campaign.load_manifest!(@campaign)

    baseline = entry("baseline", "baseline", research_utility: 1.0)

    candidate =
      entry("candidate", "search",
        research_utility: 2.0,
        score: %{hits: 2, recall: 0.5, f1: 0.67, snr: 2.0}
      )

    leaderboard = Sugary.Campaign.rank_leaderboard([baseline, candidate], manifest)
    decision = Sugary.Campaign.final_decision(manifest, [], leaderboard, %{stop_reason: nil})

    assert decision.decision == "recommend_candidate"
    assert decision.candidate_id == "candidate"
  end

  test "final decision detects saturated baseline" do
    manifest = Sugary.Campaign.load_manifest!(@campaign)

    baseline =
      entry("baseline", "baseline",
        research_utility: 4.0,
        score: %{expected_claims: 4, hits: 4, recall: 1.0, noise: 0}
      )

    leaderboard = Sugary.Campaign.rank_leaderboard([baseline], manifest)
    decision = Sugary.Campaign.final_decision(manifest, [], leaderboard, %{stop_reason: nil})

    assert decision.decision == "needs_harder_fixtures"
  end

  test "dry run writes queue and report without running experiments" do
    dir = Sugary.Campaign.run!(@campaign, dry_run: true)
    on_exit(fn -> File.rm_rf(dir) end)

    state = Sugary.Json.read!(Path.join(dir, "state.json"))
    queue = Sugary.Json.read!(Path.join(dir, "queue.json"))
    report = File.read!(Path.join(dir, "campaign-report.md"))

    assert state["status"] == "dry_run"
    assert length(queue) > 2
    assert report =~ "Campaign Report"
    assert File.exists?(Path.join(dir, "completed-runs.jsonl"))
    assert File.read!(Path.join(dir, "completed-runs.jsonl")) == ""
  end

  test "campaign run checkpoints, enforces experiment limits, and resumes" do
    dir = Sugary.Campaign.run!(@campaign, limit_experiments: 1)
    on_exit(fn -> File.rm_rf(dir) end)

    state = Sugary.Json.read!(Path.join(dir, "state.json"))
    leaderboard = Sugary.Json.read!(Path.join(dir, "leaderboard.json"))

    assert state["stop_reason"] == "max_experiments"
    assert length(leaderboard) == 1

    resumed = Sugary.Campaign.run!(@campaign, resume: true, limit_experiments: 2)
    assert resumed == dir

    resumed_state = Sugary.Json.read!(Path.join(dir, "state.json"))
    resumed_leaderboard = Sugary.Json.read!(Path.join(dir, "leaderboard.json"))

    assert resumed_state["stop_reason"] == "max_experiments"
    assert length(resumed_leaderboard) == 2
    assert File.exists?(Path.join(dir, "completed-runs.jsonl"))
  end

  test "holdout campaign is rejected before execution" do
    path =
      temp_campaign("""
      id = "holdout-campaign-test"
      suite = "agent-written-hard-fixtures"
      split = "holdout"

      [search_space]
      contexts = ["diff_only"]
      """)

    dir = Sugary.Campaign.run!(path)
    on_exit(fn -> File.rm_rf(dir) end)

    state = Sugary.Json.read!(Path.join(dir, "state.json"))

    assert state["status"] == "invalid"
    assert state["decision"]["decision"] == "invalid_due_to_leakage"
    assert state["stop_reason"] == "holdout_split"
  end
end

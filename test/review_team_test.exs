defmodule Sugary.ReviewTeamTest do
  use ExUnit.Case

  defp bench_case(id) do
    Sugary.Fixtures.load_suite!("local-fixtures")
    |> Enum.find(&(&1.id == id))
  end

  defp write_tmp(name, body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-review-team-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, name)
    File.write!(path, body)
    path
  end

  defp team_method(path, id \\ "test-team") do
    %{id: id, type: "team", team_path: path, class: "team"}
  end

  defp run_team(path, case_id \\ "missing-auth") do
    Sugary.Teams.run_case(bench_case(case_id), team_method(path))
  end

  defp method_team(policy \\ "continue", reviewer_method \\ "baseline-changed-files") do
    write_tmp(
      "method-team.toml",
      """
      id = "method-team"
      failure_policy = "#{policy}"
      merge_strategy = "dedupe_by_key_location_and_claim"
      max_published_claims = 3

      [[reviewers]]
      id = "method-reviewer"
      type = "method"
      method = "#{reviewer_method}"
      """
    )
  end

  defp invalid_command_script do
    write_tmp("invalid_reviewer.exs", ~S|IO.write("not json")|)
  end

  defp command_claim_script(id, dedupe_key, path, claim, extra \\ "") do
    write_tmp(
      "#{id}.exs",
      """
      _input = IO.read(:stdio, :eof)
      #{extra}

      result = %{
        reviewer_id: "#{id}",
        method_id: "#{id}",
        class: "research",
        claims: [
          %{
            id: "#{id}-claim",
            claim: "#{claim}",
            category: "security",
            severity: "high",
            confidence: 0.7,
            path: "#{path}",
            start_line: 42,
            end_line: 42,
            introduced_by_pr: true,
            evidence: [
              %{
                type: "command_reviewer",
                tier: 4,
                strength: "medium",
                summary: "#{id} evidence"
              }
            ],
            dedupe_key: "#{dedupe_key}",
            source: %{method: "#{id}", class: "research"},
            publish_decision: "candidate"
          }
        ],
        cost: 0.0,
        latency_ms: 1,
        artifacts: [],
        errors: []
      }

      IO.write(:json.encode(result))
      """
    )
  end

  defp command_team(script_paths, policy \\ "continue") do
    reviewers =
      script_paths
      |> Enum.with_index(1)
      |> Enum.map(fn {script, index} ->
        """
        [[reviewers]]
        id = "command-#{index}"
        type = "command"
        command = "elixir"
        args = ["#{script}"]
        timeout_ms = 2000
        cwd = "."
        """
      end)
      |> Enum.join("\n")

    write_tmp(
      "command-team.toml",
      """
      id = "command-team"
      failure_policy = "#{policy}"
      merge_strategy = "dedupe_by_key_location_and_claim"
      max_published_claims = 3

      #{reviewers}
      """
    )
  end

  test "ReviewTeam manifest parsing" do
    team = Sugary.Teams.load!("teams/proof-carrying-team.toml")

    assert team.id == "proof-carrying-team"
    assert team.failure_policy == "continue"
    assert team.merge_strategy == "dedupe_by_key_location_and_claim"
    assert team.max_published_claims == 3
    assert length(team.reviewers) == 4
  end

  test "one-reviewer team runs through the existing reviewer interface" do
    result = run_team(method_team())

    assert length(result.team.reviewer_runs) == 1
    assert Enum.any?(result.final_claims, &(&1.dedupe_key == "admin-route-missing-auth"))
  end

  test "multi-reviewer team dedupes explicit dedupe_key and preserves provenance" do
    result = run_team("teams/default-local-team.toml")

    [claim] =
      Enum.filter(result.team.merged_claims, &(&1.dedupe_key == "admin-route-missing-auth"))

    assert get_in(claim, [:source, :agreement_count]) == 3
    assert get_in(claim, [:source, :provenance]) |> length() == 3
    assert Enum.all?(get_in(claim, [:source, :provenance]), &Map.has_key?(&1, :result_id))
  end

  test "reviewers execute sequentially in manifest order" do
    order_file =
      write_tmp("order.txt", "")
      |> tap(&File.rm!/1)

    first =
      command_claim_script(
        "first",
        "first-key",
        "src/one.ex",
        "First claim",
        ~s|File.write!("#{order_file}", "first\\n", [:append])|
      )

    second =
      command_claim_script(
        "second",
        "second-key",
        "src/two.ex",
        "Second claim",
        ~s|File.write!("#{order_file}", "second\\n", [:append])|
      )

    command_team([first, second]) |> run_team()

    assert File.read!(order_file) == "first\nsecond\n"
  end

  test "dedupe by location works when explicit dedupe_key is absent" do
    first =
      command_claim_script(
        "loc-a",
        "",
        "src/routes/admin.ts",
        "Generated admin route misses authorization."
      )

    second =
      command_claim_script(
        "loc-b",
        "",
        "src/routes/admin.ts",
        "Generated admin route misses authorization."
      )

    result = command_team([first, second]) |> run_team()
    [claim] = result.team.merged_claims

    assert claim.dedupe_key =~ "loc:src/routes/admin.ts:42:42:security:high"
    assert get_in(claim, [:source, :agreement_count]) == 2
  end

  test "continue failure policy isolates reviewer failures" do
    team_path =
      write_tmp(
        "continue-team.toml",
        """
        id = "continue-team"
        failure_policy = "continue"
        max_published_claims = 3

        [[reviewers]]
        id = "bad-command"
        type = "command"
        command = "elixir"
        args = ["#{invalid_command_script()}"]

        [[reviewers]]
        id = "method-reviewer"
        type = "method"
        method = "baseline-changed-files"
        """
      )

    result = run_team(team_path)

    assert Enum.any?(result.final_claims, &(&1.dedupe_key == "admin-route-missing-auth"))
    assert Enum.any?(result.reviewer_result.errors, &(&1.reason == "reviewer_failed"))
  end

  test "fail_team failure policy suppresses the whole team" do
    team_path =
      write_tmp(
        "fail-team.toml",
        """
        id = "fail-team"
        failure_policy = "fail_team"
        max_published_claims = 3

        [[reviewers]]
        id = "bad-command"
        type = "command"
        command = "elixir"
        args = ["#{invalid_command_script()}"]

        [[reviewers]]
        id = "method-reviewer"
        type = "method"
        method = "baseline-changed-files"
        """
      )

    result = run_team(team_path)

    assert result.final_claims == []
    assert [%{reason: "reviewer_failure"} | _] = result.reviewer_result.errors
  end

  test "require_at_least_one_success failure policy" do
    all_fail = command_team([invalid_command_script()], "require_at_least_one_success")
    failed = run_team(all_fail)

    assert failed.final_claims == []
    assert [%{reason: "no_successful_reviewers"} | _] = failed.reviewer_result.errors

    one_success =
      write_tmp(
        "one-success-team.toml",
        """
        id = "one-success-team"
        failure_policy = "require_at_least_one_success"
        max_published_claims = 3

        [[reviewers]]
        id = "bad-command"
        type = "command"
        command = "elixir"
        args = ["#{invalid_command_script()}"]

        [[reviewers]]
        id = "method-reviewer"
        type = "method"
        method = "baseline-changed-files"
        """
      )

    succeeded = run_team(one_success)
    assert Enum.any?(succeeded.final_claims, &(&1.dedupe_key == "admin-route-missing-auth"))
  end

  test "team score aggregation and reviewer-level contribution stats" do
    results =
      ["missing-auth", "null-guard"]
      |> Enum.map(
        &Sugary.Teams.run_case(
          bench_case(&1),
          team_method("teams/default-local-team.toml", "default-local-team")
        )
      )

    score = Sugary.Scorer.score("default-local-team", results)
    contributions = Sugary.Teams.contributions(results, score)

    assert score.hits == 2
    assert score.published_claims == 2
    assert length(contributions) == 3
    assert Enum.all?(contributions, &Map.has_key?(&1, :marginal_team_contribution))
  end

  test "team artifacts are written and team is usable from experiment manifest" do
    run_dir = Sugary.Runner.run_experiment_file!("experiments/review-team-v0.toml")
    on_exit(fn -> File.rm_rf(run_dir) end)

    team_dir = Path.join(run_dir, "proof-carrying-team")

    assert File.exists?(Path.join(team_dir, "team-manifest.toml"))
    assert File.exists?(Path.join(team_dir, "raw-claims.jsonl"))
    assert File.exists?(Path.join(team_dir, "merged-claims.jsonl"))
    assert File.exists?(Path.join(team_dir, "published-claims.jsonl"))
    assert File.exists?(Path.join(team_dir, "provenance.json"))
    assert File.exists?(Path.join(team_dir, "team-scorecard.json"))
    assert File.exists?(Path.join(team_dir, "reviewer-contributions.json"))
    assert File.exists?(Path.join(team_dir, "failures.jsonl"))
    assert File.exists?(Path.join(team_dir, "report.md"))
    assert Path.wildcard(Path.join([team_dir, "reviewer-results", "*.json"])) != []
  end

  test "command reviewer can run inside a team" do
    result =
      Sugary.Teams.run_case(
        bench_case("missing-auth"),
        team_method("teams/proof-carrying-team.toml", "proof-carrying-team")
      )

    assert Enum.any?(result.team.raw_claims, fn claim ->
             get_in(claim, [:source, :reviewer_id]) == "sample-command-reviewer"
           end)
  end
end

defmodule Sugary.ExternalReviewersTest do
  use ExUnit.Case

  alias Sugary.Protocol.ReviewInputBundle

  @pack "reviewer-packs/external-real-pack-v0.toml"

  setup do
    File.rm_rf(".sugary/research/replay-cache")
    :ok
  end

  defp input(diff \\ "hard_async_race_condition") do
    ReviewInputBundle.new(%{
      case_id: "external-test",
      suite: "agent-written-hard-fixtures",
      pr: %{title: "External reviewer test", body: ""},
      diff: diff,
      context: %{changed_files: ["src/preferences.ex", "test/parser_test.exs"]},
      method: %{id: "external-test"},
      metadata: %{tags: ["test"]}
    })
  end

  defp method(attrs \\ %{}) do
    Map.merge(
      %{
        id: "external-test-reviewer",
        type: "command",
        class: "research",
        command: "elixir",
        args: ["scripts/reviewers/generic_json_reviewer.exs"],
        timeout_ms: 5_000,
        cwd: ".",
        replay_mode: "live",
        cost_model: "free_local",
        requires_network: false,
        requires_secrets: []
      },
      Map.new(attrs)
    )
  end

  defp write_script(name, body) do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-external-reviewer-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    path = Path.join(dir, name)
    File.write!(path, body)
    path
  end

  defp env_script do
    write_script(
      "env_reviewer.exs",
      """
      _input = IO.read(:stdio, :eof)
      id = System.fetch_env!("SUGARY_TEST_CLAIM")

      IO.write(:json.encode(%{
        reviewer_id: "external-test-reviewer",
        method_id: "external-test-reviewer",
        class: "research",
        claims: [
          %{
            id: id,
            claim: "Claim " <> id,
            category: "bug",
            severity: "high",
            confidence: 0.8,
            path: "src/preferences.ex",
            start_line: 1,
            end_line: 1,
            introduced_by_pr: true,
            evidence: [%{type: "fixture", tier: 4, strength: "medium", summary: "env fixture"}],
            dedupe_key: id,
            source: %{method: "external-test-reviewer"},
            publish_decision: "candidate"
          }
        ],
        cost: 0.0,
        latency_ms: 1,
        artifacts: [],
        errors: []
      }))
      """
    )
  end

  defp first_artifact(result), do: result.artifacts |> List.first()

  test "external reviewer pack parses optional real tools and fixture reviewer" do
    pack = Sugary.ReviewerPacks.load!(@pack)

    assert pack.id == "external-real-pack-v0"
    assert length(pack.reviewers) >= 6

    semgrep = Enum.find(pack.reviewers, &(&1["id"] == "semgrep-json"))
    fixture = Enum.find(pack.reviewers, &(&1["id"] == "fixture-json-reviewer"))

    assert semgrep["enabled"] == false
    assert semgrep["required_executable"] == "semgrep"
    assert fixture["enabled"] == true
    assert fixture["cost_model"] == "free_local"
  end

  test "availability check reports available, disabled, missing executable, and missing env" do
    rows = Sugary.ExternalReviewers.check_pack!(@pack)

    assert Enum.find(rows, &(&1.id == "fixture-json-reviewer")).status == "available"
    assert Enum.find(rows, &(&1.id == "semgrep-json")).status == "skipped"

    missing_exe =
      Sugary.ExternalReviewers.availability_for_reviewer(%{
        "id" => "missing-tool",
        "enabled" => true,
        "required_executable" => "definitely-not-sugary-real"
      })

    missing_env =
      Sugary.ExternalReviewers.availability_for_reviewer(%{
        "id" => "missing-env",
        "enabled" => true,
        "required_executable" => "elixir",
        "requires_secrets" => ["SUGARY_MISSING_ENV_FOR_TEST"]
      })

    assert missing_exe.status == "skipped"
    assert missing_exe.reason =~ "missing definitely-not-sugary-real"
    assert missing_env.status == "skipped"
    assert missing_env.reason =~ "SUGARY_MISSING_ENV_FOR_TEST"
  end

  test "replay cache key is stable and changes with input or manifest" do
    base = method()
    key = Sugary.CommandReviewer.replay_cache_key(base, input())

    assert key == Sugary.CommandReviewer.replay_cache_key(base, input())

    refute key ==
             Sugary.CommandReviewer.replay_cache_key(
               base,
               input("hard_test_only_false_confidence")
             )

    refute key == Sugary.CommandReviewer.replay_cache_key(%{base | args: ["other.exs"]}, input())
  end

  test "cache-first uses replay when cache exists" do
    live = Sugary.CommandReviewer.run(%{method() | replay_mode: "live"}, input())
    replay = Sugary.CommandReviewer.run(%{method() | replay_mode: "cache-first"}, input())

    assert first_artifact(live).execution_mode == "live"
    assert first_artifact(replay).execution_mode == "replay"
    assert first_artifact(replay).cache_hit == true
    assert hd(replay.claims).dedupe_key == "async-race-condition"
  end

  test "replay-only skips when cache is missing" do
    result = Sugary.CommandReviewer.run(%{method() | replay_mode: "replay-only"}, input())

    assert result.claims == []
    assert [%{reason: "skipped", detail: "replay cache miss"}] = result.errors
    assert first_artifact(result).execution_mode == "skip"
  end

  test "refresh overwrites cache for same input and manifest shape" do
    script = env_script()

    first =
      Sugary.CommandReviewer.run(
        %{method(args: [script], env: ["SUGARY_TEST_CLAIM=first"]) | replay_mode: "live"},
        input()
      )

    refreshed =
      Sugary.CommandReviewer.run(
        %{method(args: [script], env: ["SUGARY_TEST_CLAIM=second"]) | replay_mode: "refresh"},
        input()
      )

    replay =
      Sugary.CommandReviewer.run(
        %{
          method(args: [script], env: ["SUGARY_TEST_CLAIM=second"])
          | replay_mode: "replay-only"
        },
        input()
      )

    miss =
      Sugary.CommandReviewer.run(
        %{
          method(args: [script], env: ["SUGARY_TEST_CLAIM=ignored"])
          | replay_mode: "replay-only"
        },
        input()
      )

    assert hd(first.claims).dedupe_key == "first"
    assert hd(refreshed.claims).dedupe_key == "second"
    assert hd(replay.claims).dedupe_key == "second"
    assert miss.claims == []
    assert [%{reason: "skipped", detail: "replay cache miss"}] = miss.errors
  end

  test "cache key changes when reviewer script content changes" do
    script = write_script("mutable_reviewer.exs", reviewer_script_for_claim("first"))

    first =
      Sugary.CommandReviewer.run(
        %{method(args: [script]) | replay_mode: "live"},
        input()
      )

    File.write!(script, reviewer_script_for_claim("second"))

    second =
      Sugary.CommandReviewer.run(
        %{method(args: [script]) | replay_mode: "cache-first"},
        input()
      )

    assert first_artifact(first).execution_mode == "live"
    assert hd(first.claims).dedupe_key == "first"
    assert first_artifact(second).execution_mode == "live"
    assert first_artifact(second).cache_hit == false
    assert hd(second.claims).dedupe_key == "second"
  end

  test "cache key changes when explicit env references a changed local file" do
    script =
      write_script(
        "file_env_reviewer.exs",
        """
        _input = IO.read(:stdio, :eof)
        id = System.fetch_env!("SUGARY_TEST_CLAIM_FILE") |> File.read!() |> String.trim()
        IO.write(:json.encode(%{
          reviewer_id: "external-test-reviewer",
          method_id: "external-test-reviewer",
          class: "research",
          claims: [
            %{
              id: id,
              claim: "Claim " <> id,
              category: "bug",
              severity: "high",
              confidence: 0.8,
              path: "src/preferences.ex",
              start_line: 1,
              end_line: 1,
              introduced_by_pr: true,
              evidence: [%{type: "fixture", tier: 4, strength: "medium", summary: "file env fixture"}],
              dedupe_key: id,
              source: %{method: "external-test-reviewer"},
              publish_decision: "candidate"
            }
          ],
          cost: 0.0,
          latency_ms: 1,
          artifacts: [],
          errors: []
        }))
        """
      )

    claim_file = write_script("claim.txt", "first")

    first =
      Sugary.CommandReviewer.run(
        %{
          method(args: [script], env: ["SUGARY_TEST_CLAIM_FILE=#{claim_file}"])
          | replay_mode: "live"
        },
        input()
      )

    File.write!(claim_file, "second")

    second =
      Sugary.CommandReviewer.run(
        %{
          method(args: [script], env: ["SUGARY_TEST_CLAIM_FILE=#{claim_file}"])
          | replay_mode: "cache-first"
        },
        input()
      )

    assert hd(first.claims).dedupe_key == "first"
    assert first_artifact(second).execution_mode == "live"
    assert first_artifact(second).cache_hit == false
    assert hd(second.claims).dedupe_key == "second"
  end

  defp reviewer_script_for_claim(id) do
    """
    _input = IO.read(:stdio, :eof)
    IO.write(:json.encode(%{
      reviewer_id: "external-test-reviewer",
      method_id: "external-test-reviewer",
      class: "research",
      claims: [
        %{
          id: "#{id}",
          claim: "Claim #{id}",
          category: "bug",
          severity: "high",
          confidence: 0.8,
          path: "src/preferences.ex",
          start_line: 1,
          end_line: 1,
          introduced_by_pr: true,
          evidence: [%{type: "fixture", tier: 4, strength: "medium", summary: "script fixture"}],
          dedupe_key: "#{id}",
          source: %{method: "external-test-reviewer"},
          publish_decision: "candidate"
        }
      ],
      cost: 0.0,
      latency_ms: 1,
      artifacts: [],
      errors: []
    }))
    """
  end

  test "text-to-reviewer-result normalizes plain text into low-confidence claims" do
    result =
      Sugary.CommandReviewer.run(
        method(
          id: "generic-llm-reviewer",
          args: ["scripts/reviewers/text_to_reviewer_result.exs"],
          env: ["SUGARY_REVIEWER_TEXT=Investigate this generated branch"]
        ),
        input()
      )

    [claim] = result.claims
    assert claim.claim == "Investigate this generated branch"
    assert claim.confidence == 0.35
    assert claim.category == "external_text"
  end

  test "external result quality warnings are recorded in artifacts" do
    warnings =
      Sugary.ExternalReviewers.quality_warnings(
        [
          %{
            id: "bad",
            claim: "Bad",
            category: "bug",
            severity: "medium",
            confidence: 0.2,
            path: "",
            introduced_by_pr: false,
            evidence: [],
            dedupe_key: "bad",
            source: %{}
          }
        ],
        input(),
        method()
      )

    warning_labels = Enum.map(warnings, & &1.warning)
    assert "missing file path" in warning_labels
    assert "missing line" in warning_labels
    assert "non-actionable summary" in warning_labels
    assert "no evidence text" in warning_labels
  end

  test "mixed internal, nested team, and pack reviewer team expands and runs" do
    [case_] =
      Sugary.Fixtures.load_suite!("agent-written-hard-fixtures", split: "holdout") |> Enum.take(1)

    result =
      Sugary.Teams.run_case(case_, %{
        id: "hybrid-proof-carrying-plus-external",
        type: "team",
        team_path: "teams/hybrid-proof-carrying-plus-external.toml",
        replay_mode: "cache-first",
        class: "team"
      })

    reviewer_ids = Enum.map(result.team.reviewer_runs, & &1.reviewer_id)

    assert "hard-specialist-team" in reviewer_ids
    assert "fixture-json-reviewer" in reviewer_ids
  end

  test "smoke experiment marks command reviewer execution modes in report" do
    run_dir =
      Sugary.Runner.run_experiment_manifest!(%{
        Sugary.Toml.parse_file!("experiments/external-real-pack-hard-holdout.toml")
        | replay_mode: "cache-first"
      })

    on_exit(fn -> File.rm_rf(run_dir) end)
    report = File.read!(Path.join(run_dir, "report.md"))

    assert report =~ "External Reviewer Execution"
    assert report =~ "fixture-json-reviewer"
    assert report =~ "live"
  end
end

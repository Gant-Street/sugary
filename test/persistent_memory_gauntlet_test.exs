defmodule Sugary.PersistentMemoryGauntletTest do
  use ExUnit.Case

  defp with_env(name, value, fun) do
    previous = System.get_env(name)

    if value in [nil, ""] do
      System.delete_env(name)
    else
      System.put_env(name, value)
    end

    try do
      fun.()
    after
      if previous do
        System.put_env(name, previous)
      else
        System.delete_env(name)
      end
    end
  end

  defp mock_martian_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-memory-gauntlet-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    Enum.each(1..2, fn index ->
      Sugary.Json.write!(Path.join(dir, "case-#{index}.json"), %{
        id: "memory-gauntlet-source-case-#{index}",
        repo: "example/repo",
        title: "Respect configured upload limits #{index}",
        body: "Local public benchmark smoke fixture.",
        diff:
          "diff --git a/app/assets/javascripts/discourse/lib/utilities.js b/app/assets/javascripts/discourse/lib/utilities.js\n" <>
            "--- a/app/assets/javascripts/discourse/lib/utilities.js\n" <>
            "+++ b/app/assets/javascripts/discourse/lib/utilities.js\n" <>
            "-    var maxSizeKB = Discourse.SiteSettings['max_' + type + '_size_kb'];\n" <>
            "+    var maxSizeKB = 10 * 1024;\n",
        changed_files: ["app/assets/javascripts/discourse/lib/utilities.js"],
        expectedClaims: [
          %{
            id: "public-static-hardcoded-upload-limit",
            description:
              "Hardcoding maxSizeKB to 10 * 1024 ignores configured Discourse upload limits.",
            category: "contract",
            severity: "low",
            path: "app/assets/javascripts/discourse/lib/utilities.js",
            line: 4,
            difficulty: "public",
            specialist: "contract"
          }
        ],
        knownNonIssues: []
      })
    end)

    dir
  end

  defp test_team_path do
    dir = Path.join(System.tmp_dir!(), "sugary-memory-team-#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)

    path = Path.join(dir, "memory-test-team.toml")

    File.write!(path, """
    id = "memory-test-team"
    description = "Deterministic test team for persistent memory gauntlet."
    failure_policy = "continue"
    merge_strategy = "dedupe_by_key_location_and_claim"
    max_published_claims = 3

    [[reviewers]]
    id = "public-static-proof-gate"
    type = "method"
    method = "public-static-proof-gate"
    """)

    path
  end

  test "persistent memory gauntlet writes scorecard, memory, controls, and leakage report" do
    bench_dir = mock_martian_dir()
    team_path = test_team_path()

    with_env("MARTIAN_BENCH_DIR", bench_dir, fn ->
      gauntlet_dir =
        Sugary.PersistentMemoryGauntlet.run!(%{
          "id" => "persistent-memory-test",
          "train-limit" => "1",
          "eval-limit" => "1",
          "train-offset" => "0",
          "eval-offset" => "1",
          "team" => team_path,
          "h5i" => "false"
        })

      scorecard = Sugary.Json.read!(Path.join(gauntlet_dir, "scorecard.json"))

      on_exit(fn ->
        File.rm_rf(gauntlet_dir)
        File.rm_rf(scorecard["train_run_dir"])
        File.rm_rf(scorecard["eval_run_dir"])
      end)

      assert File.exists?(Path.join(gauntlet_dir, "h5i-memory.json"))
      assert File.exists?(Path.join(gauntlet_dir, "shuffled-memory.json"))
      assert File.exists?(Path.join(gauntlet_dir, "report.md"))
      assert File.exists?(Path.join(gauntlet_dir, "h5i-memory-events.jsonl"))

      assert get_in(scorecard, ["memory_summary", "positive_lessons"]) == 1
      assert get_in(scorecard, ["leakage", "fatal?"]) == false
      assert Map.has_key?(scorecard["methods"], "stateless-team")
      assert Map.has_key?(scorecard["methods"], "stateless-normalized-team")
      assert Map.has_key?(scorecard["methods"], "h5i-persistent-memory-team")
      assert Map.has_key?(scorecard["methods"], "shuffled-memory-control-team")

      memory_text = File.read!(Path.join(gauntlet_dir, "h5i-memory.json"))
      refute memory_text =~ "memory-gauntlet-source-case-2"
      refute memory_text =~ "expectedClaims"

      report = File.read!(Path.join(gauntlet_dir, "report.md"))
      assert report =~ "h5i Persistent Memory Gauntlet"
      assert report =~ "shuffled-memory-control-team"
    end)
  end
end

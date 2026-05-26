defmodule Sugary.ArchitectureGauntletTest do
  use ExUnit.Case

  defp tmp_dir do
    dir =
      Path.join(
        System.tmp_dir!(),
        "sugary-architecture-gauntlet-test-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    dir
  end

  defp write!(dir, name, body) do
    path = Path.join(dir, name)
    File.write!(path, body)
    path
  end

  test "parses gauntlet variables and compositions from TOML" do
    dir = tmp_dir()

    path =
      write!(
        dir,
        "gauntlet.toml",
        """
        id = "parse-test"
        suite = "local-fixtures"

        [[variables]]
        id = "baseline"
        role = "reference"
        reviewer = "golden-noisy-reviewer"
        ingredients = ["native_harness", "oracle_test"]

        [[compositions]]
        id = "team"
        team = "#{Path.join(dir, "team.toml")}"
        members = ["baseline"]
        """
      )

    manifest = Sugary.ArchitectureGauntlet.parse_manifest!(path)

    assert manifest.id == "parse-test"
    assert [variable] = manifest.variables
    assert variable.id == "baseline"
    assert variable.ingredients == ["native_harness", "oracle_test"]
    assert [composition] = manifest.compositions
    assert composition.members == ["baseline"]
  end

  test "runs a gauntlet and reports independent and compositional decisions" do
    dir = tmp_dir()

    team_path =
      write!(
        dir,
        "team.toml",
        """
        id = "golden-team"
        failure_policy = "continue"
        merge_strategy = "dedupe_by_key_location_and_claim"
        max_published_claims = 3

        [[reviewers]]
        id = "golden-perfect"
        type = "method"
        method = "golden-perfect-reviewer"

        [[reviewers]]
        id = "golden-noisy"
        type = "method"
        method = "golden-noisy-reviewer"
        """
      )

    gauntlet_path =
      write!(
        dir,
        "architecture.toml",
        """
        id = "architecture-test"
        description = "Small architecture gauntlet test."
        suite = "local-fixtures"
        replay_mode = "cache-first"

        [guardrails]
        min_snr_ratio = 0.9
        min_usefulness_ratio = 1.0
        max_added_noise = 0
        max_avg_comments_per_pr = 3.0
        min_unique_hits = 1

        [[variables]]
        id = "golden-noisy"
        role = "reference"
        reviewer = "golden-noisy-reviewer"
        ingredients = ["reference"]

        [[variables]]
        id = "golden-perfect"
        role = "candidate"
        reviewer = "golden-perfect-reviewer"
        ingredients = ["noise_control"]

        [[compositions]]
        id = "golden-team"
        role = "composition"
        team = "#{team_path}"
        members = ["golden-noisy", "golden-perfect"]
        ingredients = ["team", "dedupe"]
        """
      )

    out_dir = Sugary.ArchitectureGauntlet.run!(gauntlet_path)
    underlying_run = out_dir |> Path.join("underlying-run.txt") |> File.read!() |> String.trim()
    on_exit(fn -> File.rm_rf(out_dir) end)
    on_exit(fn -> File.rm_rf(underlying_run) end)

    decision = Sugary.Json.read!(Path.join(out_dir, "decision.json"))
    assert decision["version"] == "architecture-gauntlet-v0"
    assert decision["experiment_run"] == underlying_run

    perfect =
      Enum.find(
        decision["variable_decisions"],
        &(get_in(&1, ["card", "id"]) == "golden-perfect")
      )

    assert perfect["decision"] == "keep"
    assert get_in(perfect, ["checks", "unique_signal_or_noise_reduction"]) == true

    report = File.read!(Path.join(out_dir, "architecture-gauntlet-report.md"))
    assert report =~ "Architecture Gauntlet v0"
    assert report =~ "Variable Scorecards"
    assert report =~ "Composition Scorecards"
  end

  test "composition promotion is blocked when it only ties the native/reference baseline" do
    dir = tmp_dir()

    team_path =
      write!(
        dir,
        "tie-team.toml",
        """
        id = "tie-team"
        failure_policy = "continue"
        merge_strategy = "dedupe_by_key_location_and_claim"
        max_published_claims = 3

        [[reviewers]]
        id = "golden-perfect"
        type = "method"
        method = "golden-perfect-reviewer"
        """
      )

    gauntlet_path =
      write!(
        dir,
        "architecture.toml",
        """
        id = "architecture-tie-test"
        suite = "local-fixtures"

        [[variables]]
        id = "native-perfect"
        role = "native_harness_reference"
        reviewer = "golden-perfect-reviewer"
        ingredients = ["native_harness"]

        [[variables]]
        id = "weak-baseline"
        role = "candidate"
        reviewer = "golden-missing-context-reviewer"
        ingredients = ["weak"]

        [[compositions]]
        id = "tie-team"
        role = "composition"
        team = "#{team_path}"
        members = ["weak-baseline"]
        ingredients = ["team"]
        """
      )

    out_dir = Sugary.ArchitectureGauntlet.run!(gauntlet_path)
    underlying_run = out_dir |> Path.join("underlying-run.txt") |> File.read!() |> String.trim()
    on_exit(fn -> File.rm_rf(out_dir) end)
    on_exit(fn -> File.rm_rf(underlying_run) end)

    decision = Sugary.Json.read!(Path.join(out_dir, "decision.json"))

    [composition] = decision["composition_decisions"]
    assert get_in(composition, ["best_comparator", "id"]) == "native-perfect"
    assert composition["beats_best_member"] == true
    assert composition["beats_best_comparator"] == false
    assert composition["decision"] == "quarantine"
  end

  test "absolute guardrails can block an otherwise improved candidate" do
    dir = tmp_dir()

    gauntlet_path =
      write!(
        dir,
        "architecture.toml",
        """
        id = "architecture-absolute-guardrail-test"
        suite = "local-fixtures"

        [guardrails]
        min_absolute_snr = 999.0

        [[variables]]
        id = "golden-noisy"
        role = "reference"
        reviewer = "golden-noisy-reviewer"
        ingredients = ["reference"]

        [[variables]]
        id = "golden-perfect"
        role = "candidate"
        reviewer = "golden-perfect-reviewer"
        ingredients = ["noise_control"]
        """
      )

    out_dir = Sugary.ArchitectureGauntlet.run!(gauntlet_path)
    underlying_run = out_dir |> Path.join("underlying-run.txt") |> File.read!() |> String.trim()
    on_exit(fn -> File.rm_rf(out_dir) end)
    on_exit(fn -> File.rm_rf(underlying_run) end)

    decision = Sugary.Json.read!(Path.join(out_dir, "decision.json"))

    candidate =
      Enum.find(
        decision["variable_decisions"],
        &(get_in(&1, ["card", "id"]) == "golden-perfect")
      )

    assert get_in(candidate, ["checks", "absolute_snr"]) == false
    assert candidate["decision"] == "quarantine"
  end
end

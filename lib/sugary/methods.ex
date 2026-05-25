defmodule Sugary.Methods do
  @registry %{
    "golden-perfect-reviewer" => %{
      id: "golden-perfect-reviewer",
      class: "harness_test",
      candidate_generation: "golden_perfect",
      context: "oracle",
      evidence: "fixture_oracle",
      refutation: "none",
      ranking: "fixed_threshold"
    },
    "golden-noisy-reviewer" => %{
      id: "golden-noisy-reviewer",
      class: "harness_test",
      candidate_generation: "golden_noisy",
      context: "oracle",
      evidence: "fixture_oracle",
      refutation: "none",
      ranking: "fixed_threshold"
    },
    "golden-missing-context-reviewer" => %{
      id: "golden-missing-context-reviewer",
      class: "harness_test",
      candidate_generation: "golden_missing_context",
      context: "oracle",
      evidence: "fixture_oracle",
      refutation: "none",
      ranking: "fixed_threshold"
    },
    "golden-duplicate-reviewer" => %{
      id: "golden-duplicate-reviewer",
      class: "harness_test",
      candidate_generation: "golden_duplicate",
      context: "oracle",
      evidence: "fixture_oracle",
      refutation: "none",
      ranking: "fixed_threshold"
    },
    "a-diff-only-single-shot" => %{
      id: "a-diff-only-single-shot",
      class: "research",
      context: "diff_only",
      candidate_generation: "baseline_single_shot",
      evidence: "none",
      refutation: "none",
      ranking: "fixed_threshold"
    },
    "b-changed-files" => %{
      id: "b-changed-files",
      class: "research",
      context: "changed_files",
      candidate_generation: "baseline_single_shot",
      evidence: "none",
      refutation: "none",
      ranking: "fixed_threshold"
    },
    "c-symbol-graph" => %{
      id: "c-symbol-graph",
      class: "research",
      context: "symbol_graph_stub",
      candidate_generation: "baseline_single_shot",
      evidence: "none",
      refutation: "none",
      ranking: "fixed_threshold"
    },
    "d-symbol-graph-candidate-swarm" => %{
      id: "d-symbol-graph-candidate-swarm",
      class: "research",
      context: "symbol_graph_stub",
      candidate_generation: "reflexion_stub",
      evidence: "none",
      refutation: "none",
      ranking: "fixed_threshold"
    },
    "e-evidence-gate" => %{
      id: "e-evidence-gate",
      class: "research",
      context: "symbol_graph_stub",
      candidate_generation: "reflexion_stub",
      evidence: "static_trace_stub",
      refutation: "none",
      ranking: "fixed_threshold"
    },
    "f-adversarial-refutation" => %{
      id: "f-adversarial-refutation",
      class: "research",
      context: "symbol_graph_stub",
      candidate_generation: "reflexion_stub",
      evidence: "static_trace_stub",
      refutation: "generic_refuter_stub",
      ranking: "fixed_threshold"
    },
    "g-calibrated-ranker" => %{
      id: "g-calibrated-ranker",
      class: "research",
      context: "symbol_graph_stub",
      candidate_generation: "reflexion_stub",
      evidence: "static_trace_stub",
      refutation: "generic_refuter_stub",
      ranking: "expected_value_stub"
    },
    "public-static-proof-gate" => %{
      id: "public-static-proof-gate",
      class: "research",
      context: "public_diff",
      candidate_generation: "public_static_proof_gate",
      evidence: "none",
      refutation: "none",
      ranking: "expected_value_stub"
    }
  }

  @aliases %{
    "baseline-diff-only" => "a-diff-only-single-shot",
    "baseline-changed-files" => "b-changed-files",
    "symbol-graph-reviewer" => "c-symbol-graph",
    "symbol-graph-reflexion" => "d-symbol-graph-candidate-swarm",
    "evidence-gate" => "e-evidence-gate",
    "adversarial-refutation" => "f-adversarial-refutation",
    "calibrated-ranker" => "g-calibrated-ranker",
    "pcrs-evidence-refuter" => "f-adversarial-refutation",
    "public-static-proof-gate" => "public-static-proof-gate"
  }

  def all, do: @registry

  def get!(id) do
    resolved = Map.get(@aliases, id, id)
    Map.fetch!(@registry, resolved)
  end

  def from_manifest_method(method) do
    method = Enum.into(method, %{}, fn {key, value} -> {to_string(key), value} end)
    id = method["id"]

    cond do
      team_path = method["team"] ->
        method
        |> Map.put("id", id || Path.basename(team_path, ".toml"))
        |> Map.put("type", "team")
        |> Map.put("team_path", team_path)
        |> Map.put_new("class", "team")
        |> atomize_map()

      method["type"] == "pack_reviewer" or method["pack"] ->
        method
        |> pack_reviewer()
        |> Map.put(:id, id || method["reviewer"])

      reviewer_id = method["reviewer"] ->
        reviewer_id
        |> get!()
        |> Map.put(:id, id || reviewer_id)

      true ->
        base = Map.get(@registry, Map.get(@aliases, id, id), %{id: id, class: "research"})

        method
        |> then(&Map.merge(base, &1))
        |> atomize_map()
    end
  end

  def from_manifest_reviewer(reviewer) do
    reviewer
    |> Enum.into(%{}, fn {key, value} -> {to_string(key), value} end)
    |> Map.put_new("class", "research")
    |> Map.put_new("context", "external_command")
    |> Map.put_new("candidate_generation", "command")
    |> Map.put_new("evidence", "none")
    |> Map.put_new("refutation", "none")
    |> Map.put_new("ranking", "fixed_threshold")
    |> atomize_map()
  end

  def from_team_reviewer(reviewer) do
    reviewer = Enum.into(reviewer, %{}, fn {key, value} -> {to_string(key), value} end)

    case reviewer["type"] || "method" do
      "method" ->
        method_id = reviewer["method"] || reviewer["id"]

        method_id
        |> get!()
        |> Map.merge(atomize_map(reviewer))
        |> Map.put(:id, reviewer["id"] || method_id)
        |> Map.put(:team_reviewer_type, "method")
        |> Map.put(:source_method_id, method_id)

      "command" ->
        reviewer
        |> Map.put("type", "command")
        |> from_manifest_reviewer()
        |> Map.put(:team_reviewer_type, "command")

      "team" ->
        path = reviewer["path"] || reviewer["team_path"] || reviewer["team"]

        %{
          id: reviewer["id"] || Path.basename(path, ".toml"),
          type: "team",
          class: "team",
          team_path: path,
          team_reviewer_type: "team"
        }

      "pack_reviewer" ->
        reviewer
        |> pack_reviewer()
        |> Map.put(:team_reviewer_type, "pack_reviewer")

      other ->
        raise ArgumentError, "unsupported team reviewer type #{inspect(other)}"
    end
  end

  defp pack_reviewer(reviewer) do
    pack_path = reviewer["pack"]
    reviewer_id = reviewer["reviewer"]

    pack_path
    |> Sugary.ReviewerPacks.load!()
    |> Map.get(:reviewers)
    |> Enum.find(&(Sugary.ReviewerPacks.reviewer_id(&1) == reviewer_id))
    |> case do
      nil ->
        raise ArgumentError,
              "reviewer #{inspect(reviewer_id)} not found in pack #{inspect(pack_path)}"

      pack_reviewer ->
        pack_reviewer
        |> Map.merge(Map.drop(reviewer, ["type", "pack", "reviewer"]))
        |> Map.put("type", Map.get(pack_reviewer, "type", "command"))
        |> from_team_reviewer()
    end
  end

  defp atomize_map(map), do: Enum.into(map, %{}, fn {key, value} -> {atom_key(key), value} end)
  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)
end

defmodule Sugary.Campaign do
  alias Sugary.Protocol.ExperimentManifest

  @root ".sugary/research/campaigns"
  @version "campaign-runner-v0"

  def load_manifest!(path), do: Sugary.Toml.parse_campaign_file!(path)

  def run!(path, opts \\ []) do
    manifest =
      path
      |> load_manifest!()
      |> maybe_override_replay_mode(Keyword.get(opts, :replay_mode))

    campaign_dir = Path.join(@root, manifest.id)
    resume? = Keyword.get(opts, :resume, false)
    dry_run? = Keyword.get(opts, :dry_run, false)

    Sugary.Runner.init_research!()
    File.mkdir_p!(@root)

    unless resume?, do: File.rm_rf!(campaign_dir)
    File.mkdir_p!(campaign_dir)

    if File.exists?(path) do
      File.cp!(path, Path.join(campaign_dir, "campaign.toml"))
    end

    queue = load_or_generate_queue(campaign_dir, manifest, resume?)
    leaderboard = load_leaderboard(campaign_dir, resume?)

    state =
      campaign_dir
      |> load_state(resume?)
      |> Map.merge(%{
        version: @version,
        campaign_id: manifest.id,
        campaign_path: path,
        split: manifest.split,
        primary_metric: manifest.primary_metric || "research_utility",
        updated_at: timestamp()
      })
      |> Map.put_new(:started_at, timestamp())

    cond do
      dry_run? ->
        final_state =
          Map.merge(state, %{
            status: "dry_run",
            decision: %{decision: "dry_run", reason: "No experiments executed."},
            next_variant: next_variant_id(queue, leaderboard)
          })

        write_checkpoint!(campaign_dir, manifest, queue, leaderboard, final_state)
        campaign_dir

      manifest.split == "holdout" ->
        decision = %{
          decision: "invalid_due_to_leakage",
          reason: "Campaign Runner v0 refuses to tune directly on holdout splits."
        }

        final_state =
          Map.merge(state, %{
            status: "invalid",
            decision: decision,
            finished_at: timestamp(),
            stop_reason: "holdout_split"
          })

        write_checkpoint!(campaign_dir, manifest, queue, leaderboard, final_state)
        campaign_dir

      true ->
        execute_loop(campaign_dir, manifest, queue, leaderboard, state, opts)
    end
  end

  def generate_queue(manifest) do
    baselines = baseline_variants(manifest)
    search = search_variants(manifest)

    (baselines ++ search)
    |> Enum.uniq_by(& &1.id)
    |> Enum.with_index(1)
    |> Enum.map(fn {variant, index} ->
      variant
      |> Map.put(:position, index)
      |> Map.put_new(:status, "pending")
    end)
  end

  def rank_leaderboard(entries, manifest) do
    best_baseline =
      entries
      |> Enum.filter(&(&1.role == "baseline"))
      |> Enum.max_by(&leaderboard_rank/1, fn -> nil end)

    entries
    |> Enum.map(&Map.put(&1, :guardrails, guardrails(&1, best_baseline, manifest, entries)))
    |> Enum.sort_by(&leaderboard_rank/1, :desc)
  end

  def next_variant(queue, leaderboard) do
    pending = Enum.filter(queue, &(&1.status == "pending"))

    cond do
      pending == [] ->
        nil

      Enum.any?(pending, &(&1.role == "baseline")) ->
        pending
        |> Enum.filter(&(&1.role == "baseline"))
        |> Enum.min_by(& &1.position)

      true ->
        preferred =
          pending
          |> Enum.sort_by(&next_variant_rank(&1, leaderboard), :desc)
          |> List.first()

        preferred || Enum.min_by(pending, & &1.position)
    end
  end

  def final_decision(manifest, queue, leaderboard, state) do
    best_baseline =
      leaderboard
      |> Enum.filter(&(&1.role == "baseline"))
      |> Enum.max_by(&leaderboard_rank/1, fn -> nil end)

    best_candidate =
      leaderboard
      |> Enum.reject(&(&1.role == "baseline"))
      |> Enum.filter(&(get_in(&1, [:guardrails, :pass?]) != false))
      |> Enum.max_by(&leaderboard_rank/1, fn -> nil end)

    min_delta = get_number(manifest.stop_conditions, "min_meaningful_utility_delta", 0.1)

    cond do
      manifest.split == "holdout" ->
        %{decision: "invalid_due_to_leakage", reason: "Campaign split is holdout."}

      fixture_saturated?(best_baseline) ->
        %{
          decision: "needs_harder_fixtures",
          reason:
            "The best baseline found every expected defect with zero noise, so this suite has no useful gradient."
        }

      best_candidate && best_baseline &&
          best_candidate.research_utility >= best_baseline.research_utility + min_delta ->
        %{
          decision: "recommend_candidate",
          reason: "Best candidate improved research utility while passing configured guardrails.",
          candidate_id: best_candidate.id,
          baseline_id: best_baseline.id,
          research_utility_delta: best_candidate.research_utility - best_baseline.research_utility
        }

      budget_stopped?(state) ->
        %{
          decision: "budget_exhausted",
          reason: Map.get(state, :stop_reason) || "Campaign budget exhausted."
        }

      unresolved_failures?(leaderboard) ->
        %{
          decision: "needs_new_reviewer_capability",
          reason:
            "Search space left unresolved false negatives; add a reviewer or context capability before widening the campaign."
        }

      Enum.any?(queue, &(&1.status == "pending")) ->
        %{
          decision: "reject_search_space",
          reason: "No pending candidate has passed promotion criteria."
        }

      true ->
        %{
          decision: "reject_search_space",
          reason: "Search space was exhausted without a promotable candidate."
        }
    end
  end

  def render_report(manifest, queue, leaderboard, state) do
    rows =
      leaderboard
      |> Enum.map(fn entry ->
        "| #{entry.id} | #{entry.role} | #{fmt(entry.research_utility)} | #{entry.score.hits} | #{fmt(entry.score.recall)} | #{fmt(entry.score.usefulness)} | #{fmt(entry.score.snr)} | #{entry.score.noise} | #{fmt(entry.score.avg_comments_per_pr)} | #{if entry.guardrails[:pass?], do: "pass", else: "fail"} |"
      end)
      |> Enum.join("\n")

    failures =
      leaderboard
      |> failure_clusters()
      |> Enum.map(fn {category, count} -> "| #{category} | #{count} |" end)
      |> Enum.join("\n")

    """
    # Campaign Report: #{manifest.id}

    Runner: `#{@version}`
    Suite: `#{manifest.suite}` / split: `#{manifest.split}`
    Primary metric: `#{manifest.primary_metric || "research_utility"}`
    Replay mode: `#{manifest.replay_mode || "cache-first"}`

    ## Status

    - Status: `#{Map.get(state, :status, "running")}`
    - Stop reason: `#{Map.get(state, :stop_reason, "none")}`
    - Decision: `#{get_in(state, [:decision, :decision]) || "pending"}`
    - Next variant: `#{Map.get(state, :next_variant, "none") || "none"}`
    - Completed experiments: #{Enum.count(queue, &(&1.status == "completed"))}
    - Pending experiments: #{Enum.count(queue, &(&1.status == "pending"))}

    ## Leaderboard

    | Variant | Role | Research Utility | Hits | Recall | Usefulness | SNR | Noise | Avg Comments/PR | Guardrails |
    | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
    #{if rows == "", do: "| none | none | 0 | 0 | 0.000 | 0.000 | 0.000 | 0 | 0.000 | fail |", else: rows}

    ## Failure Clusters

    | Category | Count |
    | --- | --- |
    #{if failures == "", do: "| none | 0 |", else: failures}

    ## Guardrails

    - Material recall regression: #{get_number(manifest.guardrails, "material_recall_regression", 0.05)}
    - Minimum SNR ratio: #{get_number(manifest.guardrails, "min_snr_ratio", 0.9)}
    - Max average comments per PR: #{get_number(manifest.guardrails, "max_avg_comments_per_pr", 3.0)}

    ## Interpretation

    Campaign Runner v0 searches bounded architecture variables on non-holdout splits only. A recommended candidate is an input to the locked promotion workflow, not a public benchmark claim.
    """
  end

  defp execute_loop(campaign_dir, manifest, queue, leaderboard, state, opts) do
    state = Map.put(state, :status, "running")
    write_checkpoint!(campaign_dir, manifest, queue, leaderboard, state)

    case stop_reason(manifest, queue, leaderboard, state, opts) do
      nil ->
        case next_variant(queue, leaderboard) do
          nil ->
            finish!(
              campaign_dir,
              manifest,
              queue,
              leaderboard,
              Map.put(state, :stop_reason, "queue_exhausted")
            )

          variant ->
            {queue, state} = mark_running(queue, state, variant)
            write_checkpoint!(campaign_dir, manifest, queue, leaderboard, state)

            {entry, failures} = run_variant!(manifest, variant)
            queue = mark_completed(queue, variant, entry)
            leaderboard = rank_leaderboard([entry | leaderboard], manifest)

            state =
              state
              |> Map.put(:experiments_completed, Enum.count(queue, &(&1.status == "completed")))
              |> Map.put(:estimated_cost_usd, total_cost(leaderboard))
              |> Map.put(:updated_at, timestamp())
              |> Map.put(:next_variant, next_variant_id(queue, leaderboard))

            append_jsonl!(Path.join(campaign_dir, "completed-runs.jsonl"), [entry])
            append_jsonl!(Path.join(campaign_dir, "failures.jsonl"), failures)
            write_checkpoint!(campaign_dir, manifest, queue, leaderboard, state)
            execute_loop(campaign_dir, manifest, queue, leaderboard, state, opts)
        end

      reason ->
        finish!(campaign_dir, manifest, queue, leaderboard, Map.put(state, :stop_reason, reason))
    end
  end

  defp finish!(campaign_dir, manifest, queue, leaderboard, state) do
    decision = final_decision(manifest, queue, leaderboard, state)

    final_state =
      state
      |> Map.put(:status, "complete")
      |> Map.put(:decision, decision)
      |> Map.put(:finished_at, timestamp())
      |> Map.put(:updated_at, timestamp())

    write_checkpoint!(campaign_dir, manifest, queue, leaderboard, final_state)

    if decision.decision == "recommend_candidate" do
      best = Enum.find(leaderboard, &(&1.id == decision.candidate_id))
      File.write!(Path.join(campaign_dir, "recommended-candidate.toml"), render_candidate(best))
    end

    campaign_dir
  end

  defp run_variant!(manifest, variant) do
    experiment =
      ExperimentManifest.new(%{
        id: "#{manifest.id}-#{variant.id}",
        suite: manifest.suite,
        split: manifest.split,
        replay_mode: manifest.replay_mode,
        methods: [variant.method]
      })

    {run_dir, [report], cases} = Sugary.Runner.run_experiment_manifest_with_reports!(experiment)
    scorecard = Sugary.ResearchScorecard.build(experiment, [report], cases)
    [method_card] = scorecard.methods

    entry = %{
      id: variant.id,
      role: variant.role,
      type: variant.type,
      method: variant.method,
      run_dir: run_dir,
      score: report.score,
      research_utility: method_card.research_utility,
      scorecard: method_card,
      failures: report.failures,
      completed_at: timestamp()
    }

    {entry, report.failures}
  end

  defp write_checkpoint!(campaign_dir, manifest, queue, leaderboard, state) do
    ensure_jsonl!(Path.join(campaign_dir, "completed-runs.jsonl"))
    ensure_jsonl!(Path.join(campaign_dir, "failures.jsonl"))
    Sugary.Json.write!(Path.join(campaign_dir, "state.json"), state)
    Sugary.Json.write!(Path.join(campaign_dir, "queue.json"), queue)
    Sugary.Json.write!(Path.join(campaign_dir, "leaderboard.json"), leaderboard)

    File.write!(
      Path.join(campaign_dir, "campaign-report.md"),
      render_report(manifest, queue, leaderboard, state)
    )
  end

  defp load_or_generate_queue(campaign_dir, manifest, true) do
    path = Path.join(campaign_dir, "queue.json")

    if File.exists?(path),
      do: path |> Sugary.Json.read!() |> atomize(),
      else: generate_queue(manifest)
  end

  defp load_or_generate_queue(_campaign_dir, manifest, _resume), do: generate_queue(manifest)

  defp load_leaderboard(campaign_dir, true) do
    path = Path.join(campaign_dir, "leaderboard.json")
    if File.exists?(path), do: path |> Sugary.Json.read!() |> atomize(), else: []
  end

  defp load_leaderboard(_campaign_dir, _resume), do: []

  defp load_state(campaign_dir, true) do
    path = Path.join(campaign_dir, "state.json")
    if File.exists?(path), do: path |> Sugary.Json.read!() |> atomize(), else: %{}
  end

  defp load_state(_campaign_dir, _resume), do: %{}

  defp maybe_override_replay_mode(manifest, mode) when mode in [nil, ""], do: manifest
  defp maybe_override_replay_mode(manifest, mode), do: %{manifest | replay_mode: mode}

  defp baseline_variants(manifest) do
    baselines = manifest.fixed_baselines || %{}

    method_ids =
      list_field(baselines, "method_ids") ++
        list_field(baselines, "methods") ++ list_field(manifest, "baseline_methods")

    team_paths =
      list_field(baselines, "team_paths") ++
        list_field(baselines, "teams") ++ list_field(manifest, "baseline_teams")

    method_variants =
      Enum.map(method_ids, fn id ->
        %{
          id: "baseline-#{slug(id)}",
          role: "baseline",
          type: "method",
          method: %{"id" => id, "reviewer" => id}
        }
      end)

    team_variants =
      Enum.map(team_paths, fn path ->
        %{
          id: "baseline-team-#{slug(Path.basename(path, ".toml"))}",
          role: "baseline",
          type: "team",
          method: %{"id" => Path.basename(path, ".toml"), "team" => path}
        }
      end)

    method_variants ++ team_variants
  end

  defp search_variants(manifest) do
    space = manifest.search_space || %{}

    contexts = list_or_default(space, "contexts", ["diff_only"])
    candidates = list_or_default(space, "candidate_generations", ["baseline_single_shot"])
    evidence = list_or_default(space, "evidence", ["none"])
    refutations = list_or_default(space, "refutations", ["none"])
    rankings = list_or_default(space, "rankings", ["fixed_threshold"])

    method_variants =
      for context <- contexts,
          candidate <- candidates,
          evidence_mode <- evidence,
          refutation <- refutations,
          ranking <- rankings do
        id =
          [
            "variant",
            context,
            candidate,
            evidence_mode,
            refutation,
            ranking
          ]
          |> Enum.map(&slug/1)
          |> Enum.join("-")

        %{
          id: id,
          role: "search",
          type: "method",
          method: %{
            "id" => id,
            "class" => "research",
            "context" => context,
            "candidate_generation" => candidate,
            "evidence" => evidence_mode,
            "refutation" => refutation,
            "ranking" => ranking
          }
        }
      end

    team_variants =
      space
      |> list_field("team_paths")
      |> Enum.map(fn path ->
        %{
          id: "variant-team-#{slug(Path.basename(path, ".toml"))}",
          role: "search",
          type: "team",
          method: %{"id" => Path.basename(path, ".toml"), "team" => path}
        }
      end)

    method_variants ++ team_variants
  end

  defp next_variant_rank(variant, leaderboard) do
    clusters = failure_clusters(leaderboard)
    fp_count = Map.get(clusters, "false_positive", 0) + Map.get(clusters, "preexisting_bug", 0)
    fn_count = Map.get(clusters, "false_negative", 0) + Map.get(clusters, "missing_context", 0)

    refutation_bonus =
      if fp_count > 0 and method_value(variant, "refutation") == "generic_refuter_stub",
        do: 10,
        else: 0

    context_bonus =
      if fn_count > 0 and
           method_value(variant, "context") in ["symbol_graph_stub", "changed_files"],
         do: 8,
         else: 0

    evidence_bonus =
      if method_value(variant, "evidence") == "static_trace_stub", do: 2, else: 0

    ranker_bonus =
      if method_value(variant, "ranking") == "expected_value_stub", do: 1, else: 0

    refutation_bonus + context_bonus + evidence_bonus + ranker_bonus - variant.position / 1000
  end

  defp stop_reason(manifest, queue, leaderboard, state, opts) do
    limit =
      Keyword.get(opts, :limit_experiments) || get_number(manifest.budget, "max_experiments", nil)

    completed = Enum.count(queue, &(&1.status == "completed"))
    max_cost = get_number(manifest.budget, "max_estimated_cost_usd", nil)
    max_wall = get_number(manifest.budget, "max_wall_time_seconds", nil)
    no_pending? = not Enum.any?(queue, &(&1.status == "pending"))

    cond do
      no_pending? -> "queue_exhausted"
      limit && completed >= limit -> "max_experiments"
      max_cost && total_cost(leaderboard) >= max_cost -> "max_estimated_cost_usd"
      max_wall && elapsed_seconds(state.started_at) >= max_wall -> "max_wall_time_seconds"
      convergence_reached?(manifest, leaderboard) -> "convergence"
      true -> nil
    end
  end

  defp convergence_reached?(manifest, leaderboard) do
    patience = get_number(manifest.stop_conditions, "no_improvement_patience", nil)

    if patience && length(leaderboard) >= patience + 1 do
      baseline =
        leaderboard
        |> Enum.filter(&(&1.role == "baseline"))
        |> Enum.max_by(&leaderboard_rank/1, fn -> nil end)

      recent =
        leaderboard
        |> Enum.reject(&(&1.role == "baseline"))
        |> Enum.sort_by(& &1.completed_at, :desc)
        |> Enum.take(patience)

      min_delta = get_number(manifest.stop_conditions, "min_meaningful_utility_delta", 0.1)

      baseline &&
        length(recent) == patience &&
        Enum.all?(recent, &(&1.research_utility < baseline.research_utility + min_delta))
    else
      false
    end
  end

  defp mark_running(queue, state, variant) do
    queue =
      Enum.map(queue, fn item ->
        if item.id == variant.id do
          item |> Map.put(:status, "running") |> Map.put(:started_at, timestamp())
        else
          item
        end
      end)

    {queue, Map.merge(state, %{current_variant: variant.id, updated_at: timestamp()})}
  end

  defp mark_completed(queue, variant, entry) do
    Enum.map(queue, fn item ->
      if item.id == variant.id do
        item
        |> Map.put(:status, "completed")
        |> Map.put(:completed_at, entry.completed_at)
        |> Map.put(:run_dir, entry.run_dir)
      else
        item
      end
    end)
  end

  defp guardrails(_entry, nil, _manifest, _entries) do
    %{pass?: true, checks: %{baseline_available: false}, warnings: ["No completed baseline yet."]}
  end

  defp guardrails(entry, baseline, manifest, entries) do
    guardrails = manifest.guardrails || %{}
    recall_regression = get_number(guardrails, "material_recall_regression", 0.05)
    min_snr_ratio = get_number(guardrails, "min_snr_ratio", 0.9)
    max_comments = get_number(guardrails, "max_avg_comments_per_pr", 3.0)
    max_cost = get_number(manifest.budget, "max_estimated_cost_usd", nil)

    recall_ok = entry.score.recall + recall_regression >= baseline.score.recall
    snr_ok = entry.score.snr >= baseline.score.snr * min_snr_ratio
    comments_ok = entry.score.avg_comments_per_pr <= max_comments
    cost_ok = is_nil(max_cost) or total_cost(entries) <= max_cost
    leakage_ok = not oracle_method?(entry.method)

    checks = %{
      recall_ok: recall_ok,
      snr_ok: snr_ok,
      comments_ok: comments_ok,
      cost_ok: cost_ok,
      leakage_ok: leakage_ok
    }

    %{
      pass?: Enum.all?(Map.values(checks)),
      checks: checks,
      warnings: guardrail_warnings(checks)
    }
  end

  defp guardrail_warnings(checks) do
    checks
    |> Enum.reject(fn {_key, value} -> value end)
    |> Enum.map(fn {key, _value} -> "#{key} failed" end)
  end

  defp render_candidate(nil), do: "# No candidate recommended.\n"

  defp render_candidate(entry) do
    method = entry.method

    body =
      cond do
        team = method[:team] || method["team"] ->
          """
          [[methods]]
          id = "#{entry.id}"
          team = "#{team}"
          """

        reviewer = method[:reviewer] || method["reviewer"] ->
          """
          [[methods]]
          id = "#{entry.id}"
          reviewer = "#{reviewer}"
          """

        true ->
          """
          [[methods]]
          id = "#{entry.id}"
          class = "#{method[:class] || method["class"] || "research"}"
          context = "#{method[:context] || method["context"]}"
          candidate_generation = "#{method[:candidate_generation] || method["candidate_generation"]}"
          evidence = "#{method[:evidence] || method["evidence"]}"
          refutation = "#{method[:refutation] || method["refutation"]}"
          ranking = "#{method[:ranking] || method["ranking"]}"
          """
      end

    """
    # Generated by Sugary Campaign Runner v0.
    # This is a locked-promotion candidate recommendation, not a public benchmark claim.

    #{body}
    """
  end

  defp failure_clusters(leaderboard) do
    leaderboard
    |> Enum.flat_map(& &1.failures)
    |> Enum.group_by(fn failure ->
      failure_field(failure, "category") || failure_field(failure, "type") || "unknown"
    end)
    |> Map.new(fn {category, failures} -> {to_string(category), length(failures)} end)
  end

  defp failure_field(%_module{} = struct, key),
    do: struct |> Map.from_struct() |> failure_field(key)

  defp failure_field(map, key) when is_map(map),
    do: map[key] || map[to_string(key)] || map[String.to_atom(to_string(key))]

  defp failure_field(_failure, _key), do: nil

  defp unresolved_failures?(leaderboard) do
    leaderboard
    |> failure_clusters()
    |> Enum.any?(fn {category, count} ->
      count > 0 and category in ["missing_context", "comment_suppressed_too_aggressively"]
    end)
  end

  defp fixture_saturated?(nil), do: false

  defp fixture_saturated?(entry) do
    entry.score.expected_claims > 0 and entry.score.hits == entry.score.expected_claims and
      entry.score.noise == 0
  end

  defp budget_stopped?(state) do
    Map.get(state, :stop_reason) in [
      "max_experiments",
      "max_estimated_cost_usd",
      "max_wall_time_seconds"
    ]
  end

  defp oracle_method?(method) do
    (method[:context] || method["context"]) == "oracle" or
      (method[:evidence] || method["evidence"]) == "fixture_oracle"
  end

  defp leaderboard_rank(entry) do
    score = entry.score
    {entry.research_utility || 0.0, score.f1, score.usefulness, score.snr}
  end

  defp total_cost(leaderboard) do
    Enum.reduce(leaderboard, 0.0, fn entry, acc -> acc + (entry.score.cost || 0.0) end)
  end

  defp next_variant_id(queue, leaderboard) do
    case next_variant(queue, leaderboard) do
      nil -> nil
      variant -> variant.id
    end
  end

  defp append_jsonl!(path, records) do
    path |> Path.dirname() |> File.mkdir_p!()

    lines =
      records
      |> Enum.map(&(Sugary.Json.encode!(&1) <> "\n"))
      |> Enum.join()

    File.write!(path, lines, [:append])
  end

  defp ensure_jsonl!(path) do
    path |> Path.dirname() |> File.mkdir_p!()
    unless File.exists?(path), do: File.write!(path, "")
  end

  defp list_or_default(map, key, default) do
    case list_field(map, key) do
      [] -> default
      values -> values
    end
  end

  defp list_field(%_module{} = struct, key), do: struct |> Map.from_struct() |> list_field(key)

  defp list_field(map, key) when is_map(map) do
    value = map[key] || map[to_string(key)] || map[String.to_atom(to_string(key))]

    value
    |> List.wrap()
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp list_field(_map, _key), do: []

  defp method_value(variant, key) do
    method = variant[:method] || variant["method"] || %{}
    method[key] || method[to_string(key)] || method[String.to_atom(to_string(key))]
  end

  defp get_number(map, key, default) when is_map(map) do
    value = map[key] || map[to_string(key)] || map[String.to_atom(to_string(key))]

    cond do
      value in [nil, ""] ->
        default

      is_integer(value) or is_float(value) ->
        value

      is_binary(value) ->
        case Float.parse(value) do
          {number, ""} -> number
          _ -> default
        end

      true ->
        default
    end
  end

  defp get_number(_map, _key, default), do: default

  defp elapsed_seconds(nil), do: 0

  defp elapsed_seconds(started_at) do
    case DateTime.from_iso8601(started_at) do
      {:ok, started, _offset} -> DateTime.diff(DateTime.utc_now(), started)
      _ -> 0
    end
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp fmt(value) when is_integer(value), do: Integer.to_string(value)
  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(_value), do: "0.000"

  defp timestamp, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

  defp atomize(%{} = map),
    do: Map.new(map, fn {key, value} -> {atom_key(key), atomize(value)} end)

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value

  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)
end

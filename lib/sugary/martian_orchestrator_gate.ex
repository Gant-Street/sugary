defmodule Sugary.MartianOrchestratorGate do
  @default_id "martian-orchestrator-h5i-v0"
  @default_limit 3
  @default_offset 0
  @default_replay_mode "cache-first"
  @default_team "teams/public-pcrs-static-codex-low-team.toml"

  alias Sugary.Protocol.ExperimentManifest

  def run!(opts \\ %{}) do
    opts = normalize_opts(opts)
    id = Map.get(opts, "id", @default_id)
    limit = opts |> Map.get("limit", @default_limit) |> parse_int()
    offset = opts |> Map.get("offset", @default_offset) |> parse_int()
    replay_mode = Map.get(opts, "replay-mode", @default_replay_mode)
    team_path = Map.get(opts, "team", @default_team)
    requested_backend = Map.get(opts, "agent-bus", "auto")

    gate_dir = make_gate_dir(id)
    File.mkdir_p!(gate_dir)

    bus =
      Sugary.AgentBus.new!(
        id: Path.basename(gate_dir),
        requested_backend: requested_backend,
        root: Path.join(gate_dir, "agent-bus")
      )

    cases =
      Sugary.PublicBenchmarks.load_cases!("martian-offline", limit: limit, offset: offset)

    append_start!(bus, id, limit, offset, replay_mode, team_path)
    blind_cases = route_cases!(bus, cases)

    manifest =
      ExperimentManifest.new(%{
        id: "#{id}-martian-comparison",
        description:
          "Martian-only orchestration substrate comparison. This is an unofficial local smoke run.",
        suite: "martian-offline",
        limit: limit,
        offset: offset,
        replay_mode: replay_mode,
        methods: [
          %{"id" => "baseline-diff-only", "reviewer" => "baseline-diff-only"},
          %{"id" => "public-static-proof-gate", "reviewer" => "public-static-proof-gate"},
          %{
            "id" => "orchestrated-public-pcrs-static-codex-low-team",
            "team" => team_path
          }
        ]
      })

    {run_dir, method_reports, run_cases} =
      Sugary.Runner.run_experiment_manifest_with_reports!(manifest)

    append_results!(bus, method_reports, blind_cases)

    Sugary.AgentBus.append!(bus, %{
      type: "ORCHESTRATION_DONE",
      from: "sugary-orchestrator",
      to: "researcher",
      suite: "martian-offline",
      payload: %{
        experiment_run_dir: run_dir,
        methods: Enum.map(method_reports, & &1.method.id),
        note: "Transport-only gate; orchestration messages did not alter reviewer prompts."
      }
    })

    bus_summary = Sugary.AgentBus.summary(bus)
    leakage = Sugary.PublicBenchmarks.leakage_report(run_dir, run_cases)
    bus_leakage = bus_leakage_report(bus, run_cases)

    scorecard =
      build_scorecard(%{
        id: id,
        gate_dir: gate_dir,
        run_dir: run_dir,
        limit: limit,
        offset: offset,
        replay_mode: replay_mode,
        team_path: team_path,
        method_reports: method_reports,
        bus_summary: bus_summary,
        leakage: leakage,
        bus_leakage: bus_leakage
      })

    Sugary.Json.write!(Path.join(gate_dir, "orchestrator-scorecard.json"), scorecard)
    Sugary.Json.write!(Path.join(gate_dir, "agent-bus-summary.json"), bus_summary)
    Sugary.Json.write!(Path.join(gate_dir, "leakage-report.json"), leakage)
    Sugary.Json.write!(Path.join(gate_dir, "agent-bus-leakage-report.json"), bus_leakage)
    File.cp!(bus.messages_path, Path.join(gate_dir, "agent-messages.jsonl"))
    File.write!(Path.join(gate_dir, "orchestrator-report.md"), render_report(scorecard))

    gate_dir
  end

  defp append_start!(bus, id, limit, offset, replay_mode, team_path) do
    Sugary.AgentBus.append!(bus, %{
      type: "ORCHESTRATION_START",
      from: "researcher",
      to: "sugary-orchestrator",
      suite: "martian-offline",
      payload: %{
        gate_id: id,
        limit: limit,
        offset: offset,
        replay_mode: replay_mode,
        team_path: team_path,
        claim_scope:
          "Martian-only comparison of orchestration substrate. No official benchmark claim."
      }
    })
  end

  defp route_cases!(bus, cases) do
    cases
    |> Enum.with_index(1)
    |> Map.new(fn {bench_case, index} ->
      blind_id = "blind-martian-case-#{index}"
      focus_paths = changed_files(bench_case)
      diff_size = byte_size(bench_case.diff || "")

      Enum.each(sentinels(), fn sentinel ->
        Sugary.AgentBus.append!(bus, %{
          type: "REVIEW_REQUEST",
          from: "sugary-orchestrator",
          to: sentinel.id,
          branch: "HEAD",
          risk: sentinel.risk,
          summary: sentinel.summary,
          suite: "martian-offline",
          case_id: blind_id,
          payload: %{
            blind_case_id: blind_id,
            focus_paths: focus_paths,
            diff_size_bytes: diff_size,
            reviewer_method: sentinel.method,
            risk: sentinel.risk,
            note: "Oracle and original benchmark identifiers are withheld."
          }
        })
      end)

      Sugary.AgentBus.append!(bus, %{
        type: "REFUTE_REQUEST",
        from: "sugary-orchestrator",
        to: "proof-publisher",
        suite: "martian-offline",
        case_id: blind_id,
        payload: %{
          blind_case_id: blind_id,
          focus_paths: focus_paths,
          ask: "Suppress claims without PR-introducedness or evidence."
        }
      })

      {bench_case.id, blind_id}
    end)
  end

  defp append_results!(bus, method_reports, blind_cases) do
    Enum.each(method_reports, fn report ->
      Enum.each(report.results, fn result ->
        blind_id = Map.fetch!(blind_cases, result.case.id)
        published = Enum.count(result.final_claims, &(&1.publish_decision == "publish"))

        Sugary.AgentBus.append!(bus, %{
          type: "REVIEW_RESULT",
          from: report.method.id,
          to: "sugary-orchestrator",
          suite: "martian-offline",
          case_id: blind_id,
          payload: %{
            method_id: report.method.id,
            candidate_claims: length(result.candidate_claims),
            published_claims: published,
            reviewer_errors: length(result.reviewer_result.errors || []),
            reviewer_class: result.reviewer_result.class
          }
        })
      end)
    end)

    method_reports
    |> Enum.filter(&(Map.get(&1.method, :type) == "team"))
    |> Enum.each(fn report ->
      Enum.each(report.results, fn result ->
        blind_id = Map.fetch!(blind_cases, result.case.id)

        Sugary.AgentBus.append!(bus, %{
          type: "PUBLISH_DECISION",
          from: "sugary-orchestrator",
          to: "researcher",
          suite: "martian-offline",
          case_id: blind_id,
          payload: %{
            team_id: report.method.id,
            raw_claims: length(result.team.raw_claims),
            merged_claims: length(result.team.merged_claims),
            published_claims: length(result.team.published_claims),
            failure_reason: result.team.failure_reason,
            note: "Sugary owns merge, ranking, scoring, and final publishing decisions."
          }
        })
      end)
    end)
  end

  defp build_scorecard(attrs) do
    reports = attrs.method_reports
    candidate_id = "orchestrated-public-pcrs-static-codex-low-team"
    candidate = Enum.find(reports, &(&1.method.id == candidate_id))

    best_single =
      reports
      |> Enum.reject(&(Map.get(&1.method, :type) == "team"))
      |> Enum.max_by(&{&1.score.f1, &1.score.usefulness, &1.score.snr}, fn -> nil end)

    decision = decision(candidate, best_single, attrs.leakage, attrs.bus_leakage)

    %{
      id: attrs.id,
      benchmark: "martian-offline",
      unofficial: true,
      gate_dir: attrs.gate_dir,
      experiment_run_dir: attrs.run_dir,
      limit: attrs.limit,
      offset: attrs.offset,
      replay_mode: attrs.replay_mode,
      team_path: attrs.team_path,
      agent_bus: attrs.bus_summary,
      methods: Map.new(reports, &{&1.method.id, score_summary(&1.score)}),
      candidate: maybe_method_summary(candidate),
      best_single: maybe_method_summary(best_single),
      comparison: comparison(candidate, best_single),
      leakage: attrs.leakage,
      agent_bus_leakage: attrs.bus_leakage,
      decision: decision,
      quality_claim_level:
        "transport-only comparison; orchestration messages did not alter reviewer prompts, tools, or publishing thresholds"
    }
  end

  defp decision(_candidate, _best_single, %{fatal?: true}, _bus_leakage),
    do: "invalid_due_to_reviewer_input_leakage"

  defp decision(_candidate, _best_single, _leakage, %{fatal?: true}),
    do: "invalid_due_to_agent_bus_leakage"

  defp decision(nil, _best_single, _leakage, _bus_leakage), do: "invalid_missing_candidate"
  defp decision(_candidate, nil, _leakage, _bus_leakage), do: "invalid_missing_baseline"

  defp decision(candidate, best_single, _leakage, _bus_leakage) do
    cond do
      candidate.score.f1 > best_single.score.f1 and
          candidate.score.snr >= best_single.score.snr * 0.9 ->
        "orchestrated_team_beats_best_single_on_martian_smoke"

      true ->
        "transport_validated_no_quality_lift"
    end
  end

  defp comparison(nil, _best_single), do: %{}
  defp comparison(_candidate, nil), do: %{}

  defp comparison(candidate, best_single) do
    %{
      f1_delta: candidate.score.f1 - best_single.score.f1,
      recall_delta: candidate.score.recall - best_single.score.recall,
      usefulness_delta: candidate.score.usefulness - best_single.score.usefulness,
      snr_delta: candidate.score.snr - best_single.score.snr,
      avg_comments_delta:
        candidate.score.avg_comments_per_pr - best_single.score.avg_comments_per_pr
    }
  end

  defp maybe_method_summary(nil), do: nil

  defp maybe_method_summary(report),
    do: %{method_id: report.method.id, score: score_summary(report.score)}

  defp score_summary(score) do
    %{
      f1: score.f1,
      recall: score.recall,
      precision: score.precision,
      usefulness: score.usefulness,
      snr: score.snr,
      avg_comments_per_pr: score.avg_comments_per_pr,
      published_claims: score.published_claims,
      hits: score.hits,
      noise: score.noise,
      cost: score.cost,
      latency_ms: score.latency_ms
    }
  end

  defp bus_leakage_report(bus, cases) do
    messages = File.read!(bus.messages_path)

    source_ids =
      cases
      |> Enum.map(fn bench_case ->
        bench_case.source_metadata
        |> case do
          nil ->
            nil

          metadata ->
            Map.get(metadata, :original_case_id) || Map.get(metadata, "original_case_id")
        end
      end)
      |> Enum.reject(&(&1 in [nil, ""]))

    leaked_ids = Enum.filter(source_ids, &String.contains?(messages, &1))

    oracle_markers =
      ["expectedClaims", "knownNonIssues", "\"oracle\"", "golden_comments"]
      |> Enum.filter(&String.contains?(messages, &1))

    %{
      fatal?: leaked_ids != [] or oracle_markers != [],
      input_case_id_leaks: leaked_ids,
      oracle_markers: oracle_markers,
      warnings: []
    }
  end

  defp render_report(scorecard) do
    rows =
      scorecard.methods
      |> Enum.map(fn {method_id, score} ->
        "| #{method_id} | #{fmt(score.recall)} | #{fmt(score.usefulness)} | #{fmt(score.snr)} | #{fmt(score.f1)} | #{fmt(score.avg_comments_per_pr)} | #{score.published_claims} | #{score.noise} |"
      end)
      |> Enum.join("\n")

    bus = scorecard.agent_bus
    comparison = scorecard.comparison || %{}

    """
    # Martian Orchestrator Gate: #{scorecard.id}

    This is an unofficial local Martian smoke comparison. It does not submit results and it is not an official benchmark score.

    ## Decision

    - Decision: `#{scorecard.decision}`
    - Claim level: #{scorecard.quality_claim_level}
    - h5i requested backend: `#{bus.requested_backend}`
    - effective backend: `#{bus.effective_backend}`
    - h5i available locally: #{if bus.h5i_available, do: "yes", else: "no"}

    ## Scorecard

    | Method | Recall | Usefulness | SNR | F1 | Avg Comments | Published | Noise |
    | --- | --- | --- | --- | --- | --- | --- | --- |
    #{rows}

    ## Candidate vs Best Single

    - Candidate: `#{get_in(scorecard, [:candidate, :method_id]) || "none"}`
    - Best single: `#{get_in(scorecard, [:best_single, :method_id]) || "none"}`
    - F1 delta: #{fmt(Map.get(comparison, :f1_delta))}
    - Recall delta: #{fmt(Map.get(comparison, :recall_delta))}
    - Usefulness delta: #{fmt(Map.get(comparison, :usefulness_delta))}
    - SNR delta: #{fmt(Map.get(comparison, :snr_delta))}
    - Avg comment delta: #{fmt(Map.get(comparison, :avg_comments_delta))}

    ## Agent Bus

    - Message count: #{bus.message_count}
    - Messages path: `#{bus.messages_path}`
    - Counts by type: `#{inspect(bus.message_counts_by_type)}`
    - h5i events: #{bus.h5i_event_count}

    ## Leakage

    - Reviewer input leakage fatal: #{scorecard.leakage.fatal?}
    - Agent bus leakage fatal: #{scorecard.agent_bus_leakage.fatal?}

    ## Interpretation

    This run tests the orchestration substrate, not persistent-memory quality. A quality lift here means the team being compared did better on Martian smoke; it does not prove h5i or any bus backend caused the lift because reviewer prompts and tools are unchanged.
    """
  end

  defp sentinels do
    [
      %{
        id: "static-proof-sentinel",
        method: "public-static-proof-gate",
        risk: "deterministic static proof",
        summary: "Look for high-evidence claims from the changed diff."
      },
      %{
        id: "codex-review-sentinel",
        method: "codex-gpt-5.5-low",
        risk: "model candidate search",
        summary: "Generate candidate code-review claims from the changed diff."
      }
    ]
  end

  defp changed_files(bench_case) do
    context = bench_case.context || %{}

    get_in_flexible(context, [:allowed, :changed_files]) ||
      get_in_flexible(context, ["allowed", "changed_files"]) ||
      Map.get(context, :changed_files) ||
      Map.get(context, "changed_files") ||
      []
  end

  defp get_in_flexible(map, path) do
    Enum.reduce_while(path, map, fn key, acc ->
      cond do
        is_map(acc) and Map.has_key?(acc, key) ->
          {:cont, Map.get(acc, key)}

        is_atom(key) and is_map(acc) and Map.has_key?(acc, Atom.to_string(key)) ->
          {:cont, Map.get(acc, Atom.to_string(key))}

        is_binary(key) and is_map(acc) and Map.has_key?(acc, String.to_atom(key)) ->
          {:cont, Map.get(acc, String.to_atom(key))}

        true ->
          {:halt, nil}
      end
    end)
  rescue
    ArgumentError -> nil
  end

  defp make_gate_dir(id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(".sugary/research/orchestrator-gates", "#{timestamp}-#{id}")
  end

  defp normalize_opts(opts) when is_list(opts) do
    Map.new(opts, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_opts(opts) when is_map(opts) do
    Map.new(opts, fn {key, value} -> {to_string(key), value} end)
  end

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value), do: value |> to_string() |> Integer.parse() |> elem(0)

  defp fmt(nil), do: "n/a"
  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)
end

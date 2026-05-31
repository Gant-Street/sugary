defmodule Sugary.TransferGate do
  alias Sugary.Protocol.ExperimentManifest

  @default_static_run ".sugary/research/runs/20260531T001509Z-martian-pcrs-v3-static-patterns-candidate"
  @default_publisher_run ".sugary/research/pcrs-ensemble-publisher/20260531T001945Z-pcrs-ensemble-v3-static-patterns-wide-raw"

  @trust_policy "posterior-max1-plus-source5-qualified-triad-budget52"
  @qualified_policy "qualified-f1-judge-risk-budget84-max3"
  @raw_policy "raw-recall-diagnostic-budget160-deduped-max6"

  def run!(opts \\ %{}) do
    opts = stringify(opts)
    id = Map.get(opts, "id", "locked-pcrs-v3-transfer-gate-v0")
    suite = Map.get(opts, "suite", "aacr-bench")
    limit = opts |> Map.get("limit", "25") |> parse_int()
    offset = opts |> Map.get("offset", "0") |> parse_int()
    locked_commit = Map.get(opts, "locked-commit", "e66b567")
    static_run = Map.get(opts, "static-run", @default_static_run)
    publisher_run = Map.get(opts, "publisher-run", @default_publisher_run)
    baseline_id = Map.get(opts, "baseline", "baseline-diff-only")
    candidate_id = Map.get(opts, "candidate", "public-static-proof-gate")

    manifest =
      ExperimentManifest.new(%{
        id: id <> "-smoke",
        suite: suite,
        limit: limit,
        offset: offset,
        methods: [
          %{id: baseline_id, reviewer: baseline_id},
          %{id: candidate_id, reviewer: candidate_id}
        ],
        description:
          "Locked PCRS v3 transfer gate. Static proof patterns and publisher thresholds are frozen from #{locked_commit}."
      })

    {run_dir, method_reports, cases} =
      Sugary.Runner.run_experiment_manifest_with_reports!(manifest)

    transfer_dir = transfer_dir(id)
    File.mkdir_p!(transfer_dir)

    local = %{
      static_proof: static_summary(static_run, candidate_id),
      publisher: publisher_summary(publisher_run)
    }

    transfer = %{
      suite: suite,
      limit: limit,
      offset: offset,
      run_dir: run_dir,
      cases: length(cases),
      baseline: score_for(method_reports, baseline_id),
      static_proof: score_for(method_reports, candidate_id),
      leakage: Sugary.PublicBenchmarks.leakage_report(run_dir, cases)
    }

    scorecard =
      %{
        id: id,
        locked_commit: locked_commit,
        source_static_run: static_run,
        source_publisher_run: publisher_run,
        transfer_run: run_dir,
        transfer_suite: suite,
        local: local,
        transfer: transfer,
        generalization_gap: generalization_gap(local.static_proof, transfer.static_proof),
        skipped_sources: skipped_sources(suite),
        caveats: caveats(suite)
      }

    Sugary.Json.write!(Path.join(transfer_dir, "transfer-scorecard.json"), scorecard)
    File.write!(Path.join(transfer_dir, "generalization-report.md"), render_report(scorecard))
    File.write!(Path.join(transfer_dir, "run-dir.txt"), run_dir <> "\n")

    transfer_dir
  end

  defp transfer_dir(id) do
    timestamp =
      DateTime.utc_now()
      |> Calendar.strftime("%Y%m%dT%H%M%SZ")

    Path.join(".sugary/research/transfer-gates", "#{timestamp}-#{id}")
  end

  defp static_summary(run_dir, method_id) do
    score =
      run_dir
      |> Path.join("scores.json")
      |> read_json()
      |> List.wrap()
      |> Enum.find(fn
        %{"method_id" => ^method_id} -> true
        %{"score" => %{"method_id" => ^method_id}} -> true
        _other -> false
      end)

    %{
      status: if(score, do: "available", else: "missing"),
      run_dir: run_dir,
      method_id: method_id,
      score: score && (score["score"] || score)
    }
  end

  defp publisher_summary(run_dir) do
    pool = read_json(Path.join(run_dir, "candidate-pool.json"))
    decision = read_json(Path.join(run_dir, "decision.json"))
    policies = read_json(Path.join(run_dir, "policy-scorecards.json")) || []

    %{
      status: if(pool && policies != [], do: "available", else: "missing"),
      run_dir: run_dir,
      candidate_pool: pool,
      decision: decision,
      trust_default: policy_score(policies, @trust_policy),
      qualified: policy_score(policies, @qualified_policy),
      raw_diagnostic: policy_score(policies, @raw_policy)
    }
  end

  defp policy_score(policies, id) do
    policies
    |> Enum.find(&(&1["id"] == id))
    |> case do
      nil -> %{status: "missing", id: id}
      policy -> Map.put(policy, "status", "available")
    end
  end

  defp score_for(method_reports, method_id) do
    method_reports
    |> Enum.find(&(&1.method.id == method_id))
    |> case do
      nil -> %{status: "missing", method_id: method_id}
      report -> %{status: "available", method_id: method_id, score: report.score}
    end
  end

  defp generalization_gap(%{score: local_score}, %{score: transfer_score})
       when is_map(local_score) and is_map(transfer_score) do
    %{
      f1: metric(local_score, "f1") - metric(transfer_score, :f1),
      precision: metric(local_score, "precision") - metric(transfer_score, :precision),
      recall: metric(local_score, "recall") - metric(transfer_score, :recall),
      hits: metric(local_score, "hits") - metric(transfer_score, :hits),
      noise: metric(local_score, "noise") - metric(transfer_score, :noise)
    }
  end

  defp generalization_gap(_local, _transfer), do: %{status: "not_computable"}

  defp skipped_sources(suite) do
    [
      %{
        source: "pcrs-ensemble-publisher-candidate-pool",
        suite: suite,
        status: "skipped",
        reason:
          "The locked ensemble candidate pool was produced from Martian source runs. No model-backed candidate source artifacts exist for #{suite} without live LLM/API execution."
      },
      %{
        source: "qualified-publisher-policy",
        suite: suite,
        status: "skipped",
        reason:
          "Publisher thresholds are recorded, but cannot score transfer until equivalent candidate details are generated for #{suite}."
      },
      %{
        source: "official-benchmark-runner",
        suite: suite,
        status: "skipped",
        reason:
          "This no-key gate runs Sugary local scoring only. It does not call a Martian API or submit results."
      }
    ]
  end

  defp caveats(suite) do
    [
      "Static-proof patterns are locked from the source commit; this run must not add #{suite}-specific patterns.",
      "Sugary local scoring is not the official #{suite} evaluator.",
      "AACR semantic matching normally uses an LLM or embedding evaluator; this no-key gate uses Sugary's deterministic matcher.",
      "A transfer failure is actionable evidence about brittleness, not proof that PCRS is wrong.",
      "A transfer win here would still be smoke evidence, not a public benchmark claim."
    ]
  end

  defp render_report(scorecard) do
    local_static = get_in(scorecard, [:local, :static_proof, :score]) || %{}
    transfer_static = get_in(scorecard, [:transfer, :static_proof, :score]) || %{}
    transfer_baseline = get_in(scorecard, [:transfer, :baseline, :score]) || %{}
    pool = get_in(scorecard, [:local, :publisher, :candidate_pool]) || %{}
    qualified = get_in(scorecard, [:local, :publisher, :qualified, "score"]) || %{}
    trust = get_in(scorecard, [:local, :publisher, :trust_default, "score"]) || %{}
    leakage = scorecard.transfer.leakage || %{}

    """
    # Locked PCRS v3 Transfer Gate

    This is an unofficial local transfer gate. It does not use a Martian API, does not submit results, and does not claim benchmark rank.

    ## Lock

    - Locked commit: `#{scorecard.locked_commit}`
    - Transfer suite: `#{scorecard.transfer_suite}`
    - Transfer run: `#{scorecard.transfer_run}`
    - Source static run: `#{scorecard.source_static_run}`
    - Source publisher run: `#{scorecard.source_publisher_run}`

    ## Source Checkpoint

    | Source | Recall | Precision | F1 | Hits | Noise | Comments |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: |
    | Static proof on Martian source | #{fmt(metric(local_static, "recall"))} | #{fmt(metric(local_static, "precision"))} | #{fmt(metric(local_static, "f1"))} | #{fmt(metric(local_static, "hits"))} | #{fmt(metric(local_static, "noise"))} | #{fmt(metric(local_static, "published_claims"))} |
    | Trust publisher on Martian source | #{fmt(metric(trust, "recall"))} | #{fmt(metric(trust, "precision"))} | #{fmt(metric(trust, "f1"))} | #{fmt(metric(trust, "hits"))} | #{fmt(metric(trust, "noise"))} | #{fmt(metric(trust, "published_claims"))} |
    | Qualified publisher on Martian source | #{fmt(metric(qualified, "recall"))} | #{fmt(metric(qualified, "precision"))} | #{fmt(metric(qualified, "f1"))} | #{fmt(metric(qualified, "hits"))} | #{fmt(metric(qualified, "noise"))} | #{fmt(metric(qualified, "published_claims"))} |

    Candidate-pool recall on source: #{fmt(pool["oracle_recall"])} (#{pool["pool_hits"] || "n/a"} / #{pool["expected_claims"] || "n/a"}).

    ## Transfer Result

    | Method | Recall | Precision | F1 | Hits | Noise | Comments |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: |
    | Baseline | #{fmt(metric(transfer_baseline, :recall))} | #{fmt(metric(transfer_baseline, :precision))} | #{fmt(metric(transfer_baseline, :f1))} | #{fmt(metric(transfer_baseline, :hits))} | #{fmt(metric(transfer_baseline, :noise))} | #{fmt(metric(transfer_baseline, :published_claims))} |
    | Static proof candidate | #{fmt(metric(transfer_static, :recall))} | #{fmt(metric(transfer_static, :precision))} | #{fmt(metric(transfer_static, :f1))} | #{fmt(metric(transfer_static, :hits))} | #{fmt(metric(transfer_static, :noise))} | #{fmt(metric(transfer_static, :published_claims))} |

    ## Generalization Gap

    - Static F1 gap: #{fmt(scorecard.generalization_gap[:f1])}
    - Static precision gap: #{fmt(scorecard.generalization_gap[:precision])}
    - Static recall gap: #{fmt(scorecard.generalization_gap[:recall])}
    - Static hit gap: #{fmt(scorecard.generalization_gap[:hits])}
    - Static noise gap: #{fmt(scorecard.generalization_gap[:noise])}

    ## Skipped Sources

    #{scorecard.skipped_sources |> Enum.map(&"- `#{&1.source}`: #{&1.reason}") |> Enum.join("\n")}

    ## Leakage / Overfitting

    - Leakage fatal: #{leakage[:fatal?] || leakage["fatal?"] || false}
    - Input case-id leaks: #{inspect(leakage[:input_case_id_leaks] || leakage["input_case_id_leaks"] || [])}
    - Oracle input files: #{inspect(leakage[:oracle_input_files] || leakage["oracle_input_files"] || [])}

    #{scorecard.caveats |> Enum.map(&"- #{&1}") |> Enum.join("\n")}

    ## Decision

    #{decision(scorecard)}
    """
  end

  defp decision(scorecard) do
    transfer_static = get_in(scorecard, [:transfer, :static_proof, :score]) || %{}
    transfer_baseline = get_in(scorecard, [:transfer, :baseline, :score]) || %{}
    leakage = scorecard.transfer.leakage || %{}

    cond do
      leakage[:fatal?] || leakage["fatal?"] ->
        "Invalid due to leakage. Do not interpret metrics."

      metric(transfer_static, :hits) == 0 ->
        "Transfer failed for the locked static-proof slice: no AACR hits. Treat this as brittleness evidence and build the next reviewer variable from public transfer failures."

      metric(transfer_static, :f1) <= metric(transfer_baseline, :f1) ->
        "Transfer did not beat baseline under Sugary local scoring. Do not promote."

      true ->
        "Transfer smoke passed against the local baseline, but remains unofficial and non-general."
    end
  end

  defp metric(nil, _key), do: 0.0

  defp metric(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, to_string(key)) || 0.0
  end

  defp fmt(nil), do: "n/a"
  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)

  defp read_json(path), do: if(File.exists?(path), do: Sugary.Json.read!(path), else: nil)

  defp stringify(opts) when is_map(opts) do
    Map.new(opts, fn {key, value} -> {to_string(key), value} end)
  end

  defp stringify(opts) when is_list(opts), do: opts |> Enum.into(%{}) |> stringify()

  defp parse_int(value) when is_integer(value), do: value

  defp parse_int(value) do
    value
    |> to_string()
    |> Integer.parse()
    |> case do
      {number, _rest} -> number
      :error -> raise ArgumentError, "invalid integer #{inspect(value)}"
    end
  end
end

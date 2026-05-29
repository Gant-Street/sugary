defmodule Sugary.ScientificPilot do
  alias Sugary.Protocol.ExperimentManifest

  @root ".sugary/research/scientific-pilots"
  @version "scientific-pilot-v0"

  def run!(opts) do
    config = config(opts)
    File.mkdir_p!(@root)

    manifest = experiment_manifest(config)

    {underlying_run, method_reports, cases} =
      Sugary.Runner.run_experiment_manifest_with_reports!(manifest)

    analysis = analyze(config, method_reports, cases, underlying_run)
    out_dir = make_run_dir(config.id)
    File.mkdir_p!(out_dir)

    Sugary.Json.write!(Path.join(out_dir, "config.json"), json_safe(config))
    File.write!(Path.join(out_dir, "underlying-run.txt"), underlying_run <> "\n")

    Sugary.Json.write!(
      Path.join(out_dir, "method-scorecards.json"),
      scorecards(analysis.method_reports)
    )

    write_jsonl!(Path.join(out_dir, "paired-deltas.jsonl"), analysis.paired_deltas)
    Sugary.Json.write!(Path.join(out_dir, "bootstrap.json"), analysis.bootstrap)
    Sugary.Json.write!(Path.join(out_dir, "decision.json"), analysis.decision)

    Sugary.Json.write!(
      Path.join(out_dir, "analysis.json"),
      json_safe(Map.drop(analysis, [:method_reports]))
    )

    File.write!(Path.join(out_dir, "scientific-pilot-report.md"), render_report(analysis))

    out_dir
  end

  def analyze(config, method_reports, cases, underlying_run \\ nil) do
    reports_by_id = Map.new(method_reports, &{&1.method.id, &1})
    candidate = Map.fetch!(reports_by_id, config.candidate)
    baselines = baseline_reports(config, method_reports)
    best_baseline = Enum.max_by(baselines, &score_rank(&1.score), fn -> nil end)

    paired_deltas =
      if best_baseline do
        paired_deltas(candidate, best_baseline)
      else
        []
      end

    bootstrap = bootstrap_deltas(paired_deltas, config.bootstrap_iterations)
    unique_hits = if best_baseline, do: unique_hits(candidate, best_baseline), else: 0
    added_noise = if best_baseline, do: candidate.score.noise - best_baseline.score.noise, else: 0
    sample = sample_diagnostics(cases, config.min_cases)

    decision =
      decision(config, candidate, best_baseline, bootstrap, sample, unique_hits, added_noise)

    %{
      version: @version,
      id: config.id,
      suite: config.suite,
      split: config.split,
      limit: config.limit,
      offset: config.offset,
      experiment: config.experiment,
      underlying_run: underlying_run,
      cases: length(cases),
      expected_claims: total_expected(cases),
      candidate: summarize_report(candidate),
      best_baseline: summarize_report(best_baseline),
      method_reports: method_reports,
      baseline_ids: Enum.map(baselines, & &1.method.id),
      paired_deltas: paired_deltas,
      aggregate_delta: aggregate_delta(candidate, best_baseline),
      bootstrap: bootstrap,
      unique_hits_over_best_baseline: unique_hits,
      added_noise_over_best_baseline: added_noise,
      sample_diagnostics: sample,
      decision: decision,
      non_claims: [
        "This is an unofficial local scientific pilot, not an official benchmark score.",
        "A pilot promotion means the candidate should enter the locked promotion workflow; it is not a production default.",
        "Public benchmark results remain local and must not be reported as leaderboard performance."
      ]
    }
  end

  def bootstrap_deltas(paired_deltas, iterations \\ 500) do
    metrics = [
      :f1,
      :usefulness_adjusted_f1,
      :recall,
      :usefulness,
      :snr,
      :noise,
      :cost,
      :latency_ms
    ]

    count = length(paired_deltas)

    samples =
      if count == 0 do
        []
      else
        Enum.map(1..iterations, fn iteration ->
          sample =
            Enum.map(0..(count - 1), fn index ->
              Enum.at(paired_deltas, rem(:erlang.phash2({@version, iteration, index}), count))
            end)

          Map.new(metrics, &{&1, average_delta(sample, &1)})
        end)
      end

    Map.new(metrics, fn metric ->
      values = Enum.map(samples, &Map.fetch!(&1, metric)) |> Enum.sort()
      {metric, interval(values)}
    end)
    |> Map.put(:iterations, iterations)
    |> Map.put(:cases, count)
  end

  defp config(opts) do
    opts = normalize_opts(opts)
    experiment = Map.get(opts, "experiment")
    candidate = Map.fetch!(opts, "candidate")
    baselines = list_opt(opts, "baseline")

    if experiment in [nil, ""] and baselines == [] do
      raise ArgumentError,
            "scientific pilot requires at least one --baseline unless --experiment supplies baseline reports"
    end

    %{
      id: Map.get(opts, "id", "scientific-martian-pilot-v0"),
      experiment: experiment,
      suite: Map.get(opts, "suite", "martian-offline"),
      split: empty_to_nil(Map.get(opts, "split")),
      candidate: candidate_id(candidate),
      candidate_source: candidate,
      baselines: Enum.map(baselines, &candidate_id/1),
      baseline_sources: baselines,
      limit: optional_int(Map.get(opts, "limit", "100")),
      offset: optional_int(Map.get(opts, "offset", "0")) || 0,
      replay_mode: Map.get(opts, "replay-mode", "cache-first"),
      min_cases: parse_int(Map.get(opts, "min-cases", "100")),
      bootstrap_iterations: parse_int(Map.get(opts, "bootstrap-iterations", "500")),
      min_snr_ratio: parse_float(Map.get(opts, "min-snr-ratio", "0.9")),
      max_comments_per_pr: parse_float(Map.get(opts, "max-comments-per-pr", "3.0")),
      max_added_noise: parse_float(Map.get(opts, "max-added-noise", "0")),
      min_unique_hits: parse_int(Map.get(opts, "min-unique-hits", "1")),
      primary_metric: Map.get(opts, "primary-metric", "usefulness_adjusted_f1"),
      require_positive_ci: parse_bool(Map.get(opts, "require-positive-ci", true))
    }
  end

  defp experiment_manifest(%{experiment: experiment} = config) when is_binary(experiment) do
    manifest = Sugary.Toml.parse_file!(experiment)
    selected = MapSet.new([config.candidate | config.baselines])

    manifest
    |> Map.update!(:methods, &filter_manifest_entries(&1, selected))
    |> Map.update!(:reviewers, &filter_manifest_entries(&1 || [], selected))
    |> maybe_put(:limit, config.limit)
    |> maybe_put(:offset, config.offset)
    |> maybe_put(:split, config.split)
    |> maybe_put(:replay_mode, config.replay_mode)
  end

  defp experiment_manifest(config) do
    methods =
      [entry(config.candidate_source) | Enum.map(config.baseline_sources, &entry/1)]
      |> Enum.uniq_by(fn method -> method["id"] end)

    ExperimentManifest.new(%{
      id: "#{config.id}-experiment",
      suite: config.suite,
      split: config.split,
      limit: config.limit,
      offset: config.offset,
      replay_mode: config.replay_mode,
      methods: methods
    })
  end

  defp maybe_put(manifest, _key, value) when value in [nil, ""], do: manifest
  defp maybe_put(manifest, key, value), do: Map.put(manifest, key, value)

  defp filter_manifest_entries(entries, selected) do
    Enum.filter(entries, fn entry ->
      entry
      |> manifest_entry_id()
      |> then(&MapSet.member?(selected, &1))
    end)
  end

  defp manifest_entry_id(entry), do: field(entry, :id, "")

  defp entry(source) do
    id = candidate_id(source)

    if File.exists?(source) do
      %{"id" => id, "team" => source}
    else
      %{"id" => id, "reviewer" => source}
    end
  end

  defp baseline_reports(config, method_reports) do
    explicit = MapSet.new(config.baselines)

    method_reports
    |> Enum.reject(&(&1.method.id == config.candidate))
    |> Enum.filter(fn report ->
      MapSet.size(explicit) == 0 or MapSet.member?(explicit, report.method.id)
    end)
  end

  defp paired_deltas(candidate, baseline) do
    baseline_by_case = Map.new(baseline.results, &{&1.case.id, &1})

    candidate.results
    |> Enum.flat_map(fn candidate_result ->
      case Map.fetch(baseline_by_case, candidate_result.case.id) do
        {:ok, baseline_result} ->
          candidate_case = Sugary.Scorer.score(candidate.method.id, [candidate_result])
          baseline_case = Sugary.Scorer.score(baseline.method.id, [baseline_result])

          [
            %{
              case_id: candidate_result.case.id,
              candidate: case_score(candidate_case),
              baseline: case_score(baseline_case),
              delta: score_delta(candidate_case, baseline_case),
              candidate_hits: hit_ids(candidate_result),
              baseline_hits: hit_ids(baseline_result),
              candidate_noise: noise_keys(candidate_result),
              baseline_noise: noise_keys(baseline_result)
            }
          ]

        :error ->
          []
      end
    end)
  end

  defp aggregate_delta(_candidate, nil), do: %{}
  defp aggregate_delta(candidate, baseline), do: score_delta(candidate.score, baseline.score)

  defp score_delta(candidate, baseline) do
    %{
      f1: candidate.f1 - baseline.f1,
      usefulness_adjusted_f1:
        candidate.f1 * candidate.usefulness - baseline.f1 * baseline.usefulness,
      recall: candidate.recall - baseline.recall,
      usefulness: candidate.usefulness - baseline.usefulness,
      snr: candidate.snr - baseline.snr,
      noise: candidate.noise - baseline.noise,
      cost: candidate.cost - baseline.cost,
      latency_ms: candidate.latency_ms - baseline.latency_ms,
      avg_comments_per_pr: candidate.avg_comments_per_pr - baseline.avg_comments_per_pr,
      hits: candidate.hits - baseline.hits,
      published_claims: candidate.published_claims - baseline.published_claims
    }
  end

  defp case_score(score) do
    %{
      f1: score.f1,
      usefulness_adjusted_f1: score.f1 * score.usefulness,
      recall: score.recall,
      usefulness: score.usefulness,
      snr: score.snr,
      hits: score.hits,
      noise: score.noise,
      published_claims: score.published_claims,
      cost: score.cost,
      latency_ms: score.latency_ms
    }
  end

  defp unique_hits(candidate, baseline) do
    candidate
    |> report_hit_keys()
    |> MapSet.difference(report_hit_keys(baseline))
    |> MapSet.size()
  end

  defp report_hit_keys(report) do
    report.results
    |> Enum.flat_map(fn result ->
      hit_ids(result)
      |> Enum.map(&"#{result.case.id}::#{&1}")
    end)
    |> MapSet.new()
  end

  defp hit_ids(result) do
    result.final_claims
    |> Enum.filter(&(&1.publish_decision == "publish"))
    |> Enum.flat_map(fn claim ->
      case Sugary.ClaimMatcher.expected_claim(result.case, claim) do
        nil -> []
        expected -> [field(expected, :id)]
      end
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp noise_keys(result) do
    result.final_claims
    |> Enum.filter(&(&1.publish_decision == "publish"))
    |> Enum.reject(&Sugary.ClaimMatcher.expected_claim(result.case, &1))
    |> Enum.map(& &1.dedupe_key)
    |> Enum.sort()
  end

  defp sample_diagnostics(cases, min_cases) do
    count = length(cases)

    %{
      cases: count,
      min_cases: min_cases,
      expected_claims: total_expected(cases),
      level:
        cond do
          count >= min_cases -> "promotion_grade"
          count >= max(20, div(min_cases, 2)) -> "directional"
          true -> "too_small"
        end,
      enough_cases?: count >= min_cases
    }
  end

  defp decision(_config, _candidate, nil, _bootstrap, _sample, _unique_hits, _added_noise) do
    %{
      decision: "insufficient_evidence",
      reason: "No baseline report was available for paired comparison.",
      checks: %{}
    }
  end

  defp decision(config, candidate, baseline, bootstrap, sample, unique_hits, added_noise) do
    primary = Map.fetch!(bootstrap, String.to_atom(config.primary_metric))
    snr_floor = baseline.score.snr * config.min_snr_ratio

    checks = %{
      enough_cases: sample.enough_cases?,
      positive_primary_delta: Map.get(primary, :estimate, 0.0) > 0,
      positive_primary_ci: not config.require_positive_ci or Map.get(primary, :low, 0.0) > 0,
      no_snr_regression: candidate.score.snr >= snr_floor,
      comment_budget: candidate.score.avg_comments_per_pr <= config.max_comments_per_pr,
      unique_signal: unique_hits >= config.min_unique_hits,
      no_added_noise: added_noise <= config.max_added_noise
    }

    cond do
      not checks.enough_cases ->
        %{
          decision: "insufficient_evidence",
          reason:
            "Only #{sample.cases} cases were evaluated; minimum for promotion-grade evidence is #{sample.min_cases}.",
          checks: checks
        }

      Enum.all?(Map.values(checks)) ->
        %{
          decision: "promote_to_locked_workflow",
          reason:
            "Candidate beat the best paired baseline with positive #{config.primary_metric} confidence interval while clearing noise, SNR, comment, and unique-signal guardrails.",
          checks: checks
        }

      true ->
        %{
          decision: "reject",
          reason: rejection_reason(checks),
          checks: checks
        }
    end
  end

  defp rejection_reason(checks) do
    [
      unless(checks.positive_primary_delta, do: "primary paired delta was not positive"),
      unless(checks.positive_primary_ci, do: "primary paired confidence interval crossed zero"),
      unless(checks.no_snr_regression, do: "SNR regressed beyond allowed ratio"),
      unless(checks.comment_budget, do: "candidate exceeded comment budget"),
      unless(checks.unique_signal, do: "candidate added insufficient unique true positives"),
      unless(checks.no_added_noise, do: "candidate added net noise")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp average_delta([], _metric), do: 0.0

  defp average_delta(rows, metric) do
    rows
    |> Enum.map(&get_in(&1, [:delta, metric]))
    |> Enum.sum()
    |> Kernel./(length(rows))
  end

  defp interval([]), do: %{estimate: 0.0, low: 0.0, high: 0.0}

  defp interval(sorted) do
    %{
      estimate: percentile(sorted, 0.5),
      low: percentile(sorted, 0.025),
      high: percentile(sorted, 0.975)
    }
  end

  defp percentile(sorted, p) do
    index = min(length(sorted) - 1, max(0, floor((length(sorted) - 1) * p)))
    Enum.at(sorted, index)
  end

  defp render_report(analysis) do
    method_rows =
      analysis.method_reports
      |> Enum.map(fn report ->
        s = report.score

        "| `#{report.method.id}` | #{role(report, analysis)} | #{fmt(s.f1)} | #{fmt(s.f1 * s.usefulness)} | #{fmt(s.recall)} | #{fmt(s.usefulness)} | #{fmt(s.snr)} | #{s.hits} | #{s.noise} | #{fmt(s.avg_comments_per_pr)} | #{fmt(s.cost)} | #{s.latency_ms} |"
      end)
      |> Enum.join("\n")

    delta = analysis.aggregate_delta
    bootstrap = analysis.bootstrap
    decision = analysis.decision

    """
    # Scientific Pilot v0: #{analysis.id}

    Suite: `#{analysis.suite}`#{if analysis.split, do: " / split: `#{analysis.split}`", else: ""}

    Underlying experiment run: `#{analysis.underlying_run}`

    ## Decision

    **#{decision.decision}**: #{decision.reason}

    ## Sample Diagnostics

    - Cases: #{analysis.sample_diagnostics.cases}
    - Minimum promotion-grade cases: #{analysis.sample_diagnostics.min_cases}
    - Sample level: `#{analysis.sample_diagnostics.level}`
    - Expected claims: #{analysis.sample_diagnostics.expected_claims}

    ## Scorecards

    | Method | Role | F1 | UAF1 | Recall | Usefulness | SNR | Hits | Noise | Avg Comments | Cost | Latency ms |
    | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    #{method_rows}

    ## Best Paired Baseline

    - Candidate: `#{analysis.candidate.id}`
    - Baseline: `#{get_in(analysis, [:best_baseline, :id]) || "none"}`
    - Unique hits over baseline: #{analysis.unique_hits_over_best_baseline}
    - Added noise over baseline: #{analysis.added_noise_over_best_baseline}

    ## Aggregate Delta

    - Delta F1: #{fmt(field(delta, :f1, 0.0))}
    - Delta usefulness-adjusted F1: #{fmt(field(delta, :usefulness_adjusted_f1, 0.0))}
    - Delta recall: #{fmt(field(delta, :recall, 0.0))}
    - Delta usefulness: #{fmt(field(delta, :usefulness, 0.0))}
    - Delta SNR: #{fmt(field(delta, :snr, 0.0))}
    - Delta noise: #{fmt(field(delta, :noise, 0.0))}
    - Delta cost: #{fmt(field(delta, :cost, 0.0))}
    - Delta latency ms: #{fmt(field(delta, :latency_ms, 0))}

    ## Bootstrap 95% Intervals Over Paired Case Deltas

    - F1: #{render_interval(bootstrap.f1)}
    - Usefulness-adjusted F1: #{render_interval(bootstrap.usefulness_adjusted_f1)}
    - Recall: #{render_interval(bootstrap.recall)}
    - Usefulness: #{render_interval(bootstrap.usefulness)}
    - SNR: #{render_interval(bootstrap.snr)}
    - Noise: #{render_interval(bootstrap.noise)}
    - Cost: #{render_interval(bootstrap.cost)}
    - Latency ms: #{render_interval(bootstrap.latency_ms)}

    ## Guardrail Checks

    #{render_checks(decision.checks)}

    ## Non-Claims

    #{Enum.map_join(analysis.non_claims, "\n", &"- #{&1}")}
    """
  end

  defp role(report, analysis) do
    cond do
      report.method.id == analysis.candidate.id -> "candidate"
      analysis.best_baseline && report.method.id == analysis.best_baseline.id -> "best_baseline"
      report.method.id in analysis.baseline_ids -> "baseline"
      true -> "comparison"
    end
  end

  defp render_checks(checks) do
    checks
    |> Enum.map(fn {key, value} -> "- #{key}: #{value}" end)
    |> Enum.join("\n")
  end

  defp render_interval(interval) do
    "#{fmt(interval.estimate)} [#{fmt(interval.low)}, #{fmt(interval.high)}]"
  end

  defp scorecards(reports) do
    Enum.map(reports, fn report ->
      %{method_id: report.method.id, class: report.method.class, score: report.score}
    end)
  end

  defp summarize_report(nil), do: nil

  defp summarize_report(report) do
    %{
      id: report.method.id,
      class: report.method.class,
      score: report.score,
      failures: length(report.failures),
      reviewer_failures: Enum.count(report.results, &(&1.reviewer_result.errors not in [nil, []]))
    }
  end

  defp total_expected(cases) do
    cases
    |> Enum.map(&(Map.get(&1.oracle, :expectedClaims, []) |> length()))
    |> Enum.sum()
  end

  defp candidate_id(source) do
    if File.exists?(source), do: Path.basename(source, ".toml"), else: source
  end

  defp score_rank(score), do: {score.f1 * score.usefulness, score.f1, score.usefulness, score.snr}

  defp write_jsonl!(path, records) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Enum.map_join(records, "", &(Sugary.Json.encode!(&1) <> "\n")))
  end

  defp make_run_dir(id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(@root, "#{timestamp}-#{id}")
  end

  defp json_safe(value), do: Sugary.Json.decode!(Sugary.Json.encode!(value))

  defp normalize_opts(opts) when is_map(opts), do: opts
  defp normalize_opts(opts), do: Map.new(opts, fn {key, value} -> {to_string(key), value} end)

  defp list_opt(map, key),
    do: map |> Map.get(key, []) |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))

  defp empty_to_nil(""), do: nil
  defp empty_to_nil(value), do: value

  defp optional_int(nil), do: nil
  defp optional_int(""), do: nil
  defp optional_int(value), do: parse_int(value)

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value), do: value |> to_string() |> Integer.parse() |> elem(0)

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value * 1.0
  defp parse_float(value), do: value |> to_string() |> Float.parse() |> elem(0)

  defp parse_bool(value) when is_boolean(value), do: value
  defp parse_bool(value) when value in ["false", "FALSE", "0", "no"], do: false
  defp parse_bool(_value), do: true

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value) when is_integer(value), do: to_string(value)
  defp fmt(nil), do: "0.000"
  defp fmt(value), do: to_string(value)

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(%{} = map, key, default),
    do: Map.get(map, key) || Map.get(map, to_string(key)) || default

  defp field(_value, _key, default), do: default
end

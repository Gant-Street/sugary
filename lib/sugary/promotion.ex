defmodule Sugary.Promotion do
  alias Sugary.Protocol.ExperimentManifest

  @promotion_root ".sugary/research/promotions"
  @ledger_path ".sugary/research/holdout-ledger.jsonl"
  @default_pack_path "reviewer-packs/baseline-pack-v0.toml"

  @default_thresholds %{
    min_snr_ratio: 0.9,
    max_comments_per_pr: 3.0,
    min_unique_hits: 1,
    material_recall_regression: 0.05,
    max_category_regression: 0.35,
    min_holdout_cases: 3
  }

  def lock!(opts) do
    candidate = fetch!(opts, "candidate")
    suite = fetch!(opts, "suite")
    dev_run = fetch!(opts, "dev-run")
    out = fetch!(opts, "out")
    baseline_methods = list_opt(opts, "baseline-method")
    baseline_teams = list_opt(opts, "baseline-team")
    candidate_info = candidate_info(candidate)
    baseline_team_infos = Enum.map(baseline_teams, &candidate_info/1)
    dev_manifest = read_json_if_exists(Path.join(dev_run, "manifest.json"))
    dev_split = dev_manifest["split"] || "dev"

    lock = %{
      "id" => Path.basename(out, ".toml"),
      "candidate_id" => candidate_info.id,
      "candidate_type" => candidate_info.type,
      "candidate_path" => candidate_info.path,
      "baseline_methods" => baseline_methods,
      "baseline_team_ids" => Enum.map(baseline_team_infos, & &1.id),
      "baseline_team_paths" => Enum.map(baseline_team_infos, & &1.path),
      "suite" => suite,
      "dev_split" => dev_split,
      "dev_run" => dev_run,
      "git_sha" => git_sha() || "",
      "candidate_manifest_hash" => file_hash(candidate_info.path),
      "baseline_team_hashes" =>
        Enum.map(baseline_team_infos, &"#{&1.path}=#{file_hash(&1.path)}"),
      "reviewer_pack_path" => reviewer_pack_path(),
      "reviewer_pack_hash" => hash_if_exists(reviewer_pack_path()),
      "fixture_suite_hash" => fixture_suite_hash(suite),
      "locked_at" => timestamp(),
      "min_snr_ratio" => @default_thresholds.min_snr_ratio,
      "max_comments_per_pr" => @default_thresholds.max_comments_per_pr,
      "min_unique_hits" => @default_thresholds.min_unique_hits,
      "material_recall_regression" => @default_thresholds.material_recall_regression,
      "max_category_regression" => @default_thresholds.max_category_regression,
      "min_holdout_cases" => @default_thresholds.min_holdout_cases
    }

    out |> Path.dirname() |> File.mkdir_p!()
    File.write!(out, render_lock(lock))
    out
  end

  def run!(lock_path, opts \\ []) do
    split = Keyword.get(opts, :split, "holdout")
    lock = load_lock!(lock_path)
    promotion_dir = Path.join(@promotion_root, lock["id"])
    File.rm_rf!(promotion_dir)
    File.mkdir_p!(promotion_dir)
    File.cp!(lock_path, Path.join(promotion_dir, "lock.toml"))

    dev_summary = dev_summary(lock)
    Sugary.Json.write!(Path.join(promotion_dir, "dev-summary.json"), dev_summary)

    preflight = preflight_checks(lock, split)
    repeated = repeated_holdout_warnings(lock, split)

    if preflight.fatal? do
      decision = invalid_decision(preflight)
      leakage = leakage_report(preflight, repeated, [], [])
      write_invalid_artifacts!(promotion_dir, lock, split, decision, leakage)
      append_ledger!(lock, split, promotion_dir, decision)
      promotion_dir
    else
      execute_promotion!(promotion_dir, lock_path, lock, split, dev_summary, preflight, repeated)
    end
  end

  def promotion_decision(
        candidate_report,
        best_baseline,
        diagnostics,
        leakage,
        category_guard,
        thresholds
      ) do
    unique_hits = unique_hits(candidate_report, best_baseline)
    added_noise = candidate_report.score.noise - best_baseline.score.noise
    candidate_score = candidate_report.score
    baseline_score = best_baseline.score

    cond do
      leakage.fatal? ->
        %{
          decision: "invalid_due_to_leakage",
          reason: Enum.join(leakage.fatal_reasons, "; "),
          unique_hits_over_baseline: unique_hits,
          added_noise_over_baseline: added_noise
        }

      diagnostics.fixture_saturated ->
        %{
          decision: "invalid_due_to_saturated_holdout",
          reason: "Holdout is saturated, so it cannot support a promotion decision.",
          unique_hits_over_baseline: unique_hits,
          added_noise_over_baseline: added_noise
        }

      candidate_score.cases < thresholds.min_holdout_cases ->
        %{
          decision: "needs_more_data",
          reason: "Holdout has fewer cases than the configured minimum.",
          unique_hits_over_baseline: unique_hits,
          added_noise_over_baseline: added_noise
        }

      promotes?(candidate_score, baseline_score, unique_hits, added_noise, thresholds) ->
        %{
          decision: "promote",
          reason:
            "Candidate beat the best locked baseline without material SNR, recall, comment-budget, unique-hit, or noise regression.",
          unique_hits_over_baseline: unique_hits,
          added_noise_over_baseline: added_noise,
          category_warnings: category_guard.warnings
        }

      category_guard.fatal? ->
        %{
          decision: "reject",
          reason: "Candidate regressed materially in a required category.",
          unique_hits_over_baseline: unique_hits,
          added_noise_over_baseline: added_noise,
          category_warnings: category_guard.warnings
        }

      true ->
        %{
          decision: "reject",
          reason:
            rejection_reason(
              candidate_score,
              baseline_score,
              unique_hits,
              added_noise,
              thresholds
            ),
          unique_hits_over_baseline: unique_hits,
          added_noise_over_baseline: added_noise,
          category_warnings: category_guard.warnings
        }
    end
  end

  def bootstrap(report, iterations \\ 200) do
    results = report.results || []
    count = length(results)

    values =
      if count == 0 do
        []
      else
        Enum.map(1..iterations, fn iteration ->
          sample =
            Enum.map(0..(count - 1), fn index ->
              Enum.at(results, rem(:erlang.phash2({report.method.id, iteration, index}), count))
            end)

          Sugary.Scorer.score("#{report.method.id}-bootstrap", sample)
        end)
      end

    %{
      method_id: report.method.id,
      cases: count,
      f1: interval(values, & &1.f1),
      usefulness: interval(values, & &1.usefulness),
      snr: interval(values, & &1.snr),
      recall: interval(values, & &1.recall)
    }
  end

  def fixture_suite_hash(suite) do
    manifest_path = Path.join(["fixtures/suites", "#{suite}.toml"])

    fixture_contents =
      "fixtures/review"
      |> Path.join("**/case.json")
      |> Path.wildcard()
      |> Enum.flat_map(fn path ->
        raw = File.read!(path)

        case Sugary.Json.decode!(raw) do
          %{"suite" => ^suite} -> [{path, raw}]
          _other -> []
        end
      end)
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map(fn {path, raw} -> "#{path}\n#{raw}" end)

    ([read_if_exists(manifest_path)] ++ fixture_contents)
    |> Enum.join("\n")
    |> sha256()
  end

  def manifest_hash(path), do: file_hash(path)

  defp execute_promotion!(promotion_dir, lock_path, lock, split, dev_summary, preflight, repeated) do
    candidate_manifest = candidate_manifest(lock, split)
    baseline_manifest = baseline_manifest(lock, split)

    {candidate_run_dir, [candidate_report], cases} =
      Sugary.Runner.run_experiment_manifest_with_reports!(candidate_manifest)

    {baseline_run_dir, baseline_reports, _cases} =
      Sugary.Runner.run_experiment_manifest_with_reports!(baseline_manifest)

    copy_dir!(candidate_run_dir, Path.join(promotion_dir, "holdout-run"))
    copy_dir!(baseline_run_dir, Path.join([promotion_dir, "baseline-runs", "locked-baselines"]))

    best_baseline = Enum.max_by(baseline_reports, &score_rank(&1.score), fn -> nil end)
    method_reports = [candidate_report | baseline_reports]
    diagnostics = Sugary.Diagnostics.saturation(method_reports, cases, split)
    leakage = post_run_leakage_report(preflight, repeated, promotion_dir, cases, candidate_report)
    thresholds = thresholds(lock)
    category_guard = category_regression_guard(candidate_report, best_baseline, thresholds)

    decision =
      promotion_decision(
        candidate_report,
        best_baseline,
        diagnostics,
        leakage,
        category_guard,
        thresholds
      )

    bootstrap = %{candidate: bootstrap(candidate_report), best_baseline: bootstrap(best_baseline)}

    scorecard =
      promotion_scorecard(
        lock,
        split,
        candidate_report,
        best_baseline,
        dev_summary,
        diagnostics,
        decision,
        category_guard
      )

    Sugary.Json.write!(Path.join(promotion_dir, "promotion-scorecard.json"), scorecard)
    Sugary.Json.write!(Path.join(promotion_dir, "leakage-report.json"), leakage)
    Sugary.Json.write!(Path.join(promotion_dir, "bootstrap.json"), bootstrap)
    Sugary.Json.write!(Path.join(promotion_dir, "decision.json"), decision)

    File.write!(
      Path.join(promotion_dir, "generalization-report.md"),
      render_generalization_report(lock, lock_path, split, scorecard, leakage, bootstrap)
    )

    append_ledger!(lock, split, promotion_dir, decision)
    promotion_dir
  end

  defp candidate_manifest(lock, split) do
    ExperimentManifest.new(%{
      id: "#{lock["id"]}-candidate-holdout",
      suite: lock["suite"],
      split: split,
      methods: [
        locked_entry(lock["candidate_id"], lock["candidate_type"], lock["candidate_path"])
      ]
    })
  end

  defp baseline_manifest(lock, split) do
    method_entries =
      lock
      |> list_field("baseline_methods")
      |> Enum.map(&%{"id" => &1, "reviewer" => &1})

    team_entries =
      lock
      |> list_field("baseline_team_paths")
      |> Enum.zip(list_field(lock, "baseline_team_ids"))
      |> Enum.map(fn {path, id} -> locked_entry(id, "team", path) end)

    ExperimentManifest.new(%{
      id: "#{lock["id"]}-locked-baselines-holdout",
      suite: lock["suite"],
      split: split,
      methods: method_entries ++ team_entries
    })
  end

  defp locked_entry(id, "team", path), do: %{"id" => id, "team" => path}
  defp locked_entry(id, _method, _path), do: %{"id" => id, "reviewer" => id}

  defp promotion_scorecard(
         lock,
         split,
         candidate_report,
         best_baseline,
         dev_summary,
         diagnostics,
         decision,
         category_guard
       ) do
    %{
      promotion_id: lock["id"],
      suite: lock["suite"],
      split: split,
      candidate: %{
        id: candidate_report.method.id,
        score: candidate_report.score,
        slices: Sugary.Scorer.slices(candidate_report.method.id, candidate_report.results)
      },
      baseline_winner: %{
        id: best_baseline.method.id,
        score: best_baseline.score,
        slices: Sugary.Scorer.slices(best_baseline.method.id, best_baseline.results)
      },
      dev_result: dev_summary["candidate_score"],
      holdout_result: candidate_report.score,
      generalization_gap:
        generalization_gap(dev_summary["candidate_score"], candidate_report.score, decision),
      unique_hits_over_baseline: decision.unique_hits_over_baseline,
      added_noise_over_baseline: decision.added_noise_over_baseline,
      false_positive_trap_hits: trap_hits(candidate_report.results),
      saturation: diagnostics,
      complementarity_headroom: diagnostics.complementarity_headroom,
      category_regression_guard: category_guard,
      decision: decision
    }
  end

  defp render_generalization_report(lock, lock_path, split, scorecard, leakage, bootstrap) do
    candidate = scorecard.candidate.score
    baseline = scorecard.baseline_winner.score
    gap = scorecard.generalization_gap

    """
    # Promotion Report: #{lock["id"]}

    Lock file: `#{lock_path}`
    Suite: `#{lock["suite"]}` / split: `#{split}`

    ## Decision

    #{scorecard.decision.decision}

    Reason: #{scorecard.decision.reason}

    ## Summary

    | Item | Value |
    | --- | --- |
    | Candidate | #{scorecard.candidate.id} |
    | Baseline winner | #{scorecard.baseline_winner.id} |
    | Dev result | #{fmt_score(scorecard.dev_result)} |
    | Holdout result | #{fmt_score(candidate)} |
    | Unique hits over baseline | #{scorecard.unique_hits_over_baseline} |
    | Added noise over baseline | #{scorecard.added_noise_over_baseline} |
    | Saturated holdout | #{scorecard.saturation.fixture_saturated} |
    | Complementarity headroom | #{fmt(scorecard.complementarity_headroom)} |

    ## Holdout Metrics

    | Method | Recall | Precision | Usefulness | SNR | F1 | Avg Comments |
    | --- | --- | --- | --- | --- | --- | --- |
    | #{scorecard.candidate.id} | #{fmt(candidate.recall)} | #{fmt(candidate.precision)} | #{fmt(candidate.usefulness)} | #{fmt(candidate.snr)} | #{fmt(candidate.f1)} | #{fmt(candidate.avg_comments_per_pr)} |
    | #{scorecard.baseline_winner.id} | #{fmt(baseline.recall)} | #{fmt(baseline.precision)} | #{fmt(baseline.usefulness)} | #{fmt(baseline.snr)} | #{fmt(baseline.f1)} | #{fmt(baseline.avg_comments_per_pr)} |

    ## Generalization Gap

    - Dev F1 - holdout F1: #{fmt(gap["f1"])}
    - Dev SNR - holdout SNR: #{fmt(gap["snr"])}
    - Dev unique hits - holdout unique hits: #{fmt(gap["unique_hits"])}

    ## Bootstrap Intervals

    - Candidate F1: #{render_interval(bootstrap.candidate.f1)}
    - Candidate usefulness: #{render_interval(bootstrap.candidate.usefulness)}
    - Candidate SNR: #{render_interval(bootstrap.candidate.snr)}
    - Candidate recall: #{render_interval(bootstrap.candidate.recall)}
    - Baseline F1: #{render_interval(bootstrap.best_baseline.f1)}
    - Baseline usefulness: #{render_interval(bootstrap.best_baseline.usefulness)}
    - Baseline SNR: #{render_interval(bootstrap.best_baseline.snr)}
    - Baseline recall: #{render_interval(bootstrap.best_baseline.recall)}

    ## Leakage And Invalidation

    - Fatal: #{leakage.fatal?}
    - Fatal reasons: #{Enum.join(leakage.fatal_reasons, "; ")}
    - Warnings: #{Enum.join(leakage.warnings, "; ")}

    ## Category Guard

    #{render_category_warnings(scorecard.category_regression_guard.warnings)}

    ## Interpretation

    Dev wins are not proof. This report only supports promotion if the candidate was locked before holdout, manifests and fixtures did not change, holdout inputs stayed blinded, and the holdout gain survived against frozen baselines.
    """
  end

  defp write_invalid_artifacts!(promotion_dir, lock, split, decision, leakage) do
    Sugary.Json.write!(Path.join(promotion_dir, "promotion-scorecard.json"), %{
      promotion_id: lock["id"],
      suite: lock["suite"],
      split: split,
      decision: decision
    })

    Sugary.Json.write!(Path.join(promotion_dir, "leakage-report.json"), leakage)
    Sugary.Json.write!(Path.join(promotion_dir, "bootstrap.json"), %{})
    Sugary.Json.write!(Path.join(promotion_dir, "decision.json"), decision)

    File.write!(
      Path.join(promotion_dir, "generalization-report.md"),
      """
      # Promotion Report: #{lock["id"]}

      ## Decision

      #{decision.decision}

      Reason: #{decision.reason}
      """
    )
  end

  defp invalid_decision(preflight) do
    decision =
      if Enum.any?(preflight.fatal_reasons, &String.contains?(&1, "suite")) do
        "invalid_due_to_changed_manifest"
      else
        "invalid_due_to_changed_manifest"
      end

    %{decision: decision, reason: Enum.join(preflight.fatal_reasons, "; ")}
  end

  defp preflight_checks(lock, split) do
    checks =
      []
      |> check_hash(
        "candidate manifest changed",
        lock["candidate_manifest_hash"],
        hash_if_exists(lock["candidate_path"])
      )
      |> check_hashes("baseline team manifest changed", list_field(lock, "baseline_team_hashes"))
      |> check_hash(
        "reviewer pack changed",
        lock["reviewer_pack_hash"],
        hash_if_exists(lock["reviewer_pack_path"])
      )
      |> check_hash(
        "fixture suite changed",
        lock["fixture_suite_hash"],
        fixture_suite_hash(lock["suite"])
      )

    %{
      split: split,
      fatal?: checks != [],
      fatal_reasons: checks,
      warnings: []
    }
  end

  defp post_run_leakage_report(preflight, repeated, promotion_dir, cases, candidate_report) do
    input_leaks = holdout_input_leaks(promotion_dir, cases)

    diagnostic_warnings =
      Sugary.Diagnostics.anti_overfitting_warnings([candidate_report], cases, "holdout")
      |> Enum.map(&"#{&1.type}: #{&1.summary}")

    fatal_reasons =
      preflight.fatal_reasons ++ Enum.map(input_leaks, &"holdout input leaked case id #{&1}")

    %{
      fatal?: fatal_reasons != [],
      fatal_reasons: fatal_reasons,
      warnings: preflight.warnings ++ repeated ++ diagnostic_warnings,
      input_leaks: input_leaks,
      exact_oracle_or_case_name_warnings: diagnostic_warnings
    }
  end

  defp leakage_report(preflight, repeated, input_leaks, diagnostic_warnings) do
    %{
      fatal?: preflight.fatal?,
      fatal_reasons: preflight.fatal_reasons,
      warnings: preflight.warnings ++ repeated ++ diagnostic_warnings,
      input_leaks: input_leaks,
      exact_oracle_or_case_name_warnings: diagnostic_warnings
    }
  end

  defp holdout_input_leaks(promotion_dir, cases) do
    case_ids = Enum.map(cases, & &1.id)

    promotion_dir
    |> Path.join("**/input-bundles/*.json")
    |> Path.wildcard()
    |> Enum.flat_map(fn path ->
      body = File.read!(path)
      Enum.filter(case_ids, &String.contains?(body, &1))
    end)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp check_hash(reasons, _label, "", _actual), do: reasons
  defp check_hash(reasons, _label, nil, _actual), do: reasons

  defp check_hash(reasons, label, expected, actual) do
    if expected == actual do
      reasons
    else
      ["#{label}: expected #{expected}, got #{actual}" | reasons]
    end
  end

  defp check_hashes(reasons, label, hash_entries) do
    Enum.reduce(hash_entries, reasons, fn entry, acc ->
      case String.split(entry, "=", parts: 2) do
        [path, expected] -> check_hash(acc, "#{label} #{path}", expected, hash_if_exists(path))
        _other -> ["invalid hash entry #{entry}" | acc]
      end
    end)
  end

  defp repeated_holdout_warnings(lock, split) do
    if File.exists?(@ledger_path) do
      @ledger_path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Sugary.Json.decode!/1)
      |> Enum.filter(
        &(&1["suite"] == lock["suite"] and &1["split"] == split and
            &1["candidate_id"] == lock["candidate_id"])
      )
      |> case do
        [] ->
          []

        matches ->
          ["same candidate/suite holdout has already been run #{length(matches)} time(s)"]
      end
    else
      []
    end
  end

  defp append_ledger!(lock, split, promotion_dir, decision) do
    @ledger_path |> Path.dirname() |> File.mkdir_p!()

    entry = %{
      timestamp: timestamp(),
      suite: lock["suite"],
      split: split,
      candidate_id: lock["candidate_id"],
      lock_file: Path.join(promotion_dir, "lock.toml"),
      run_id: Path.basename(promotion_dir),
      git_sha: git_sha() || "",
      result_summary: decision.reason,
      decision: decision.decision
    }

    File.write!(@ledger_path, Sugary.Json.encode!(entry) <> "\n", [:append])
  end

  defp dev_summary(lock) do
    run = lock["dev_run"]
    scores = read_json_if_exists(Path.join(run, "scores.json")) || []
    manifest = read_json_if_exists(Path.join(run, "manifest.json")) || %{}
    saturation = read_json_if_exists(Path.join(run, "saturation-diagnostics.json"))
    candidate_method_id = dev_candidate_method_id(manifest, lock)

    candidate_score =
      Enum.find(scores, &(&1["method_id"] == candidate_method_id)) || best_score(scores)

    %{
      "dev_run" => run,
      "dev_split" => lock["dev_split"],
      "candidate_method_id" => candidate_method_id,
      "candidate_score" => candidate_score && candidate_score["score"],
      "scores" => scores,
      "saturation" => saturation
    }
  end

  defp dev_candidate_method_id(manifest, lock) do
    manifest
    |> Map.get("methods", [])
    |> Enum.find(fn method ->
      method["team"] == lock["candidate_path"] or method["reviewer"] == lock["candidate_id"] or
        method["id"] == lock["candidate_id"]
    end)
    |> case do
      nil -> lock["candidate_id"]
      method -> method["id"] || lock["candidate_id"]
    end
  end

  defp best_score([]), do: nil

  defp best_score(scores) do
    Enum.max_by(scores, fn score ->
      s = score["score"]
      {s["f1"], s["usefulness"], s["snr"]}
    end)
  end

  defp generalization_gap(nil, holdout_score, _decision),
    do: %{
      "f1" => nil,
      "snr" => nil,
      "unique_hits" => nil,
      "holdout_f1" => holdout_score.f1
    }

  defp generalization_gap(dev_score, holdout_score, _decision) do
    %{
      "f1" => Map.get(dev_score, "f1", 0.0) - holdout_score.f1,
      "snr" => Map.get(dev_score, "snr", 0.0) - holdout_score.snr,
      "unique_hits" => nil,
      "holdout_f1" => holdout_score.f1
    }
  end

  defp category_regression_guard(candidate_report, baseline_report, thresholds) do
    candidate = Sugary.Scorer.slices(candidate_report.method.id, candidate_report.results)
    baseline = Sugary.Scorer.slices(baseline_report.method.id, baseline_report.results)
    candidate_categories = candidate.category || %{}
    baseline_categories = baseline.category || %{}

    warnings =
      (Map.keys(candidate_categories) ++ Map.keys(baseline_categories))
      |> Enum.uniq()
      |> Enum.flat_map(fn category ->
        c =
          get_in(candidate_categories, [category, :recall]) ||
            get_in(candidate_categories, [category, "recall"]) || 0.0

        b =
          get_in(baseline_categories, [category, :recall]) ||
            get_in(baseline_categories, [category, "recall"]) || 0.0

        delta = b - c

        if delta > thresholds.max_category_regression do
          [%{category: category, baseline_recall: b, candidate_recall: c, regression: delta}]
        else
          []
        end
      end)

    %{fatal?: warnings != [], warnings: warnings}
  end

  defp trap_hits(results) do
    Enum.flat_map(results, fn result ->
      traps =
        result.case.oracle
        |> Map.get(:knownNonIssues, [])
        |> MapSet.new(& &1.id)

      result.final_claims
      |> Enum.filter(&(&1.publish_decision == "publish"))
      |> Enum.filter(&MapSet.member?(traps, &1.dedupe_key))
      |> Enum.map(&%{case_id: result.case.id, trap: &1.dedupe_key})
    end)
  end

  defp unique_hits(candidate_report, baseline_report) do
    candidate_report
    |> hit_keys()
    |> MapSet.difference(hit_keys(baseline_report))
    |> MapSet.size()
  end

  defp hit_keys(report) do
    report.results
    |> Enum.flat_map(fn result ->
      expected =
        result.case.oracle
        |> Map.get(:expectedClaims, [])
        |> MapSet.new(& &1.id)

      result.final_claims
      |> Enum.filter(&(&1.publish_decision == "publish"))
      |> Enum.filter(&MapSet.member?(expected, &1.dedupe_key))
      |> Enum.map(&"#{result.case.id}::#{&1.dedupe_key}")
    end)
    |> MapSet.new()
  end

  defp promotes?(candidate, baseline, unique_hits, added_noise, thresholds) do
    beats =
      candidate.f1 > baseline.f1 or
        candidate.f1 * candidate.usefulness > baseline.f1 * baseline.usefulness

    recall_ok = candidate.recall >= baseline.recall - thresholds.material_recall_regression
    snr_ok = candidate.snr >= baseline.snr * thresholds.min_snr_ratio
    comments_ok = candidate.avg_comments_per_pr <= thresholds.max_comments_per_pr
    unique_ok = unique_hits >= thresholds.min_unique_hits
    noise_ok = added_noise <= 0

    beats and recall_ok and snr_ok and comments_ok and unique_ok and noise_ok
  end

  defp rejection_reason(candidate, baseline, unique_hits, added_noise, thresholds) do
    [
      unless(
        candidate.f1 > baseline.f1 or
          candidate.f1 * candidate.usefulness > baseline.f1 * baseline.usefulness,
        do: "candidate did not beat best locked baseline"
      ),
      unless(candidate.recall >= baseline.recall - thresholds.material_recall_regression,
        do: "candidate recall regressed materially"
      ),
      unless(candidate.snr >= baseline.snr * thresholds.min_snr_ratio,
        do: "candidate SNR regressed >10%"
      ),
      unless(candidate.avg_comments_per_pr <= thresholds.max_comments_per_pr,
        do: "candidate exceeded comment budget"
      ),
      unless(unique_hits >= thresholds.min_unique_hits,
        do: "candidate added no unique true positive"
      ),
      unless(added_noise <= 0, do: "candidate added net noise")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join("; ")
  end

  defp interval([], _fun), do: %{estimate: 0.0, low: 0.0, high: 0.0}

  defp interval(values, fun) do
    sorted = values |> Enum.map(fun) |> Enum.sort()

    %{
      estimate: median(sorted),
      low: percentile(sorted, 0.025),
      high: percentile(sorted, 0.975)
    }
  end

  defp percentile(sorted, p) do
    index = min(length(sorted) - 1, max(0, floor((length(sorted) - 1) * p)))
    Enum.at(sorted, index)
  end

  defp median(sorted), do: percentile(sorted, 0.5)

  defp candidate_info(path_or_id) do
    cond do
      File.exists?(path_or_id) ->
        team = Sugary.Teams.load!(path_or_id)
        %{id: team.id, type: "team", path: path_or_id}

      true ->
        %{id: path_or_id, type: "method", path: ""}
    end
  end

  defp thresholds(lock) do
    %{
      min_snr_ratio: number_field(lock, "min_snr_ratio", @default_thresholds.min_snr_ratio),
      max_comments_per_pr:
        number_field(lock, "max_comments_per_pr", @default_thresholds.max_comments_per_pr),
      min_unique_hits: number_field(lock, "min_unique_hits", @default_thresholds.min_unique_hits),
      material_recall_regression:
        number_field(
          lock,
          "material_recall_regression",
          @default_thresholds.material_recall_regression
        ),
      max_category_regression:
        number_field(lock, "max_category_regression", @default_thresholds.max_category_regression),
      min_holdout_cases:
        number_field(lock, "min_holdout_cases", @default_thresholds.min_holdout_cases)
    }
  end

  defp load_lock!(path), do: Sugary.Toml.parse_file_raw!(path)
  defp fetch!(map, key), do: Map.fetch!(map, key)

  defp list_opt(map, key),
    do: map |> Map.get(key, []) |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))

  defp list_field(map, key),
    do: map |> Map.get(key, []) |> List.wrap() |> Enum.reject(&(&1 in [nil, ""]))

  defp number_field(map, key, default), do: Map.get(map, key, default) || default

  defp reviewer_pack_path do
    if File.exists?(@default_pack_path), do: @default_pack_path, else: ""
  end

  defp hash_if_exists(""), do: ""
  defp hash_if_exists(nil), do: ""
  defp hash_if_exists(path), do: if(File.exists?(path), do: file_hash(path), else: "")
  defp file_hash(""), do: ""
  defp file_hash(path), do: path |> File.read!() |> sha256()
  defp read_if_exists(path), do: if(File.exists?(path), do: File.read!(path), else: "")

  defp sha256(binary) do
    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
  end

  defp git_sha do
    case System.cmd("git", ["rev-parse", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> nil
    end
  rescue
    _error -> nil
  end

  defp timestamp do
    DateTime.utc_now()
    |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ")
  end

  defp copy_dir!(source, dest) do
    File.rm_rf!(dest)
    dest |> Path.dirname() |> File.mkdir_p!()
    File.cp_r!(source, dest)
  end

  defp read_json_if_exists(path),
    do: if(File.exists?(path), do: Sugary.Json.read!(path), else: nil)

  defp score_rank(score), do: {score.f1, score.usefulness, score.snr}

  defp render_lock(lock) do
    """
    id = #{q(lock["id"])}
    candidate_id = #{q(lock["candidate_id"])}
    candidate_type = #{q(lock["candidate_type"])}
    candidate_path = #{q(lock["candidate_path"])}
    baseline_methods = #{array(lock["baseline_methods"])}
    baseline_team_ids = #{array(lock["baseline_team_ids"])}
    baseline_team_paths = #{array(lock["baseline_team_paths"])}
    suite = #{q(lock["suite"])}
    dev_split = #{q(lock["dev_split"])}
    dev_run = #{q(lock["dev_run"])}
    git_sha = #{q(lock["git_sha"])}
    candidate_manifest_hash = #{q(lock["candidate_manifest_hash"])}
    baseline_team_hashes = #{array(lock["baseline_team_hashes"])}
    reviewer_pack_path = #{q(lock["reviewer_pack_path"])}
    reviewer_pack_hash = #{q(lock["reviewer_pack_hash"])}
    fixture_suite_hash = #{q(lock["fixture_suite_hash"])}
    locked_at = #{q(lock["locked_at"])}
    min_snr_ratio = #{lock["min_snr_ratio"]}
    max_comments_per_pr = #{lock["max_comments_per_pr"]}
    min_unique_hits = #{lock["min_unique_hits"]}
    material_recall_regression = #{lock["material_recall_regression"]}
    max_category_regression = #{lock["max_category_regression"]}
    min_holdout_cases = #{lock["min_holdout_cases"]}
    """
  end

  defp q(value), do: "\"" <> (value |> to_string() |> String.replace("\"", "\\\"")) <> "\""
  defp array(values), do: "[" <> (values |> Enum.map(&q/1) |> Enum.join(", ")) <> "]"

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(nil), do: "n/a"
  defp fmt(value), do: to_string(value)

  defp fmt_score(nil), do: "n/a"

  defp fmt_score(%Sugary.Protocol.Scorecard{} = score),
    do: "F1 #{fmt(score.f1)}, SNR #{fmt(score.snr)}"

  defp fmt_score(score), do: "F1 #{fmt(score["f1"])}, SNR #{fmt(score["snr"])}"

  defp render_interval(interval) do
    "#{fmt(interval.estimate)} [#{fmt(interval.low)}, #{fmt(interval.high)}]"
  end

  defp render_category_warnings([]), do: "- none"

  defp render_category_warnings(warnings) do
    warnings
    |> Enum.map(fn warning ->
      "- #{warning.category}: baseline recall #{fmt(warning.baseline_recall)}, candidate recall #{fmt(warning.candidate_recall)}"
    end)
    |> Enum.join("\n")
  end
end

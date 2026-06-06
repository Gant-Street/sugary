defmodule Sugary.PersistentMemoryGauntlet do
  @default_id "h5i-persistent-memory-gauntlet-v0"
  @default_suite "martian-offline"
  @default_train_limit 3
  @default_eval_limit 3
  @default_train_offset 0
  @default_team "teams/public-pcrs-static-codex-low-team.toml"
  @default_replay_mode "cache-first"
  @comment_budget 3

  alias Sugary.Protocol.{ExperimentManifest, ReviewerResult}

  def run!(opts \\ %{}) do
    opts = normalize_opts(opts)
    id = Map.get(opts, "id", @default_id)
    suite = Map.get(opts, "suite", @default_suite)
    train_limit = opts |> Map.get("train-limit", @default_train_limit) |> parse_int()
    eval_limit = opts |> Map.get("eval-limit", @default_eval_limit) |> parse_int()
    train_offset = opts |> Map.get("train-offset", @default_train_offset) |> parse_int()
    eval_offset = opts |> Map.get("eval-offset", train_offset + train_limit) |> parse_int()
    team_path = Map.get(opts, "team", @default_team)
    replay_mode = Map.get(opts, "replay-mode", @default_replay_mode)
    h5i? = truthy?(Map.get(opts, "h5i", "true"))

    gauntlet_dir = make_gauntlet_dir(id)
    File.mkdir_p!(gauntlet_dir)

    train_manifest =
      manifest(id, suite, train_limit, train_offset, team_path, replay_mode, "train")

    eval_manifest = manifest(id, suite, eval_limit, eval_offset, team_path, replay_mode, "eval")

    {train_run_dir, train_reports, train_cases} =
      Sugary.Runner.run_experiment_manifest_with_reports!(train_manifest)

    train_stateless_report = find_report!(train_reports, "stateless-team")

    train_normalized_results =
      apply_memory_variant(
        train_stateless_report.results,
        empty_memory(),
        "train-stateless-normalized-team"
      )

    memory = build_memory(train_normalized_results, train_cases)
    shuffled_memory = shuffle_memory(memory)
    memory_path = Path.join(gauntlet_dir, "h5i-memory.json")
    shuffled_path = Path.join(gauntlet_dir, "shuffled-memory.json")
    Sugary.Json.write!(memory_path, memory)
    Sugary.Json.write!(shuffled_path, shuffled_memory)

    h5i_events = mirror_memory_to_h5i(memory, gauntlet_dir, h5i?)

    bus =
      Sugary.AgentBus.new!(
        id: "#{Path.basename(gauntlet_dir)}-persistent-memory",
        requested_backend: if(h5i?, do: "h5i", else: "local-jsonl"),
        root: Path.join(gauntlet_dir, "agent-bus")
      )

    {eval_run_dir, eval_reports, eval_cases} =
      Sugary.Runner.run_experiment_manifest_with_reports!(eval_manifest)

    route_eval_cases!(bus, eval_cases, memory)

    stateless_report = find_report!(eval_reports, "stateless-team")

    stateless_normalized_results =
      apply_memory_variant(stateless_report.results, empty_memory(), "stateless-normalized-team")

    stateless_normalized_report =
      report_from_results("stateless-normalized-team", stateless_normalized_results)

    memory_results =
      apply_memory_variant(stateless_report.results, memory, "h5i-persistent-memory-team")

    shuffled_results =
      apply_memory_variant(
        stateless_report.results,
        shuffled_memory,
        "shuffled-memory-control-team"
      )

    memory_report = report_from_results("h5i-persistent-memory-team", memory_results)
    shuffled_report = report_from_results("shuffled-memory-control-team", shuffled_results)

    all_reports = eval_reports ++ [stateless_normalized_report, memory_report, shuffled_report]
    leakage = leakage_report(memory_path, eval_run_dir, eval_cases)
    bus_summary = Sugary.AgentBus.summary(bus)

    scorecard =
      scorecard(%{
        id: id,
        suite: suite,
        gauntlet_dir: gauntlet_dir,
        train_run_dir: train_run_dir,
        eval_run_dir: eval_run_dir,
        train_limit: train_limit,
        eval_limit: eval_limit,
        train_offset: train_offset,
        eval_offset: eval_offset,
        team_path: team_path,
        replay_mode: replay_mode,
        h5i_enabled: h5i?,
        memory_path: memory_path,
        shuffled_memory_path: shuffled_path,
        memory: memory,
        h5i_events: h5i_events,
        bus_summary: bus_summary,
        reports: all_reports,
        stateless_report: stateless_normalized_report,
        original_stateless_report: stateless_report,
        memory_report: memory_report,
        shuffled_report: shuffled_report,
        leakage: leakage
      })

    write_artifacts!(gauntlet_dir, %{
      train_run_dir: train_run_dir,
      eval_run_dir: eval_run_dir,
      train_manifest: train_manifest,
      eval_manifest: eval_manifest,
      train_reports: train_reports,
      eval_reports: eval_reports,
      memory_report: memory_report,
      shuffled_report: shuffled_report,
      scorecard: scorecard,
      leakage: leakage,
      bus_summary: bus_summary
    })

    Sugary.AgentBus.append!(bus, %{
      type: "ORCHESTRATION_DONE",
      from: "sugary-orchestrator",
      to: "researcher",
      suite: suite,
      payload: %{
        decision: scorecard.decision,
        eval_run_dir: eval_run_dir,
        memory_score: scorecard.methods["h5i-persistent-memory-team"],
        stateless_score: scorecard.methods["stateless-normalized-team"]
      }
    })

    gauntlet_dir
  end

  defp manifest(id, suite, limit, offset, team_path, replay_mode, phase) do
    ExperimentManifest.new(%{
      id: "#{id}-#{phase}",
      description:
        "Persistent-memory gauntlet #{phase} phase. Public benchmark results are unofficial local smoke only.",
      suite: suite,
      limit: limit,
      offset: offset,
      replay_mode: replay_mode,
      methods: [
        %{"id" => "baseline-diff-only", "reviewer" => "baseline-diff-only"},
        %{"id" => "public-static-proof-gate", "reviewer" => "public-static-proof-gate"},
        %{"id" => "stateless-team", "team" => team_path}
      ]
    })
  end

  defp build_memory(train_results, train_cases) do
    entries =
      train_results
      |> Enum.flat_map(fn result ->
        result.final_claims
        |> Enum.filter(&(field(&1, :publish_decision) == "publish"))
        |> Enum.map(&memory_entry(result.case, &1))
      end)

    positives = Enum.filter(entries, &(&1.outcome == "hit"))
    negatives = Enum.filter(entries, &(&1.outcome == "noise"))

    %{
      id: memory_id(entries),
      backend: "h5i",
      source: "train_split_review_feedback",
      suite: "martian-offline",
      train_cases: length(train_cases),
      created_at: DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ"),
      rules: %{
        no_eval_oracle: true,
        no_source_case_ids: true,
        generated_claim_text_only: true
      },
      summary: %{
        positive_lessons: length(positives),
        negative_lessons: length(negatives),
        categories: entries |> Enum.map(& &1.category) |> Enum.frequencies()
      },
      positive_lessons: positives,
      negative_lessons: negatives
    }
  end

  defp empty_memory do
    %{
      id: "no-memory",
      backend: "none",
      source: "stateless_normalized_control",
      positive_lessons: [],
      negative_lessons: [],
      summary: %{positive_lessons: 0, negative_lessons: 0, categories: %{}}
    }
  end

  defp memory_entry(bench_case, claim) do
    outcome =
      if Sugary.ClaimMatcher.expected_claim(bench_case, claim), do: "hit", else: "noise"

    %{
      id: hash([field(claim, :dedupe_key), field(claim, :claim), outcome] |> Enum.join(":")),
      outcome: outcome,
      category: field(claim, :category, "bug"),
      severity: field(claim, :severity, "medium"),
      path: field(claim, :path, "unknown"),
      path_basename: field(claim, :path, "unknown") |> Path.basename(),
      source_claim_dedupe_key: field(claim, :dedupe_key, ""),
      source_claim_summary: field(claim, :claim, "") |> truncate(220),
      tokens: tokens(claim_text(claim)),
      evidence:
        "Prior train-split review feedback on Sugary-generated claim; oracle wording and case ids are not persisted."
    }
  end

  defp shuffle_memory(memory) do
    entries = memory.positive_lessons ++ memory.negative_lessons
    shuffled = rotate(entries)

    remap =
      entries
      |> Enum.zip(shuffled)
      |> Map.new(fn {entry, replacement} -> {entry.id, replacement} end)

    shuffle_entry = fn entry ->
      replacement = Map.fetch!(remap, entry.id)

      %{
        entry
        | id: "shuffled-#{entry.id}",
          category: replacement.category,
          path: replacement.path,
          path_basename: replacement.path_basename,
          tokens: replacement.tokens,
          source_claim_dedupe_key: replacement.source_claim_dedupe_key,
          source_claim_summary: "SHUFFLED CONTROL: #{replacement.source_claim_summary}"
      }
    end

    %{
      memory
      | id: "shuffled-#{memory.id}",
        backend: "h5i-negative-control",
        source: "shuffled_train_split_review_feedback",
        positive_lessons: Enum.map(memory.positive_lessons, shuffle_entry),
        negative_lessons: Enum.map(memory.negative_lessons, shuffle_entry)
    }
  end

  defp rotate([]), do: []
  defp rotate([one]), do: [one]
  defp rotate([first | rest]), do: rest ++ [first]

  defp apply_memory_variant(results, memory, method_id) do
    Enum.map(results, fn result ->
      candidates =
        result.candidate_claims
        |> Enum.map(&annotate_memory(&1, memory))

      final_claims = publish_with_memory(candidates)

      reviewer_result =
        ReviewerResult.new(%{
          reviewer_id: method_id,
          method_id: method_id,
          class: "h5i_memory_team",
          claims: final_claims,
          cost: result.reviewer_result.cost || 0.0,
          latency_ms: result.reviewer_result.latency_ms || 0,
          artifacts: [
            %{
              adapter: "h5i_memory",
              memory_id: memory.id,
              source: memory.source,
              positive_lessons: length(memory.positive_lessons),
              negative_lessons: length(memory.negative_lessons)
            }
          ],
          errors: []
        })

      %{
        result
        | reviewer_result: reviewer_result,
          candidate_claims: candidates,
          final_claims: final_claims
      }
    end)
  end

  defp annotate_memory(claim, memory) do
    positive_score = memory_match_score(claim, memory.positive_lessons)
    negative_score = memory_match_score(claim, memory.negative_lessons)
    source = field(claim, :source, %{}) |> put_string_or_atom(:h5i_memory_id, memory.id)

    claim
    |> put_string_or_atom(:source, source)
    |> put_string_or_atom(:memory_positive_score, positive_score)
    |> put_string_or_atom(:memory_negative_score, negative_score)
    |> maybe_add_memory_evidence(positive_score, negative_score)
  end

  defp maybe_add_memory_evidence(claim, positive_score, negative_score) do
    if max(positive_score, negative_score) >= 0.55 do
      evidence = field(claim, :evidence, []) |> List.wrap()

      memory_evidence = %{
        type: "h5i_memory",
        tier: 4,
        strength: if(positive_score >= negative_score, do: "medium", else: "refuting"),
        summary:
          "h5i memory matched prior #{if positive_score >= negative_score, do: "hit", else: "noise"} pattern."
      }

      put_string_or_atom(claim, :evidence, evidence ++ [memory_evidence])
    else
      claim
    end
  end

  defp publish_with_memory(candidates) do
    candidates
    |> Enum.map(fn claim ->
      if field(claim, :memory_negative_score, 0.0) >= 0.58 do
        claim
        |> put_string_or_atom(:publish_decision, "suppress")
        |> put_string_or_atom(:suppressed_reason, "h5i_memory_prior_noise")
      else
        claim
        |> put_string_or_atom(:publish_decision, "candidate")
        |> put_string_or_atom(:suppressed_reason, nil)
      end
    end)
    |> Enum.sort_by(&memory_rank/1, :desc)
    |> Enum.with_index()
    |> Enum.map(fn {claim, index} ->
      cond do
        field(claim, :publish_decision) == "suppress" ->
          claim

        index < @comment_budget ->
          put_string_or_atom(claim, :publish_decision, "publish")

        true ->
          claim
          |> put_string_or_atom(:publish_decision, "suppress")
          |> put_string_or_atom(:suppressed_reason, "comment_budget")
      end
    end)
  end

  defp memory_rank(claim) do
    base_rank(claim) + field(claim, :memory_positive_score, 0.0) * 2.0 -
      field(claim, :memory_negative_score, 0.0) * 3.0
  end

  defp base_rank(claim) do
    severity =
      %{"critical" => 4, "high" => 3, "medium" => 2, "low" => 1}
      |> Map.get(field(claim, :severity, "medium"), 1)

    tier = claim |> field(:evidence, []) |> List.wrap() |> List.first(%{}) |> field(:tier, 5)
    field(claim, :confidence, 0.5) * severity * (6 - tier)
  end

  defp memory_match_score(_claim, []), do: 0.0

  defp memory_match_score(claim, lessons) do
    claim_tokens = claim |> claim_text() |> tokens() |> MapSet.new()
    category = field(claim, :category, "")
    path = field(claim, :path, "")
    basename = Path.basename(path)

    lessons
    |> Enum.map(fn lesson ->
      lesson_tokens = MapSet.new(lesson.tokens)

      token_score =
        ratio(
          MapSet.intersection(claim_tokens, lesson_tokens) |> MapSet.size(),
          max(MapSet.size(lesson_tokens), 1)
        )

      category_bonus = if lesson.category == category, do: 0.15, else: 0.0
      path_bonus = if lesson.path == path or lesson.path_basename == basename, do: 0.15, else: 0.0
      min(1.0, token_score + category_bonus + path_bonus)
    end)
    |> Enum.max(fn -> 0.0 end)
  end

  defp report_from_results(method_id, results) do
    score = Sugary.Scorer.score(method_id, results)
    failures = Sugary.Scorer.failures(method_id, results)

    %{
      method: %{id: method_id, class: "h5i_memory_team", type: "team"},
      score: score,
      failures: failures,
      results: results
    }
  end

  defp scorecard(attrs) do
    methods = Map.new(attrs.reports, &{&1.method.id, score_summary(&1.score)})
    stateless = attrs.stateless_report.score
    memory = attrs.memory_report.score
    shuffled = attrs.shuffled_report.score
    unique_hits = unique_hits(attrs.memory_report.results, attrs.stateless_report.results)

    shuffled_unique_hits =
      unique_hits(attrs.shuffled_report.results, attrs.stateless_report.results)

    added_noise = memory.noise - stateless.noise
    decision = decision(memory, stateless, shuffled, unique_hits, added_noise, attrs.leakage)

    %{
      id: attrs.id,
      suite: attrs.suite,
      unofficial: true,
      gauntlet_dir: attrs.gauntlet_dir,
      train_run_dir: attrs.train_run_dir,
      eval_run_dir: attrs.eval_run_dir,
      train_limit: attrs.train_limit,
      eval_limit: attrs.eval_limit,
      train_offset: attrs.train_offset,
      eval_offset: attrs.eval_offset,
      team_path: attrs.team_path,
      replay_mode: attrs.replay_mode,
      h5i_enabled: attrs.h5i_enabled,
      memory_path: attrs.memory_path,
      shuffled_memory_path: attrs.shuffled_memory_path,
      memory_summary: attrs.memory.summary,
      h5i_events: attrs.h5i_events,
      agent_bus: attrs.bus_summary,
      methods: methods,
      comparison: %{
        memory_vs_stateless_f1_delta: memory.f1 - stateless.f1,
        memory_vs_stateless_usefulness_delta: memory.usefulness - stateless.usefulness,
        memory_vs_stateless_snr_delta: memory.snr - stateless.snr,
        memory_vs_stateless_avg_comments_delta:
          memory.avg_comments_per_pr - stateless.avg_comments_per_pr,
        memory_vs_shuffled_f1_delta: memory.f1 - shuffled.f1,
        memory_unique_hits_over_stateless: unique_hits,
        shuffled_unique_hits_over_stateless: shuffled_unique_hits,
        added_noise_over_stateless: added_noise
      },
      leakage: attrs.leakage,
      decision: decision,
      claim_level:
        "Controlled local smoke. This validates/invalidate h5i memory only for this Martian subset; it is not an official benchmark score."
    }
  end

  defp decision(_memory, _stateless, _shuffled, _unique_hits, _added_noise, %{fatal?: true}),
    do: "invalid_due_to_memory_or_input_leakage"

  defp decision(memory, stateless, shuffled, unique_hits, added_noise, _leakage) do
    cond do
      memory.f1 > stateless.f1 and memory.f1 > shuffled.f1 and unique_hits > 0 and
        added_noise <= 0 and memory.snr >= stateless.snr * 0.9 ->
        "validate_h5i_memory_lift"

      memory.f1 <= stateless.f1 and memory.f1 <= shuffled.f1 ->
        "invalidate_h5i_memory_lift"

      true ->
        "inconclusive_h5i_memory_lift"
    end
  end

  defp unique_hits(left_results, right_results) do
    left = hit_ids(left_results)
    right = hit_ids(right_results)
    MapSet.difference(left, right) |> MapSet.size()
  end

  defp hit_ids(results) do
    results
    |> Enum.flat_map(fn result ->
      result.final_claims
      |> Enum.filter(&(field(&1, :publish_decision) == "publish"))
      |> Enum.flat_map(fn claim ->
        case Sugary.ClaimMatcher.expected_claim(result.case, claim) do
          nil -> []
          expected -> [field(expected, :id)]
        end
      end)
    end)
    |> MapSet.new()
  end

  defp route_eval_cases!(bus, eval_cases, memory) do
    eval_cases
    |> Enum.with_index(1)
    |> Enum.each(fn {bench_case, index} ->
      Sugary.AgentBus.append!(bus, %{
        type: "REVIEW_REQUEST",
        from: "sugary-orchestrator",
        to: "persistent-memory-publisher",
        branch: "HEAD",
        risk: "h5i memory may suppress useful claims or preserve stale false positives",
        summary: "Apply locked h5i memory #{memory.id} to blind Martian case #{index}.",
        suite: bench_case.suite,
        case_id: "blind-eval-case-#{index}",
        payload: %{
          blind_case_id: "blind-eval-case-#{index}",
          focus_paths: changed_files(bench_case),
          memory_id: memory.id,
          memory_positive_lessons: length(memory.positive_lessons),
          memory_negative_lessons: length(memory.negative_lessons)
        }
      })
    end)
  end

  defp mirror_memory_to_h5i(memory, gauntlet_dir, false) do
    events = [%{status: "skipped", reason: "h5i disabled", memory_id: memory.id}]
    write_jsonl!(Path.join(gauntlet_dir, "h5i-memory-events.jsonl"), events)
    events
  end

  defp mirror_memory_to_h5i(memory, gauntlet_dir, true) do
    path = Path.join(gauntlet_dir, "h5i-memory-events.jsonl")

    event =
      case System.find_executable("h5i") do
        nil ->
          %{status: "skipped", reason: "h5i executable unavailable", memory_id: memory.id}

        h5i ->
          text =
            "Sugary persistent-memory gauntlet built memory #{memory.id}: #{memory.summary.positive_lessons} positive lessons, #{memory.summary.negative_lessons} negative lessons. No eval oracle or source case ids persisted."

          case System.cmd(h5i, ["context", "trace", "--kind", "NOTE", text],
                 stderr_to_stdout: true
               ) do
            {stdout, 0} ->
              %{status: "mirrored", memory_id: memory.id, stdout: stdout}

            {stdout, exit_status} ->
              %{
                status: "mirror_failed",
                memory_id: memory.id,
                exit_status: exit_status,
                stdout: stdout
              }
          end
      end

    write_jsonl!(path, [event])
    [event]
  end

  defp leakage_report(memory_path, eval_run_dir, eval_cases) do
    memory_text = File.read!(memory_path)
    input_leakage = Sugary.PublicBenchmarks.leakage_report(eval_run_dir, eval_cases)

    eval_source_ids =
      eval_cases
      |> Enum.map(fn bench_case ->
        metadata = bench_case.source_metadata || %{}
        field(metadata, :original_case_id)
      end)
      |> Enum.reject(&(&1 in [nil, ""]))

    memory_case_id_leaks =
      Enum.filter(eval_source_ids, &String.contains?(memory_text, &1))

    memory_oracle_markers =
      ["expectedClaims", "knownNonIssues", "\"oracle\"", "golden_comments"]
      |> Enum.filter(&String.contains?(memory_text, &1))

    %{
      fatal?: input_leakage.fatal? or memory_case_id_leaks != [] or memory_oracle_markers != [],
      reviewer_input_leakage: input_leakage,
      memory_case_id_leaks: memory_case_id_leaks,
      memory_oracle_markers: memory_oracle_markers,
      warnings: []
    }
  end

  defp write_artifacts!(gauntlet_dir, attrs) do
    Sugary.Json.write!(Path.join(gauntlet_dir, "train-manifest.json"), attrs.train_manifest)
    Sugary.Json.write!(Path.join(gauntlet_dir, "eval-manifest.json"), attrs.eval_manifest)
    Sugary.Json.write!(Path.join(gauntlet_dir, "scorecard.json"), attrs.scorecard)
    Sugary.Json.write!(Path.join(gauntlet_dir, "leakage-report.json"), attrs.leakage)
    Sugary.Json.write!(Path.join(gauntlet_dir, "agent-bus-summary.json"), attrs.bus_summary)

    Sugary.Json.write!(
      Path.join(gauntlet_dir, "scores.json"),
      Enum.map(
        attrs.train_reports ++ attrs.eval_reports ++ [attrs.memory_report, attrs.shuffled_report],
        fn
          report -> %{method_id: report.method.id, score: report.score}
        end
      )
    )

    File.write!(Path.join(gauntlet_dir, "report.md"), render_report(attrs.scorecard))
  end

  defp render_report(scorecard) do
    rows =
      scorecard.methods
      |> Enum.map(fn {method_id, score} ->
        "| #{method_id} | #{fmt(score.recall)} | #{fmt(score.usefulness)} | #{fmt(score.snr)} | #{fmt(score.f1)} | #{fmt(score.avg_comments_per_pr)} | #{score.published_claims} | #{score.noise} |"
      end)
      |> Enum.join("\n")

    comparison = scorecard.comparison

    """
    # h5i Persistent Memory Gauntlet: #{scorecard.id}

    This is a controlled local smoke run. It does not submit or claim official benchmark performance.

    ## Decision

    - Decision: `#{scorecard.decision}`
    - Claim level: #{scorecard.claim_level}
    - h5i enabled: #{scorecard.h5i_enabled}
    - Train offset/limit: #{scorecard.train_offset}/#{scorecard.train_limit}
    - Eval offset/limit: #{scorecard.eval_offset}/#{scorecard.eval_limit}

    ## Scorecard

    | Method | Recall | Usefulness | SNR | F1 | Avg Comments | Published | Noise |
    | --- | --- | --- | --- | --- | --- | --- | --- |
    #{rows}

    ## Memory Comparison

    - Memory vs stateless-normalized F1 delta: #{fmt(comparison.memory_vs_stateless_f1_delta)}
    - Memory vs stateless-normalized usefulness delta: #{fmt(comparison.memory_vs_stateless_usefulness_delta)}
    - Memory vs stateless-normalized SNR delta: #{fmt(comparison.memory_vs_stateless_snr_delta)}
    - Memory vs stateless-normalized avg comment delta: #{fmt(comparison.memory_vs_stateless_avg_comments_delta)}
    - Memory vs shuffled F1 delta: #{fmt(comparison.memory_vs_shuffled_f1_delta)}
    - Memory unique hits over stateless: #{comparison.memory_unique_hits_over_stateless}
    - Shuffled unique hits over stateless: #{comparison.shuffled_unique_hits_over_stateless}
    - Added noise over stateless: #{comparison.added_noise_over_stateless}

    ## Memory Summary

    - Positive lessons: #{scorecard.memory_summary.positive_lessons}
    - Negative lessons: #{scorecard.memory_summary.negative_lessons}
    - Categories: `#{inspect(scorecard.memory_summary.categories)}`

    ## Leakage

    - Fatal leakage: #{scorecard.leakage.fatal?}
    - Memory case-id leaks: #{length(scorecard.leakage.memory_case_id_leaks)}
    - Memory oracle markers: #{length(scorecard.leakage.memory_oracle_markers)}

    ## Interpretation

    The important comparison is `h5i-persistent-memory-team` vs both `stateless-normalized-team` and `shuffled-memory-control-team`. A win over the original team alone is not enough; the shuffled negative control must not reproduce the lift.
    """
  end

  defp find_report!(reports, method_id) do
    Enum.find(reports, &(&1.method.id == method_id)) ||
      raise ArgumentError, "method report #{inspect(method_id)} not found"
  end

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

  defp claim_text(claim) do
    [
      field(claim, :claim, ""),
      field(claim, :category, ""),
      field(claim, :failure_path, []) |> List.wrap() |> Enum.join(" "),
      claim
      |> field(:evidence, [])
      |> List.wrap()
      |> Enum.map(&field(&1, :summary, ""))
      |> Enum.join(" ")
    ]
    |> Enum.join(" ")
  end

  defp tokens(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, " ")
    |> String.split()
    |> Enum.flat_map(&String.split(&1, "_"))
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(String.length(&1) < 3))
    |> Enum.reject(&(&1 in ~w(the and with from this that into)))
    |> Enum.uniq()
    |> Enum.sort()
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

  defp put_string_or_atom(%{} = map, key, value) do
    cond do
      Map.has_key?(map, key) -> Map.put(map, key, value)
      Map.has_key?(map, to_string(key)) -> Map.put(map, to_string(key), value)
      true -> Map.put(map, key, value)
    end
  end

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(%_module{} = struct, key, default),
    do: struct |> Map.from_struct() |> field(key, default)

  defp field(%{} = map, key, default), do: map[key] || map[to_string(key)] || default
  defp field(_other, _key, default), do: default

  defp write_jsonl!(path, records) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Enum.map_join(records, "", &(Sugary.Json.encode!(&1) <> "\n")))
  end

  defp memory_id(entries) do
    entries
    |> Enum.map(& &1.id)
    |> Enum.sort()
    |> Enum.join(":")
    |> hash()
    |> String.slice(0, 12)
    |> then(&"h5i-memory-#{&1}")
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
  defp truncate(value, max), do: value |> to_string() |> String.slice(0, max)
  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den

  defp normalize_opts(opts) when is_list(opts),
    do: Map.new(opts, fn {k, v} -> {to_string(k), v} end)

  defp normalize_opts(opts) when is_map(opts),
    do: Map.new(opts, fn {k, v} -> {to_string(k), v} end)

  defp truthy?(value) when value in [false, "false", "0", 0, "no", "off"], do: false
  defp truthy?(_value), do: true

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value), do: value |> to_string() |> Integer.parse() |> elem(0)

  defp make_gauntlet_dir(id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(".sugary/research/persistent-memory-gauntlets", "#{timestamp}-#{id}")
  end

  defp fmt(nil), do: "n/a"
  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)
end

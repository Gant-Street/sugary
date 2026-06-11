defmodule Sugary.StagedPublisherReplay do
  @attention_cost -0.1
  @version "staged-publisher-replay-v0"

  def run!(opts) do
    opts = normalize_opts(opts)
    source_run = fetch!(opts, "source-run")
    method_id = fetch!(opts, "method")
    baseline_id = Map.get(opts, "baseline")
    suite = Map.get(opts, "suite", "martian-offline")
    split = Map.get(opts, "split")
    limit = int_opt(opts, "limit", 25)
    offset = int_opt(opts, "offset", 0)
    id = Map.get(opts, "id", "staged-publisher-replay-v0")

    cases = Sugary.PublicBenchmarks.load_cases!(suite, split: split, limit: limit, offset: offset)
    out_dir = make_run_dir(id)
    File.mkdir_p!(out_dir)

    policy_reports =
      default_policies()
      |> Enum.map(&score_policy(&1, source_run, method_id, cases))

    baseline_report =
      if baseline_id do
        score_baseline(baseline_id, source_run, cases)
      end

    policy_reports =
      Enum.map(policy_reports, fn report ->
        report
        |> Map.put(:paired_vs_baseline, paired_comparison(report, baseline_report))
        |> Map.put(:guardrails, guardrails(report, baseline_report))
      end)

    winner = choose_winner(policy_reports)

    write_artifacts!(
      out_dir,
      source_run,
      method_id,
      baseline_id,
      suite,
      split,
      limit,
      offset,
      policy_reports,
      baseline_report,
      winner
    )

    out_dir
  end

  def default_policies do
    [
      %{
        id: "source-proof-max-1",
        max_published: 1,
        min_score: 0.0,
        require_source_publish: true,
        require_typed: false,
        require_repo_evidence: false,
        require_no_suppressing_invariant: false,
        require_expected_failure: false
      },
      %{
        id: "source-proof-max-2",
        max_published: 2,
        min_score: 0.0,
        require_source_publish: true,
        require_typed: false,
        require_repo_evidence: false,
        require_no_suppressing_invariant: false,
        require_expected_failure: false
      },
      %{
        id: "source-proof-max-3",
        max_published: 3,
        min_score: 0.0,
        require_source_publish: true,
        require_typed: false,
        require_repo_evidence: false,
        require_no_suppressing_invariant: false,
        require_expected_failure: false
      },
      %{
        id: "typed-repo-proof-max-2",
        max_published: 2,
        min_score: 5.4,
        require_source_publish: false,
        require_typed: true,
        require_repo_evidence: true,
        require_no_suppressing_invariant: true,
        require_expected_failure: true
      },
      %{
        id: "typed-repo-proof-max-3",
        max_published: 3,
        min_score: 5.4,
        require_source_publish: false,
        require_typed: true,
        require_repo_evidence: true,
        require_no_suppressing_invariant: true,
        require_expected_failure: true
      },
      %{
        id: "repo-proof-score-max-2",
        max_published: 2,
        min_score: 4.8,
        require_source_publish: false,
        require_typed: false,
        require_repo_evidence: true,
        require_no_suppressing_invariant: true,
        require_expected_failure: true
      },
      %{
        id: "repo-proof-score-max-3",
        max_published: 3,
        min_score: 4.8,
        require_source_publish: false,
        require_typed: false,
        require_repo_evidence: true,
        require_no_suppressing_invariant: true,
        require_expected_failure: true
      }
    ]
  end

  defp score_policy(policy, source_run, method_id, cases) do
    results =
      Enum.map(cases, fn bench_case ->
        candidates =
          source_run
          |> validation_stage_claims(method_id, bench_case)
          |> Enum.map(&Map.put(&1, :publish_decision, "candidate"))

        final_claims = publish(candidates, policy)

        %{
          case: bench_case,
          reviewer_result: %{cost: 0.0, latency_ms: 0},
          candidate_claims: candidates,
          final_claims: final_claims
        }
      end)

    score = Sugary.Scorer.score(policy.id, results)
    per_case = Enum.map(results, &case_stats/1)

    %{
      policy_id: policy.id,
      type: "staged_policy",
      version: @version,
      policy: policy,
      score: score,
      per_case: per_case,
      research_utility: research_utility(per_case),
      candidate_diagnostics: candidate_diagnostics(results)
    }
  end

  defp score_baseline(method_id, source_run, cases) do
    results =
      Enum.map(cases, fn bench_case ->
        final_claims =
          source_run
          |> claims_path(method_id, bench_case.id)
          |> Sugary.Json.read!()
          |> atomize()
          |> Enum.map(fn claim ->
            Map.put(claim, :publish_decision, Map.get(claim, :publish_decision) || "publish")
          end)

        %{
          case: bench_case,
          reviewer_result: %{cost: 0.0, latency_ms: 0},
          candidate_claims: final_claims,
          final_claims: final_claims
        }
      end)

    score = Sugary.Scorer.score(method_id, results)
    per_case = Enum.map(results, &case_stats/1)

    %{
      policy_id: method_id,
      type: "baseline",
      score: score,
      per_case: per_case,
      research_utility: research_utility(per_case)
    }
  end

  defp validation_stage_claims(source_run, method_id, bench_case) do
    source_run
    |> artifact_path(method_id, bench_case.id)
    |> Sugary.Json.read!()
    |> atomize()
    |> extract_validation_stage()
    |> Enum.with_index(1)
    |> Enum.map(fn {row, index} ->
      claim_from_validation_row(row, index, method_id, bench_case.id)
    end)
  rescue
    _error -> []
  end

  defp artifact_path(source_run, method_id, case_id) do
    method_path = Path.join([source_run, method_id, "adapter-artifacts", "#{case_id}.json"])

    if File.exists?(method_path) do
      method_path
    else
      Path.join([source_run, "adapter-artifacts", "#{method_id}--#{case_id}.json"])
    end
  end

  defp extract_validation_stage(artifacts) do
    artifacts
    |> List.wrap()
    |> Enum.flat_map(&(Map.get(&1, :reviewer_artifacts) || []))
    |> Enum.find_value([], fn artifact ->
      stage = Map.get(artifact, :validation_stage) || []
      if stage == [], do: nil, else: stage
    end)
  end

  defp claim_from_validation_row(row, index, method_id, case_id) do
    features = Map.get(row, :proof_features) || %{}
    proof_type = field(features, :proof_type, "general_review")
    path = field(row, :path, "unknown")
    root_cause_key = field(features, :root_cause_key)

    %{
      id: "#{method_id}-#{case_id}-validation-#{index}",
      claim: field(row, :claim, "Validated staged review claim."),
      category: category_from_proof_type(proof_type),
      severity: severity_from_proof_type(proof_type),
      confidence: float_value(field(row, :confidence, 0.0)),
      path: path || "unknown",
      start_line: field(row, :start_line),
      end_line: field(row, :end_line),
      introduced_by_pr: truthy?(field(features, :introduced_by_pr, true)),
      failure_path: failure_path_from_row(row),
      evidence: [
        %{
          type: "staged_validation",
          tier: evidence_tier(field(row, :proof_score, 0.0)),
          strength: evidence_strength(field(row, :proof_score, 0.0)),
          summary: field(row, :evidence_summary, "")
        }
      ],
      suggested_fix: field(row, :suggested_fix),
      suggested_test: field(row, :suggested_test),
      counterarguments: [field(row, :counterargument, "")] |> Enum.reject(&(&1 in [nil, ""])),
      dedupe_key: root_cause_key || "#{proof_type}:#{path}:#{canonical(field(row, :claim, ""))}",
      source: %{
        method: method_id,
        source_role: field(row, :source_role),
        proof_type: proof_type,
        proof_score: float_value(field(row, :proof_score, 0.0)),
        proof_decision: field(row, :proof_decision),
        proof_reasons: field(row, :proof_reasons, []),
        proof_features: features,
        validation_verdict: field(row, :verdict),
        validation_status: field(row, :status)
      },
      publish_decision: "candidate"
    }
  end

  defp publish(candidates, policy) do
    ranked =
      candidates
      |> Enum.map(&score_candidate(&1, policy))
      |> Enum.sort_by(&{Map.get(&1, :publisher_score, 0.0), Map.get(&1, :confidence, 0.0)}, :desc)

    {claims, _seen, _published} =
      Enum.reduce(ranked, {[], MapSet.new(), 0}, fn claim, {acc, seen, published} ->
        duplicate? = MapSet.member?(seen, claim.dedupe_key)
        eligible? = eligible?(claim, policy)

        cond do
          duplicate? ->
            {[
               claim
               |> Map.put(:publish_decision, "suppress")
               |> Map.put(:suppressed_reason, "duplicate_root_cause")
               | acc
             ], seen, published}

          not eligible? ->
            {[
               claim
               |> Map.put(:publish_decision, "suppress")
               |> Map.put(:suppressed_reason, suppression_reason(claim, policy))
               | acc
             ], MapSet.put(seen, claim.dedupe_key), published}

          published < policy.max_published ->
            {[
               claim
               |> Map.put(:publish_decision, "publish")
               |> Map.delete(:suppressed_reason)
               | acc
             ], MapSet.put(seen, claim.dedupe_key), published + 1}

          true ->
            {[
               claim
               |> Map.put(:publish_decision, "suppress")
               |> Map.put(:suppressed_reason, "comment_budget")
               | acc
             ], MapSet.put(seen, claim.dedupe_key), published}
        end
      end)

    Enum.reverse(claims)
  end

  defp score_candidate(claim, _policy) do
    features = proof_features(claim)
    proof_score = proof_score(claim)

    score =
      proof_score * 3.0 +
        float_value(Map.get(claim, :confidence)) * 1.2 +
        severity_score(Map.get(claim, :severity)) +
        bool_score(field(features, :has_repo_evidence)) * 0.65 +
        bool_score(field(features, :has_read_file)) * 0.4 +
        bool_score(field(features, :has_repo_grep)) * 0.45 +
        bool_score(field(features, :expected_failure_language)) * 0.45 +
        bool_score(field(features, :has_failure_path)) * 0.35 +
        bool_score(field(features, :typed_requirements_met)) * 0.45 -
        bool_score(field(features, :speculative_language)) * 0.8 -
        suppressing_invariant_penalty(features) -
        proof_reason_penalty(claim)

    claim
    |> Map.put(:publisher_score, Float.round(score, 4))
    |> Map.put(:publisher_features, %{
      proof_score: proof_score,
      has_repo_evidence: truthy?(field(features, :has_repo_evidence)),
      has_read_file: truthy?(field(features, :has_read_file)),
      has_repo_grep: truthy?(field(features, :has_repo_grep)),
      expected_failure_language: truthy?(field(features, :expected_failure_language)),
      typed_requirements_met: truthy?(field(features, :typed_requirements_met)),
      suppressing_invariants: List.wrap(field(features, :suppressing_invariants, [])),
      proof_reasons: proof_reasons(claim)
    })
  end

  defp eligible?(claim, policy) do
    features = proof_features(claim)

    checks = [
      Map.get(claim, :publisher_score, 0.0) >= policy.min_score,
      not policy.require_source_publish or field(claim.source, :proof_decision) == "publish",
      not policy.require_typed or truthy?(field(features, :typed_requirements_met)),
      not policy.require_repo_evidence or truthy?(field(features, :has_repo_evidence)),
      not policy.require_expected_failure or truthy?(field(features, :expected_failure_language)),
      not policy.require_no_suppressing_invariant or
        List.wrap(field(features, :suppressing_invariants, [])) == [],
      not truthy?(field(features, :speculative_language)),
      Map.get(claim, :introduced_by_pr) != false
    ]

    Enum.all?(checks)
  end

  defp suppression_reason(claim, policy) do
    features = proof_features(claim)

    cond do
      Map.get(claim, :publisher_score, 0.0) < policy.min_score ->
        "low_publisher_score"

      policy.require_source_publish and field(claim.source, :proof_decision) != "publish" ->
        "source_proof_decision"

      policy.require_typed and not truthy?(field(features, :typed_requirements_met)) ->
        "typed_requirements_not_met"

      policy.require_repo_evidence and not truthy?(field(features, :has_repo_evidence)) ->
        "missing_repo_evidence"

      policy.require_expected_failure and not truthy?(field(features, :expected_failure_language)) ->
        "missing_expected_failure"

      policy.require_no_suppressing_invariant and
          List.wrap(field(features, :suppressing_invariants, [])) != [] ->
        "suppressing_invariant"

      truthy?(field(features, :speculative_language)) ->
        "speculative_language"

      Map.get(claim, :introduced_by_pr) == false ->
        "not_introduced_by_pr"

      true ->
        "policy_rejected"
    end
  end

  defp case_stats(result) do
    published = Enum.filter(result.final_claims, &(&1.publish_decision == "publish"))
    accounting = Sugary.ScoreAccounting.claim_accounting(result.case, published)

    candidate_accounting =
      Sugary.ScoreAccounting.claim_accounting(result.case, result.candidate_claims)

    %{
      case_id: result.case.id,
      expected: Sugary.ClaimMatcher.expected_ids(result.case) |> MapSet.size(),
      comments: length(published),
      hits: accounting.unique_hits,
      hit_ids: accounting.hit_ids,
      noise: accounting.noise_events,
      candidate_hits: candidate_accounting.unique_hits,
      candidate_noise: candidate_accounting.noise_events,
      suppressed_true:
        MapSet.difference(
          MapSet.new(candidate_accounting.hit_ids),
          MapSet.new(accounting.hit_ids)
        )
        |> MapSet.size()
    }
  end

  defp research_utility(per_case) do
    Enum.reduce(per_case, 0.0, fn row, total ->
      total + row.hits - row.noise + row.comments * @attention_cost
    end)
  end

  defp candidate_diagnostics(results) do
    rows = Enum.map(results, &case_stats/1)

    %{
      candidates: Enum.reduce(results, 0, &(length(&1.candidate_claims) + &2)),
      candidate_hits: Enum.reduce(rows, 0, &(&1.candidate_hits + &2)),
      candidate_noise: Enum.reduce(rows, 0, &(&1.candidate_noise + &2)),
      candidate_headroom:
        Enum.reduce(rows, 0, fn row, total -> total + max(row.candidate_hits - row.hits, 0) end)
    }
  end

  defp guardrails(_report, nil), do: %{passes: false, reason: "missing_baseline", checks: %{}}

  defp guardrails(report, baseline) do
    score = report.score
    baseline_score = baseline.score

    checks = %{
      beats_f1: score.f1 > baseline_score.f1,
      usefulness: score.usefulness >= baseline_score.usefulness,
      snr: score.snr >= baseline_score.snr,
      noise: score.noise <= baseline_score.noise,
      comments: score.avg_comments_per_pr <= baseline_score.avg_comments_per_pr,
      unique_true_positive: unique_hits(report, baseline) >= 1
    }

    %{passes: Enum.all?(Map.values(checks)), checks: checks}
  end

  defp choose_winner(policy_reports) do
    promotable = Enum.filter(policy_reports, &(&1.guardrails.passes == true))
    pool = if promotable == [], do: policy_reports, else: promotable

    Enum.max_by(pool, fn report ->
      {
        report.guardrails.passes,
        report.score.f1,
        report.score.usefulness,
        report.score.snr,
        report.research_utility
      }
    end)
  end

  defp paired_comparison(_left, nil), do: nil

  defp paired_comparison(left, right) do
    right_by_case = Map.new(right.per_case, &{&1.case_id, &1})

    rows =
      Enum.map(left.per_case, fn left_case ->
        right_case = Map.fetch!(right_by_case, left_case.case_id)
        paired_outcome(left_case, right_case)
      end)

    total = max(length(rows), 1)

    %{
      baseline: right.policy_id,
      wins: Enum.count(rows, &(&1 == :win)),
      losses: Enum.count(rows, &(&1 == :loss)),
      ties: Enum.count(rows, &(&1 == :tie)),
      win_rate: Enum.count(rows, &(&1 == :win)) / total
    }
  end

  defp paired_outcome(left, right) do
    cond do
      left.hits > right.hits and left.noise <= right.noise ->
        :win

      left.hits == right.hits and left.noise < right.noise ->
        :win

      left.hits == right.hits and left.noise == right.noise and left.comments < right.comments ->
        :win

      right.hits > left.hits and right.noise <= left.noise ->
        :loss

      right.hits == left.hits and right.noise < left.noise ->
        :loss

      right.hits == left.hits and right.noise == left.noise and right.comments < left.comments ->
        :loss

      true ->
        :tie
    end
  end

  defp unique_hits(report, baseline) do
    baseline_by_case = Map.new(baseline.per_case, &{&1.case_id, MapSet.new(&1.hit_ids)})

    report.per_case
    |> Enum.reduce(MapSet.new(), fn row, acc ->
      baseline_hits = Map.get(baseline_by_case, row.case_id, MapSet.new())

      row.hit_ids
      |> MapSet.new()
      |> MapSet.difference(baseline_hits)
      |> Enum.reduce(acc, &MapSet.put(&2, "#{row.case_id}:#{&1}"))
    end)
    |> MapSet.size()
  end

  defp write_artifacts!(
         out_dir,
         source_run,
         method_id,
         baseline_id,
         suite,
         split,
         limit,
         offset,
         policy_reports,
         baseline_report,
         winner
       ) do
    Sugary.Json.write!(Path.join(out_dir, "replay-config.json"), %{
      version: @version,
      source_run: source_run,
      method_id: method_id,
      baseline_id: baseline_id,
      suite: suite,
      split: split,
      limit: limit,
      offset: offset,
      methodology: "fixed validation_stage candidate pool; no live model calls"
    })

    Sugary.Json.write!(
      Path.join(out_dir, "policy-scorecards.json"),
      Enum.map(policy_reports, &json_report/1)
    )

    if baseline_report do
      Sugary.Json.write!(
        Path.join(out_dir, "baseline-scorecard.json"),
        json_report(baseline_report)
      )
    end

    Sugary.Json.write!(Path.join(out_dir, "decision.json"), decision(winner))

    File.write!(
      Path.join(out_dir, "report.md"),
      render_report(policy_reports, baseline_report, winner)
    )
  end

  defp json_report(report) do
    report
    |> Map.put(:score, Map.from_struct(report.score))
  end

  defp decision(nil), do: %{decision: "no_policy_available"}

  defp decision(winner) do
    %{
      decision:
        if(winner.guardrails.passes, do: "promote_for_live_check", else: "no_policy_promoted"),
      policy_id: winner.policy_id,
      f1: winner.score.f1,
      usefulness: winner.score.usefulness,
      snr: winner.score.snr,
      noise: winner.score.noise,
      published_claims: winner.score.published_claims,
      guardrails: winner.guardrails
    }
  end

  defp render_report(policy_reports, baseline_report, winner) do
    baseline_section =
      if baseline_report do
        """
        ## Baseline

        | Method | F1 | Recall | Usefulness | SNR | Hits | Noise | Comments | Avg Comments/PR |
        | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
        #{score_row(baseline_report)}
        """
      else
        "## Baseline\n\nNo baseline configured.\n"
      end

    rows = policy_reports |> Enum.map(&policy_row/1) |> Enum.join("\n")

    """
    # Staged Publisher Replay v0

    Unofficial local smoke run. Not an official benchmark score.

    This ablation replays publisher policies over fixed staged `validation_stage`
    artifacts. It makes no live model calls, so candidate-generation variance cannot
    explain policy differences.

    #{baseline_section}

    ## Policies

    | Policy | F1 | Recall | Usefulness | SNR | Hits | Noise | Comments | Avg Comments/PR | Candidate Hits | Candidate Noise | Guardrails |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
    #{rows}

    ## Decision

    #{decision_text(winner)}
    """
  end

  defp score_row(report) do
    score = report.score

    "| #{report.policy_id} | #{fmt(score.f1)} | #{fmt(score.recall)} | #{fmt(score.usefulness)} | #{fmt(score.snr)} | #{score.hits} | #{score.noise} | #{score.published_claims} | #{fmt(score.avg_comments_per_pr)} |"
  end

  defp policy_row(report) do
    score = report.score
    diag = report.candidate_diagnostics
    guardrails = if report.guardrails.passes, do: "pass", else: "fail"

    "| #{report.policy_id} | #{fmt(score.f1)} | #{fmt(score.recall)} | #{fmt(score.usefulness)} | #{fmt(score.snr)} | #{score.hits} | #{score.noise} | #{score.published_claims} | #{fmt(score.avg_comments_per_pr)} | #{diag.candidate_hits} | #{diag.candidate_noise} | #{guardrails} |"
  end

  defp decision_text(nil), do: "No policy available."

  defp decision_text(winner) do
    if winner.guardrails.passes do
      "Promote `#{winner.policy_id}` for a locked live check. It cleared the configured raw-baseline guardrails on fixed staged artifacts."
    else
      "No policy promoted. Best replay policy was `#{winner.policy_id}`, but it did not clear baseline guardrails."
    end
  end

  defp claims_path(source_run, method_id, case_id),
    do: Path.join([source_run, method_id, "claims", "#{case_id}.json"])

  defp proof_features(claim), do: field(claim.source, :proof_features, %{})
  defp proof_score(claim), do: field(claim.source, :proof_score, 0.0) |> float_value()
  defp proof_reasons(claim), do: field(claim.source, :proof_reasons, []) |> List.wrap()

  defp failure_path_from_row(row) do
    [
      field(row, :claim),
      field(row, :evidence_summary),
      field(row, :counterargument)
    ]
    |> Enum.reject(&(&1 in [nil, ""]))
  end

  defp category_from_proof_type(proof_type) do
    proof_type = to_string(proof_type)

    cond do
      String.contains?(proof_type, ["auth", "permission", "tenant", "security"]) -> "security"
      String.contains?(proof_type, ["contract", "schema", "api"]) -> "contract"
      String.contains?(proof_type, ["resource", "performance"]) -> "performance"
      String.contains?(proof_type, ["test"]) -> "test_gap"
      true -> "bug"
    end
  end

  defp severity_from_proof_type(proof_type) do
    proof_type = to_string(proof_type)

    cond do
      String.contains?(proof_type, ["auth", "permission", "tenant", "security"]) -> "high"
      String.contains?(proof_type, ["api_contract", "schema", "resource"]) -> "high"
      true -> "medium"
    end
  end

  defp evidence_tier(score) do
    score = float_value(score)

    cond do
      score >= 0.9 -> 2
      score >= 0.7 -> 3
      score >= 0.5 -> 4
      true -> 5
    end
  end

  defp evidence_strength(score) do
    score = float_value(score)

    cond do
      score >= 0.9 -> "strong"
      score >= 0.7 -> "medium"
      true -> "weak"
    end
  end

  defp severity_score(severity) do
    %{"critical" => 1.2, "high" => 1.0, "medium" => 0.65, "low" => 0.2}
    |> Map.get(severity |> to_string() |> String.downcase(), 0.45)
  end

  defp bool_score(value), do: if(truthy?(value), do: 1.0, else: 0.0)

  defp suppressing_invariant_penalty(features) do
    features
    |> field(:suppressing_invariants, [])
    |> List.wrap()
    |> length()
    |> Kernel.*(1.2)
  end

  defp proof_reason_penalty(claim) do
    claim
    |> proof_reasons()
    |> Enum.count(&String.contains?(to_string(&1), ["low", "missing", "suppress"]))
    |> Kernel.*(0.45)
  end

  defp truthy?(value) when value in [true, "true", "TRUE", "yes", "1", 1], do: true
  defp truthy?(_value), do: false

  defp canonical(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, " ")
    |> String.trim()
    |> String.slice(0, 80)
  end

  defp normalize_opts(opts) when is_list(opts),
    do: Map.new(opts, fn {key, value} -> {to_string(key), value} end)

  defp normalize_opts(%{} = opts),
    do: Map.new(opts, fn {key, value} -> {to_string(key), value} end)

  defp fetch!(opts, key) do
    Map.fetch!(opts, key)
  rescue
    KeyError -> raise ArgumentError, "missing required --#{key}"
  end

  defp int_opt(opts, key, default), do: Map.get(opts, key, default) |> int_value(default)

  defp int_value(value, _default) when is_integer(value), do: value

  defp int_value(value, default) do
    case Integer.parse(to_string(value)) do
      {number, ""} -> number
      _ -> default
    end
  end

  defp float_value(value) when is_float(value), do: value
  defp float_value(value) when is_integer(value), do: value * 1.0

  defp float_value(value) do
    case Float.parse(to_string(value)) do
      {number, _rest} -> number
      _ -> 0.0
    end
  end

  defp make_run_dir(id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(".sugary/research/runs", "#{timestamp}-#{id}")
  end

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)

  defp atomize(%{} = map),
    do: Map.new(map, fn {key, value} -> {atom_key(key), atomize(value)} end)

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value
  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default
  defp field(%{} = map, key, default), do: map[key] || map[to_string(key)] || default
  defp field(_other, _key, default), do: default
end

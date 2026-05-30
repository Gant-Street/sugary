defmodule Sugary.PCRSEnsemblePublisher do
  @moduledoc false

  @root ".sugary/research/pcrs-ensemble-publisher"
  @method_id "pcrs-ensemble-publisher-v2"
  @baseline_policy %{id: "team-ev-max-2", max_published: 2, min_score: 1.4}
  @total_budget 52
  @expected_claims 137
  @v0_policy_id "posterior-max1-plus-source5-qualified-triad-budget52"
  @bootstrap_samples 1_000

  @default_baseline_run ".sugary/research/runs/20260530T072359Z-martian-autoresearch-v0"
  @default_candidate_run ".sugary/research/runs/20260530T032918Z-martian-autoresearch-50-v0-experiment"

  @core_sources [
    %{
      run: @default_baseline_run,
      method: "pcrs-codex-repo-low-strict",
      source: "strict-repeat",
      pool: :core,
      family: "pcrs_repo_strict",
      source_prior: 0.66
    },
    %{
      run: @default_candidate_run,
      method: "pcrs-codex-repo-low-strict",
      source: "strict-gauntlet",
      pool: :core,
      family: "pcrs_repo_strict",
      source_prior: 0.66
    },
    %{
      run: @default_candidate_run,
      method: "pcrs-codex-repo-low",
      source: "broad-repo",
      pool: :core,
      family: "pcrs_repo_broad",
      source_prior: 0.56
    },
    %{
      run: @default_candidate_run,
      method: "pcrs-codex-proof-low",
      source: "proof-diff",
      pool: :core,
      family: "pcrs_diff_proof",
      source_prior: 0.56
    },
    %{
      run: @default_candidate_run,
      method: "codex-gpt-5.5-repo-low",
      source: "repo-raw",
      pool: :core,
      family: "codex_repo_raw",
      source_prior: 0.52
    },
    %{
      run: @default_candidate_run,
      method: "martian-pcrs-repo-plus-codex-low",
      source: "prior-team",
      pool: :core,
      family: "pcrs_team",
      source_prior: 0.54
    }
  ]

  @tail_sources [
    %{
      run: ".sugary/research/runs/20260525T183827Z-public-martian-pcrs-transfer-v1",
      method: "public-pcrs-static-codex-low-team",
      source: "tail-transfer-team-a",
      pool: :tail,
      family: "static_codex_team",
      source_prior: 0.56
    },
    %{
      run: ".sugary/research/runs/20260526T013237Z-martian-materialized-dev18-pcrs-v1-experiment",
      method: "pcrs-codex-repo-low",
      source: "tail-materialized-pcrs-repo",
      pool: :tail,
      family: "materialized_pcrs_repo",
      source_prior: 0.52
    },
    %{
      run: ".sugary/research/runs/20260526T013237Z-martian-materialized-dev18-pcrs-v1-experiment",
      method: "native-codex-repo-low",
      source: "tail-materialized-native-repo",
      pool: :tail,
      family: "materialized_codex_repo",
      source_prior: 0.46
    },
    %{
      run:
        ".sugary/research/runs/20260526T000628Z-martian-materialized-architecture-v1-experiment",
      method: "pcrs-codex-proof-low",
      source: "tail-architecture-proof",
      pool: :tail,
      family: "architecture_pcrs_proof",
      source_prior: 0.52
    },
    %{
      run: ".sugary/research/runs/20260525T215029Z-public-martian-ranking-fresh-v1",
      method: "codex-gpt-5.5-xhigh",
      source: "tail-xhigh-fresh",
      pool: :tail,
      family: "codex_xhigh",
      source_prior: 0.55
    },
    %{
      run:
        ".sugary/research/runs/20260526T000628Z-martian-materialized-architecture-v1-experiment",
      method: "native-codex-repo-low",
      source: "tail-architecture-native-repo",
      pool: :tail,
      family: "architecture_codex_repo",
      source_prior: 0.46
    },
    %{
      run: ".sugary/research/runs/20260525T215029Z-public-martian-ranking-fresh-v1",
      method: "public-pcrs-static-codex-low-team",
      source: "tail-fresh-team",
      pool: :tail,
      family: "static_codex_team",
      source_prior: 0.56
    },
    %{
      run: ".sugary/research/runs/20260525T183827Z-public-martian-pcrs-transfer-v1",
      method: "codex-gpt-5.5-xhigh",
      source: "tail-xhigh-transfer-a",
      pool: :tail,
      family: "codex_xhigh",
      source_prior: 0.55
    },
    %{
      run: ".sugary/research/runs/20260529T045745Z-public-martian-pcrs-transfer-v1",
      method: "codex-gpt-5.5-xhigh",
      source: "tail-xhigh-transfer-b",
      pool: :tail,
      family: "codex_xhigh",
      source_prior: 0.55
    },
    %{
      run: ".sugary/research/runs/20260526T013237Z-martian-materialized-dev18-pcrs-v1-experiment",
      method: "native-codex-diff-low",
      source: "tail-materialized-native-diff",
      pool: :tail,
      family: "materialized_codex_diff",
      source_prior: 0.46
    },
    %{
      run: ".sugary/research/runs/20260526T013237Z-martian-materialized-dev18-pcrs-v1-experiment",
      method: "pcrs-codex-proof-low",
      source: "tail-materialized-proof",
      pool: :tail,
      family: "materialized_pcrs_proof",
      source_prior: 0.52
    },
    %{
      run: ".sugary/research/runs/20260529T045745Z-public-martian-pcrs-transfer-v1",
      method: "codex-gpt-5.5-low",
      source: "tail-transfer-diff-low-b",
      pool: :tail,
      family: "codex_diff_low",
      source_prior: 0.48
    },
    %{
      run: ".sugary/research/runs/20260529T044430Z-public-martian-pcrs-transfer-v1",
      method: "public-pcrs-static-codex-low-team",
      source: "tail-transfer-team-b",
      pool: :tail,
      family: "static_codex_team",
      source_prior: 0.56
    },
    %{
      run: ".sugary/research/runs/20260529T045745Z-public-martian-pcrs-transfer-v1",
      method: "public-pcrs-static-codex-low-team",
      source: "tail-transfer-team-c",
      pool: :tail,
      family: "static_codex_team",
      source_prior: 0.56
    },
    %{
      run: ".sugary/research/runs/20260525T183827Z-public-martian-pcrs-transfer-v1",
      method: "pcrs-codex-proof-low",
      source: "tail-transfer-proof-a",
      pool: :tail,
      family: "pcrs_diff_proof",
      source_prior: 0.52
    }
  ]

  @default_sources @core_sources ++ @tail_sources

  @policies [
    %{id: "posterior-budget-52-t55", threshold: 0.55, max_per_pr: 2, total_budget: @total_budget},
    %{id: "posterior-budget-52-t60", threshold: 0.60, max_per_pr: 2, total_budget: @total_budget},
    %{id: "posterior-budget-52-t65", threshold: 0.65, max_per_pr: 2, total_budget: @total_budget},
    %{id: "posterior-budget-52-t70", threshold: 0.70, max_per_pr: 2, total_budget: @total_budget},
    %{id: "posterior-max1-t55", threshold: 0.55, max_per_pr: 1, total_budget: 50},
    %{id: "posterior-max1-t60", threshold: 0.60, max_per_pr: 1, total_budget: 50},
    %{
      id: "posterior-max1-plus-source5-budget52",
      strategy: "max1_plus_second",
      threshold: 0.55,
      max_per_pr: 2,
      total_budget: 52,
      second_min_source_count: 5,
      second_min_posterior: 0.0
    },
    %{
      id: "posterior-max1-plus-source6-budget50",
      strategy: "max1_plus_second",
      threshold: 0.55,
      max_per_pr: 2,
      total_budget: 50,
      second_min_source_count: 6,
      second_min_posterior: 0.0
    },
    %{
      id: "posterior-max1-plus-source5-no-triad-budget52",
      strategy: "max1_plus_second",
      threshold: 0.55,
      max_per_pr: 2,
      total_budget: 52,
      second_min_source_count: 5,
      second_min_posterior: 0.0,
      exclude_source_counts: [3],
      hypothesis:
        "Avoid partial-consensus triads unless later evidence shows they generalize; in this local proxy they are a high-noise boundary band."
    },
    %{
      id: "posterior-max1-plus-source5-qualified-triad-budget52",
      mode: "trust",
      budget_tier: 52,
      pool_scope: :core,
      strategy: "max1_plus_second",
      threshold: 0.55,
      max_per_pr: 2,
      total_budget: 52,
      second_min_source_count: 5,
      second_min_posterior: 0.0,
      require_qualified_triad: true,
      hypothesis:
        "Admit three-source consensus only when it combines raw repo context, prior-team agreement, and a strict reviewer."
    },
    %{
      id: "qualified-f1-tail-verification-budget80",
      mode: "qualified_f1",
      budget_tier: 80,
      strategy: "max1_plus_second",
      threshold: 0.58,
      max_per_pr: 3,
      total_budget: 80,
      second_min_source_count: 1,
      second_min_posterior: 0.58,
      require_tail_verification: true,
      hypothesis:
        "Use historical tail candidate sources only when a claim has strong proof-shape features or independent source support."
    },
    %{
      id: "qualified-f1-trust-plus-tail-team-xhigh-budget78",
      mode: "qualified_f1",
      budget_tier: 78,
      strategy: "trust_plus_tail",
      base_policy_id: @v0_policy_id,
      threshold: 0.55,
      max_per_pr: 3,
      total_budget: 78,
      supplemental_budget: 26,
      max_supplemental_per_pr: 1,
      supplemental_filter: "tail_team_or_xhigh",
      near_duplicate_jaccard: 0.18,
      require_tail_verification: true,
      hypothesis:
        "Preserve the trust/default set, then add at most one team-backed or xhigh tail claim per PR after near-duplicate suppression."
    },
    %{
      id: "qualified-f1-trust-plus-tail-diverse-budget80",
      mode: "qualified_f1",
      budget_tier: 80,
      strategy: "trust_plus_tail",
      base_policy_id: @v0_policy_id,
      threshold: 0.55,
      max_per_pr: 3,
      total_budget: 80,
      supplemental_budget: 28,
      max_supplemental_per_pr: 1,
      supplemental_filter: "materialized_xhigh_team_source2",
      near_duplicate_jaccard: 0.18,
      require_tail_verification: true,
      hypothesis:
        "Wider qualified-F1 supplement using materialized, xhigh, or team-backed tail claims with source-count support."
    },
    %{
      id: "qualified-f1-tail-verification-budget88",
      mode: "qualified_f1",
      budget_tier: 88,
      strategy: "max1_plus_second",
      threshold: 0.56,
      max_per_pr: 3,
      total_budget: 88,
      second_min_source_count: 1,
      second_min_posterior: 0.56,
      require_tail_verification: true,
      hypothesis:
        "Slightly wider qualified-F1 frontier for testing whether tail verification can buy recall without crossing the 0.70 precision floor."
    },
    %{
      id: "raw-f1-tail-diagnostic-budget110",
      mode: "raw_f1_diagnostic",
      budget_tier: 110,
      strategy: "max1_plus_second",
      threshold: 0.48,
      max_per_pr: 4,
      total_budget: 110,
      second_min_source_count: 1,
      second_min_posterior: 0.48,
      eligible_for_promotion: false,
      diagnostic: true,
      hypothesis:
        "Raw recall diagnostic. This can expose publisher ceiling but is not eligible for promotion or product default."
    },
    %{
      id: "frontier-balanced-budget62-source2-qualified-triad",
      mode: "balanced",
      budget_tier: 62,
      strategy: "max1_plus_second",
      threshold: 0.55,
      max_per_pr: 2,
      total_budget: 62,
      second_min_source_count: 2,
      second_min_posterior: 0.75,
      require_qualified_triad: true,
      hypothesis:
        "Buy additional recall at a precision floor suitable for a balanced review mode."
    },
    %{
      id: "frontier-aggressive-budget72-source1-qualified-triad",
      mode: "aggressive",
      budget_tier: 72,
      strategy: "max1_plus_second",
      threshold: 0.55,
      max_per_pr: 2,
      total_budget: 72,
      second_min_source_count: 1,
      second_min_posterior: 0.75,
      require_qualified_triad: true,
      hypothesis:
        "Spend more comments only on high-posterior candidates that pass source-shape gating."
    },
    %{
      id: "frontier-leaderboard-budget85-source1-qualified-triad",
      mode: "leaderboard",
      budget_tier: 85,
      strategy: "max1_plus_second",
      threshold: 0.55,
      max_per_pr: 2,
      total_budget: 85,
      second_min_source_count: 1,
      second_min_posterior: 0.75,
      require_qualified_triad: true,
      hypothesis:
        "Leaderboard-mode candidate with a precision floor; may not use the full budget."
    },
    %{
      id: "frontier-leaderboard-budget85-max-f1-diagnostic",
      mode: "leaderboard_diagnostic",
      budget_tier: 85,
      strategy: "max1_plus_second",
      threshold: 0.55,
      max_per_pr: 2,
      total_budget: 85,
      second_min_source_count: 2,
      second_min_posterior: 0.0,
      require_qualified_triad: true,
      eligible_for_promotion: false,
      diagnostic: true,
      hypothesis:
        "Diagnostic upper-recall policy; reject if precision falls below the leaderboard floor."
    },
    %{
      id: "posterior-max1-plus-source5-unbudgeted-diagnostic",
      strategy: "max1_plus_second",
      threshold: 0.55,
      max_per_pr: 2,
      total_budget: 9_999,
      second_min_source_count: 5,
      second_min_posterior: 0.0,
      eligible_for_promotion: false,
      diagnostic: true
    }
  ]

  def run!(opts) when is_map(opts) do
    opts
    |> Enum.map(fn {key, value} ->
      {String.to_atom(to_string(key) |> String.replace("-", "_")), value}
    end)
    |> run!()
  end

  def run!(opts) when is_list(opts) do
    suite = Keyword.get(opts, :suite, "martian-offline")
    limit = opts |> Keyword.get(:limit, 50) |> int()
    offset = opts |> Keyword.get(:offset, 0) |> int()
    id = Keyword.get(opts, :id, "pcrs-ensemble-publisher-v0")
    baseline_run = Keyword.get(opts, :baseline_run, @default_baseline_run)
    candidate_run = Keyword.get(opts, :candidate_run, @default_candidate_run)
    sources = sources(baseline_run, candidate_run)
    cases = Sugary.PublicBenchmarks.load_cases!(suite, limit: limit, offset: offset)
    out_dir = make_out_dir(id)

    File.rm_rf!(out_dir)
    File.mkdir_p!(out_dir)

    baseline = baseline_report(baseline_run, cases)
    case_pools = Enum.map(cases, &case_pool(&1, sources))
    pool_report = candidate_pool_report(case_pools)

    policy_reports =
      Enum.map(@policies, &policy_report(&1, case_pools, pool_report.expected_claims))

    winner = choose_winner(policy_reports, baseline)
    leave_repo_out = repo_group_generalization(winner, baseline)
    repo_group_deltas = repo_group_deltas(policy_reports, baseline)
    frontier = frontier_report(policy_reports, baseline, pool_report)
    bootstrap = bootstrap_report(policy_reports, baseline)
    suppressed_true_positives = suppressed_true_positive_report(policy_reports)
    admitted_false_positives = admitted_false_positive_report(policy_reports)
    calibration = calibration_report(case_pools, winner)
    marginal_precision_bands = marginal_precision_bands(policy_reports)
    decision = decision(policy_reports, winner, baseline, pool_report, leave_repo_out)

    write_artifacts!(
      out_dir,
      %{
        suite: suite,
        limit: limit,
        offset: offset,
        baseline_run: baseline_run,
        candidate_run: candidate_run,
        sources: sources,
        baseline: baseline,
        pool_report: pool_report,
        policies: policy_reports,
        winner: winner,
        leave_repo_out: leave_repo_out,
        repo_group_deltas: repo_group_deltas,
        frontier: frontier,
        bootstrap: bootstrap,
        suppressed_true_positives: suppressed_true_positives,
        admitted_false_positives: admitted_false_positives,
        calibration: calibration,
        marginal_precision_bands: marginal_precision_bands,
        decision: decision
      }
    )

    out_dir
  end

  def method_id, do: @method_id

  defp sources(baseline_run, candidate_run) do
    @default_sources
    |> Enum.map(fn source ->
      source
      |> maybe_replace_run(@default_baseline_run, baseline_run)
      |> maybe_replace_run(@default_candidate_run, candidate_run)
    end)
  end

  defp maybe_replace_run(source, old, new),
    do: if(source.run == old, do: %{source | run: new}, else: source)

  defp baseline_report(run, cases) do
    results =
      Enum.map(cases, fn bench_case ->
        claims =
          run
          |> claims_path("pcrs-codex-repo-low-strict", bench_case.id)
          |> Sugary.Json.read!()
          |> Enum.map(&atomize/1)

        final_claims = publish_team_ev(claims, @baseline_policy)

        %{
          case: bench_case,
          reviewer_result: %{cost: 0.0, latency_ms: 0},
          candidate_claims: claims,
          final_claims: final_claims
        }
      end)

    %{
      id: "baseline-team-ev-max-2",
      score: score("baseline-team-ev-max-2", results),
      results: results,
      per_case: Enum.map(results, &case_row/1)
    }
  end

  defp case_pool(bench_case, sources) do
    raw =
      sources
      |> Enum.flat_map(fn source ->
        source.run
        |> claims_path(source.method, bench_case.id)
        |> case do
          nil ->
            []

          path ->
            path
            |> Sugary.Json.read!()
            |> Enum.map(&normalize_claim(&1, source))
        end
      end)

    candidates =
      raw
      |> merge_candidates(bench_case)
      |> Enum.map(&add_labels(bench_case, &1))
      |> Enum.map(&add_posterior(&1))
      |> Enum.sort_by(& &1.posterior, :desc)

    %{
      case: bench_case,
      repo_group: repo_group(bench_case),
      raw_claims: raw,
      candidates: candidates
    }
  end

  defp claims_path(run, method_id, case_id) do
    aggregate = Path.join([run, "claims", "#{method_id}--#{case_id}.json"])
    method_local = Path.join([run, method_id, "claims", "#{case_id}.json"])

    cond do
      File.exists?(aggregate) -> aggregate
      File.exists?(method_local) -> method_local
      true -> nil
    end
  end

  defp normalize_claim(raw_claim, source) do
    claim = atomize(raw_claim)
    existing_source = field(claim, :source, %{})

    claim
    |> Map.put(:source_run, source.run)
    |> Map.put(:source_method, source.method)
    |> Map.put(:source_id, source.source)
    |> Map.put(:source_pool, Map.get(source, :pool, :core))
    |> Map.put(:source_family, Map.get(source, :family, source.source))
    |> Map.put(:source_prior, Map.get(source, :source_prior, 0.5))
    |> Map.put(
      :source,
      Map.merge(existing_source, %{
        ensemble_source_id: source.source,
        ensemble_pool: Map.get(source, :pool, :core),
        ensemble_family: Map.get(source, :family, source.source),
        ensemble_source_prior: Map.get(source, :source_prior, 0.5)
      })
    )
    |> Map.put(:publish_decision, "suppress")
  end

  defp merge_candidates(raw, bench_case) do
    raw
    |> Enum.reduce([], fn claim, groups ->
      case Enum.find_index(groups, &same_candidate?(&1, claim)) do
        nil ->
          [[claim] | groups]

        index ->
          List.update_at(groups, index, &[claim | &1])
      end
    end)
    |> Enum.map(&merged_candidate(&1, bench_case))
  end

  defp same_candidate?(group, claim) do
    representative = hd(group)

    (explicit_key(representative) != "" and explicit_key(representative) == explicit_key(claim)) or
      (normalize_path(field(representative, :path)) == normalize_path(field(claim, :path)) and
         normalize_path(field(claim, :path)) not in ["", "unknown"] and
         token_jaccard(claim_text(representative), claim_text(claim)) >= 0.30)
  end

  defp merged_candidate(claims, bench_case) do
    representative = Enum.max_by(claims, &base_rank/1)
    source_ids = claims |> Enum.map(&field(&1, :source_id)) |> Enum.uniq() |> Enum.sort()
    source_methods = claims |> Enum.map(&field(&1, :source_method)) |> Enum.uniq() |> Enum.sort()

    source_pools =
      claims |> Enum.map(&field(&1, :source_pool, :core)) |> Enum.uniq() |> Enum.sort()

    source_families = claims |> Enum.map(&field(&1, :source_family)) |> Enum.uniq() |> Enum.sort()

    evidence =
      claims |> Enum.flat_map(&(field(&1, :evidence, []) |> List.wrap())) |> uniq_by_summary()

    failure_path =
      claims |> Enum.flat_map(&(field(&1, :failure_path, []) |> List.wrap())) |> Enum.uniq()

    merged_source =
      representative
      |> field(:source, %{})
      |> Map.merge(%{
        agreement_count: length(source_ids),
        ensemble_source_ids: source_ids,
        ensemble_source_methods: source_methods,
        ensemble_source_pools: source_pools,
        ensemble_source_families: source_families,
        merged_claim_count: length(claims)
      })

    representative
    |> Map.put(:id, "ensemble-#{short_hash(bench_case.id <> ":" <> merge_key(representative))}")
    |> Map.put(:claim, merged_claim_text(representative, claims))
    |> Map.put(:evidence, evidence)
    |> Map.put(:failure_path, failure_path)
    |> Map.put(:source, merged_source)
    |> Map.put(:source_ids, source_ids)
    |> Map.put(:source_methods, source_methods)
    |> Map.put(:source_pools, source_pools)
    |> Map.put(:source_families, source_families)
    |> Map.put(:merged_claims, Enum.map(claims, &field(&1, :id)))
    |> Map.put(:features, features(representative, claims, bench_case, source_ids))
  end

  defp merged_claim_text(representative, claims) do
    variants =
      claims
      |> Enum.map(&field(&1, :claim))
      |> Enum.reject(&(&1 in [nil, ""]))
      |> Enum.uniq()
      |> Enum.take(3)

    case variants do
      [] -> field(representative, :claim)
      [one] -> one
      [_one | _rest] -> Enum.join(variants, " ")
    end
  end

  defp features(representative, claims, bench_case, source_ids) do
    evidence = claims |> Enum.flat_map(&(field(&1, :evidence, []) |> List.wrap()))

    categories =
      claims |> Enum.map(&(field(&1, :category, "") |> to_string() |> String.downcase()))

    path = field(representative, :path)
    source_pools = claims |> Enum.map(&field(&1, :source_pool, :core))
    source_families = claims |> Enum.map(&field(&1, :source_family)) |> Enum.uniq()
    source_priors = claims |> Enum.map(&(field(&1, :source_prior, 0.5) || 0.5))
    core_source_count = Enum.count(source_pools, &(&1 == :core or &1 == "core"))
    tail_source_count = Enum.count(source_pools, &(&1 == :tail or &1 == "tail"))

    base = %{
      max_confidence:
        Enum.map(claims, &(field(&1, :confidence, 0.0) || 0.0)) |> Enum.max(fn -> 0.0 end),
      source_prior:
        if(source_priors == [],
          do: 0.5,
          else: Enum.sum(source_priors) / max(length(source_priors), 1)
        ),
      max_source_prior: Enum.max(source_priors, fn -> 0.5 end),
      severity_weight:
        claims |> Enum.map(&(field(&1, :severity) |> severity_weight())) |> Enum.max(fn -> 1 end),
      strongest_evidence_tier:
        evidence |> Enum.map(&(field(&1, :tier, 5) || 5)) |> Enum.min(fn -> 5 end),
      evidence_count: length(evidence),
      source_count: length(source_ids),
      source_family_count: length(source_families),
      core_source_count: core_source_count,
      tail_source_count: tail_source_count,
      tail_only: tail_source_count > 0 and core_source_count == 0,
      has_tail: tail_source_count > 0,
      has_strict: Enum.any?(source_ids, &String.contains?(&1, "strict")),
      has_broad_repo: "broad-repo" in source_ids,
      has_proof_diff: "proof-diff" in source_ids,
      has_prior_team: "prior-team" in source_ids,
      has_repo_raw: "repo-raw" in source_ids,
      has_xhigh: Enum.any?(source_ids, &String.contains?(&1, "xhigh")),
      has_materialized: Enum.any?(source_ids, &String.contains?(&1, "materialized")),
      has_tail_team:
        Enum.any?(
          source_ids,
          &(String.contains?(&1, "tail-transfer-team") or &1 == "tail-fresh-team")
        ),
      path_known: normalize_path(path) not in ["", "unknown"],
      line_known: not is_nil(field(representative, :start_line) || field(representative, :line)),
      changed_file_support: changed_file_support?(bench_case, path),
      has_failure_path:
        claims |> Enum.any?(&(field(&1, :failure_path, []) |> List.wrap() |> length() > 0)),
      has_suggested_test: claims |> Enum.any?(&(field(&1, :suggested_test, "") not in [nil, ""])),
      introduced_by_pr: Enum.any?(claims, &(field(&1, :introduced_by_pr, true) == true)),
      risk_category: risk_category?(categories),
      low_style:
        Enum.any?(
          claims,
          &(field(&1, :category, "") == "style" or field(&1, :severity, "") == "low")
        ),
      weak_or_missing_evidence: evidence == [] or Enum.all?(evidence, &(field(&1, :tier, 5) >= 5))
    }

    Map.put(base, :tail_verified, tail_verified?(base))
  end

  defp tail_verified?(features) do
    not features.tail_only or
      features.source_count >= 2 or
      (features.max_confidence >= 0.82 and features.path_known and features.changed_file_support and
         features.has_failure_path and not features.weak_or_missing_evidence and
         (features.risk_category or features.has_suggested_test or features.has_xhigh or
            features.has_tail_team))
  end

  defp add_labels(bench_case, candidate) do
    expected = Sugary.ClaimMatcher.expected_claim(bench_case, candidate)
    known_non_issue = Sugary.ClaimMatcher.known_non_issue(bench_case, candidate)

    candidate
    |> Map.put(:expected_id, if(expected, do: field(expected, :id), else: nil))
    |> Map.put(:is_true_positive, not is_nil(expected) and is_nil(known_non_issue))
    |> Map.put(:is_noise, is_nil(expected) or not is_nil(known_non_issue))
  end

  defp add_posterior(candidate) do
    legacy_raw = legacy_posterior_score(candidate.features)
    legacy_posterior = 1.0 / (1.0 + :math.exp(-5.0 * (legacy_raw - 0.62)))
    tail_raw = tail_posterior_score(candidate.features)
    tail_posterior = 1.0 / (1.0 + :math.exp(-5.0 * (tail_raw - 0.62)))

    candidate
    |> Map.put(:legacy_raw_posterior_score, legacy_raw)
    |> Map.put(:legacy_posterior, legacy_posterior)
    |> Map.put(:raw_posterior_score, tail_raw)
    |> Map.put(:posterior, tail_posterior)
  end

  defp legacy_posterior_score(f) do
    source_count = if f.core_source_count > 0, do: f.core_source_count, else: f.source_count

    0.0
    |> Kernel.+(0.30 * clamp(f.max_confidence))
    |> Kernel.+(0.10 * normalize(f.severity_weight, 4))
    |> Kernel.+(0.12 * evidence_score(f.strongest_evidence_tier))
    |> Kernel.+(0.16 * normalize(min(source_count, 4), 4))
    |> Kernel.+(if(f.has_strict, do: 0.11, else: 0.0))
    |> Kernel.+(if(f.has_broad_repo, do: 0.07, else: 0.0))
    |> Kernel.+(if(f.has_proof_diff, do: 0.05, else: 0.0))
    |> Kernel.+(if(f.has_prior_team, do: 0.04, else: 0.0))
    |> Kernel.+(if(f.path_known, do: 0.06, else: -0.04))
    |> Kernel.+(if(f.line_known, do: 0.04, else: 0.0))
    |> Kernel.+(if(f.changed_file_support, do: 0.05, else: -0.02))
    |> Kernel.+(if(f.has_failure_path, do: 0.06, else: -0.02))
    |> Kernel.+(if(f.has_suggested_test, do: 0.03, else: 0.0))
    |> Kernel.+(if(f.risk_category, do: 0.04, else: 0.0))
    |> Kernel.+(if(f.introduced_by_pr, do: 0.02, else: -0.18))
    |> Kernel.-(if(f.low_style, do: 0.08, else: 0.0))
    |> Kernel.-(if(f.weak_or_missing_evidence, do: 0.10, else: 0.0))
    |> clamp()
  end

  defp tail_posterior_score(f) do
    0.0
    |> Kernel.+(0.30 * clamp(f.max_confidence))
    |> Kernel.+(0.10 * clamp(f.source_prior))
    |> Kernel.+(0.10 * normalize(f.severity_weight, 4))
    |> Kernel.+(0.12 * evidence_score(f.strongest_evidence_tier))
    |> Kernel.+(0.12 * normalize(min(f.source_count, 4), 4))
    |> Kernel.+(0.05 * normalize(min(f.source_family_count, 3), 3))
    |> Kernel.+(if(f.has_strict, do: 0.11, else: 0.0))
    |> Kernel.+(if(f.has_broad_repo, do: 0.07, else: 0.0))
    |> Kernel.+(if(f.has_proof_diff, do: 0.05, else: 0.0))
    |> Kernel.+(if(f.has_prior_team, do: 0.04, else: 0.0))
    |> Kernel.+(if(f.has_xhigh, do: 0.04, else: 0.0))
    |> Kernel.+(if(f.has_materialized, do: 0.03, else: 0.0))
    |> Kernel.+(if(f.path_known, do: 0.06, else: -0.04))
    |> Kernel.+(if(f.line_known, do: 0.04, else: 0.0))
    |> Kernel.+(if(f.changed_file_support, do: 0.05, else: -0.02))
    |> Kernel.+(if(f.has_failure_path, do: 0.06, else: -0.02))
    |> Kernel.+(if(f.has_suggested_test, do: 0.03, else: 0.0))
    |> Kernel.+(if(f.risk_category, do: 0.04, else: 0.0))
    |> Kernel.+(if(f.introduced_by_pr, do: 0.02, else: -0.18))
    |> Kernel.+(if(f.tail_verified, do: 0.04, else: -0.18))
    |> Kernel.-(if(f.low_style, do: 0.08, else: 0.0))
    |> Kernel.-(if(f.weak_or_missing_evidence, do: 0.10, else: 0.0))
    |> Kernel.-(if(f.tail_only and f.max_source_prior < 0.50, do: 0.05, else: 0.0))
    |> clamp()
  end

  defp policy_report(policy, case_pools, expected_total) do
    selected = selected_candidate_ids(case_pools, policy)
    results = Enum.map(case_pools, &policy_case_result(&1, policy, selected))
    score = score(policy.id, results)
    per_case = Enum.map(results, &case_row/1)

    %{
      id: policy.id,
      policy: policy,
      score: score,
      usefulness_adjusted_f1: uaf1(score),
      theoretical_max_f1_at_budget: theoretical_max_f1(policy, expected_total),
      results: results,
      per_case: per_case,
      recall_at_budget: recall_at_budget(case_pools, policy, selected),
      tp_at_1: tp_at_k(case_pools, 1),
      tp_at_2: tp_at_k(case_pools, 2),
      suppressed_tp: suppressed_tp(results),
      admitted_fp: score.noise,
      calibration: calibration_buckets(results)
    }
  end

  defp theoretical_max_f1(policy, expected_total) do
    budget = min(Map.get(policy, :total_budget, 0), expected_total)
    ratio(2 * budget, expected_total + budget)
  end

  defp policy_case_result(case_pool, policy, selected) do
    final_claims = publish_posterior(case_pool.candidates, policy, selected)

    %{
      case: case_pool.case,
      reviewer_result: %{cost: 0.0, latency_ms: 0},
      candidate_claims:
        Enum.map(case_pool.candidates, &Map.put(&1, :publish_decision, "suppress")),
      final_claims: final_claims
    }
  end

  defp publish_posterior(candidates, policy, selected) do
    candidates
    |> policy_case_candidates(policy)
    |> Enum.map(fn claim ->
      claim =
        claim
        |> Map.put(:posterior, policy_posterior(claim, policy))
        |> Map.put(:raw_posterior_score, policy_raw_posterior_score(claim, policy))

      if MapSet.member?(selected, claim.id) do
        Map.put(claim, :publish_decision, "publish")
      else
        claim
        |> Map.put(:publish_decision, "suppress")
        |> Map.put(:suppressed_reason, "posterior_below_threshold")
      end
    end)
  end

  defp selected_candidate_ids(case_pools, policy) do
    if Map.get(policy, :strategy) == "trust_plus_tail" do
      trust_plus_tail_selected_candidate_ids(case_pools, policy)
    else
      posterior_selected_candidate_ids(case_pools, policy)
    end
  end

  defp posterior_selected_candidate_ids(case_pools, policy) do
    case_pools
    |> Enum.flat_map(fn case_pool ->
      policy_case_candidates(case_pool.candidates, policy)
    end)
    |> Enum.filter(&(policy_posterior(&1, policy) >= policy.threshold))
    |> Enum.sort_by(&policy_posterior(&1, policy), :desc)
    |> Enum.take(policy.total_budget)
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp trust_plus_tail_selected_candidate_ids(case_pools, policy) do
    base_policy = base_policy!(policy)
    base_selected = posterior_selected_candidate_ids(case_pools, base_policy)

    base_claims =
      case_pools
      |> Enum.flat_map(fn case_pool ->
        case_pool.candidates
        |> policy_case_candidates(base_policy)
        |> Enum.filter(&MapSet.member?(base_selected, &1.id))
        |> Enum.map(&Map.put(&1, :case_id, case_pool.case.id))
      end)

    supplemental_budget =
      Map.get(policy, :supplemental_budget, policy.total_budget - MapSet.size(base_selected))

    max_supplemental_per_pr = Map.get(policy, :max_supplemental_per_pr, 1)

    supplemental_candidates =
      case_pools
      |> Enum.flat_map(fn case_pool ->
        case_pool.candidates
        |> Enum.reject(&MapSet.member?(base_selected, &1.id))
        |> Enum.filter(&supplemental_allowed?(&1, policy))
        |> Enum.map(&Map.put(&1, :case_id, case_pool.case.id))
      end)
      |> Enum.sort_by(&supplemental_score(&1, policy), :desc)

    {supplemental, _counts} =
      Enum.reduce(supplemental_candidates, {[], %{}}, fn candidate, {selected, counts} ->
        case_id = candidate.case_id
        already_selected = base_claims ++ selected

        cond do
          length(selected) >= supplemental_budget ->
            {selected, counts}

          Map.get(counts, case_id, 0) >= max_supplemental_per_pr ->
            {selected, counts}

          near_duplicate?(
            candidate,
            already_selected,
            Map.get(policy, :near_duplicate_jaccard, 0.18)
          ) ->
            {selected, counts}

          true ->
            {[candidate | selected], Map.update(counts, case_id, 1, &(&1 + 1))}
        end
      end)

    (Enum.map(base_claims, & &1.id) ++ Enum.map(supplemental, & &1.id))
    |> Enum.take(policy.total_budget)
    |> MapSet.new()
  end

  defp base_policy!(policy) do
    base_id = Map.fetch!(policy, :base_policy_id)

    Enum.find(@policies, &(&1.id == base_id)) ||
      raise ArgumentError, "unknown base PCRS policy #{inspect(base_id)}"
  end

  defp policy_case_candidates(candidates, %{strategy: "max1_plus_second"} = policy) do
    sorted =
      candidates
      |> Enum.filter(&allowed_by_policy?(&1, policy))
      |> Enum.sort_by(&policy_posterior(&1, policy), :desc)

    first = Enum.take(sorted, 1)

    second =
      sorted
      |> Enum.drop(1)
      |> Enum.filter(fn candidate ->
        policy_posterior(candidate, policy) >= Map.get(policy, :second_min_posterior, 0.0) and
          policy_source_count(candidate, policy) >= Map.get(policy, :second_min_source_count, 1)
      end)
      |> Enum.take(max(policy.max_per_pr - 1, 0))

    first ++ second
  end

  defp policy_case_candidates(candidates, %{strategy: "trust_plus_tail"} = policy) do
    base_policy = base_policy!(policy)

    candidates
    |> Enum.filter(&(allowed_by_policy?(&1, base_policy) or supplemental_allowed?(&1, policy)))
    |> Enum.sort_by(&supplemental_score(&1, policy), :desc)
  end

  defp policy_case_candidates(candidates, policy) do
    candidates
    |> Enum.filter(&allowed_by_policy?(&1, policy))
    |> Enum.sort_by(&policy_posterior(&1, policy), :desc)
    |> Enum.take(policy.max_per_pr)
  end

  defp policy_posterior(candidate, policy) do
    if policy_ranker(policy) == :legacy do
      candidate.legacy_posterior
    else
      candidate.posterior
    end
  end

  defp policy_raw_posterior_score(candidate, policy) do
    if policy_ranker(policy) == :legacy do
      candidate.legacy_raw_posterior_score
    else
      candidate.raw_posterior_score
    end
  end

  defp policy_ranker(policy) do
    case Map.get(policy, :ranker) do
      nil ->
        if Map.get(policy, :mode) in ["qualified_f1", "raw_f1_diagnostic"],
          do: :tail,
          else: :legacy

      value ->
        value
    end
  end

  defp allowed_by_policy?(candidate, policy) do
    source_count = policy_source_count(candidate, policy)

    source_count not in Map.get(policy, :exclude_source_counts, []) and
      pool_allowed?(candidate, policy) and
      tail_allowed?(candidate, policy) and
      qualified_triad?(candidate, policy)
  end

  defp pool_allowed?(candidate, %{pool_scope: :core}) do
    candidate.features.core_source_count > 0
  end

  defp pool_allowed?(_candidate, _policy), do: true

  defp tail_allowed?(candidate, %{require_tail_verification: true}) do
    not candidate.features.tail_only or candidate.features.tail_verified
  end

  defp tail_allowed?(_candidate, _policy), do: true

  defp supplemental_allowed?(candidate, policy) do
    candidate.features.tail_verified and
      supplemental_filter_allowed?(
        candidate.features,
        Map.get(policy, :supplemental_filter, "tail_team")
      )
  end

  defp supplemental_filter_allowed?(features, "tail_team"), do: features.has_tail_team

  defp supplemental_filter_allowed?(features, "tail_team_or_xhigh"),
    do: features.has_tail_team or features.has_xhigh

  defp supplemental_filter_allowed?(features, "materialized_xhigh_team_source2") do
    (features.has_materialized or features.has_xhigh or features.has_tail_team) and
      features.source_count >= 2
  end

  defp supplemental_filter_allowed?(features, "source3_tail"),
    do: features.has_tail and features.source_count >= 3

  defp supplemental_filter_allowed?(_features, _filter), do: false

  defp supplemental_score(candidate, _policy) do
    f = candidate.features

    candidate.posterior +
      if_score(f.has_xhigh, 0.18) +
      if_score(f.has_tail_team, 0.10) +
      if_score(f.has_materialized, 0.07) +
      0.04 * min(f.source_count, 4) -
      if_score(f.tail_only, 0.03)
  end

  defp if_score(true, value), do: value
  defp if_score(_value, _score), do: 0.0

  defp near_duplicate?(candidate, selected_claims, threshold) do
    Enum.any?(selected_claims, fn selected ->
      field(selected, :case_id) == field(candidate, :case_id) and
        (token_jaccard(field(selected, :claim), field(candidate, :claim)) >= threshold or
           (normalize_path(field(selected, :path)) == normalize_path(field(candidate, :path)) and
              field(selected, :category) == field(candidate, :category) and
              token_jaccard(field(selected, :claim), field(candidate, :claim)) >= threshold / 2))
    end)
  end

  defp qualified_triad?(candidate, %{require_qualified_triad: true} = policy) do
    policy_source_count(candidate, policy) != 3 or
      (candidate.features.has_repo_raw and candidate.features.has_prior_team and
         candidate.features.has_strict)
  end

  defp qualified_triad?(_candidate, _policy), do: true

  defp policy_source_count(candidate, %{pool_scope: :core}) do
    candidate.features.core_source_count
  end

  defp policy_source_count(candidate, _policy), do: candidate.features.source_count

  defp choose_winner(policy_reports, _baseline) do
    qualified = best_qualified_f1(policy_reports)
    v0 = Enum.find(policy_reports, &(&1.id == @v0_policy_id))
    product_default = best_product_default(policy_reports, v0)

    cond do
      qualified != nil and qualified.score.f1 >= 0.520 and qualified.score.precision >= 0.70 ->
        qualified

      product_default != nil ->
        product_default

      true ->
        Enum.max_by(policy_reports, &{uaf1(&1.score), &1.score.f1, -&1.score.noise}, fn -> nil end)
    end
  end

  defp candidate_pool_report(case_pools) do
    expected_total =
      case_pools
      |> Enum.map(&(Sugary.ClaimMatcher.expected_ids(&1.case) |> MapSet.size()))
      |> Enum.sum()

    hits_by_case =
      Enum.map(case_pools, fn case_pool ->
        ids =
          case_pool.candidates
          |> Enum.flat_map(fn candidate ->
            if candidate.expected_id, do: [candidate.expected_id], else: []
          end)
          |> MapSet.new()

        %{
          case_id: case_pool.case.id,
          repo_group: case_pool.repo_group,
          expected: Sugary.ClaimMatcher.expected_ids(case_pool.case) |> MapSet.size(),
          pool_hits: MapSet.size(ids),
          raw_claims: length(case_pool.raw_claims),
          merged_candidates: length(case_pool.candidates),
          tail_candidates: Enum.count(case_pool.candidates, & &1.features.has_tail),
          tail_only_candidates: Enum.count(case_pool.candidates, & &1.features.tail_only),
          tail_verified_candidates: Enum.count(case_pool.candidates, & &1.features.tail_verified)
        }
      end)

    pool_hits = Enum.sum(Enum.map(hits_by_case, & &1.pool_hits))

    %{
      expected_claims: expected_total,
      pool_hits: pool_hits,
      oracle_recall: ratio(pool_hits, expected_total),
      raw_claims: Enum.sum(Enum.map(case_pools, &length(&1.raw_claims))),
      merged_candidates: Enum.sum(Enum.map(case_pools, &length(&1.candidates))),
      tail_candidates:
        case_pools
        |> Enum.flat_map(& &1.candidates)
        |> Enum.count(& &1.features.has_tail),
      tail_only_candidates:
        case_pools
        |> Enum.flat_map(& &1.candidates)
        |> Enum.count(& &1.features.tail_only),
      tail_verified_candidates:
        case_pools
        |> Enum.flat_map(& &1.candidates)
        |> Enum.count(& &1.features.tail_verified),
      per_case: hits_by_case
    }
  end

  defp recall_at_budget(case_pools, policy, selected) do
    hit_ids =
      case_pools
      |> Enum.flat_map(fn case_pool ->
        case_pool.candidates
        |> Enum.filter(&MapSet.member?(selected, &1.id))
        |> Enum.map(&Map.put(&1, :case_id, case_pool.case.id))
      end)
      |> Enum.flat_map(fn candidate ->
        if candidate.expected_id do
          ["#{candidate.case_id}:#{candidate.expected_id}"]
        else
          []
        end
      end)
      |> MapSet.new()

    %{
      budget: policy.total_budget,
      selected: MapSet.size(selected),
      hits: MapSet.size(hit_ids),
      recall: ratio(MapSet.size(hit_ids), @expected_claims)
    }
  end

  defp tp_at_k(case_pools, k) do
    case_pools
    |> Enum.count(fn case_pool ->
      case_pool.candidates
      |> Enum.sort_by(& &1.posterior, :desc)
      |> Enum.take(k)
      |> Enum.any?(& &1.is_true_positive)
    end)
  end

  defp suppressed_tp(results) do
    Enum.reduce(results, 0, fn result, total ->
      candidate_ids =
        result.candidate_claims
        |> Enum.flat_map(fn claim -> if claim.expected_id, do: [claim.expected_id], else: [] end)
        |> MapSet.new()

      published_ids =
        result.final_claims
        |> Enum.filter(&(&1.publish_decision == "publish"))
        |> Enum.flat_map(fn claim -> if claim.expected_id, do: [claim.expected_id], else: [] end)
        |> MapSet.new()

      total + MapSet.size(MapSet.difference(candidate_ids, published_ids))
    end)
  end

  defp calibration_buckets(results) do
    results
    |> Enum.flat_map(& &1.final_claims)
    |> Enum.group_by(fn claim ->
      low = Float.floor((claim.posterior || 0.0) * 10) / 10
      high = low + 0.1
      "#{fmt(low)}-#{fmt(high)}"
    end)
    |> Map.new(fn {bucket, claims} ->
      tp = Enum.count(claims, & &1.is_true_positive)
      fp = length(claims) - tp
      {bucket, %{claims: length(claims), tp: tp, fp: fp, precision: ratio(tp, length(claims))}}
    end)
  end

  defp calibration_report(_case_pools, nil), do: %{}
  defp calibration_report(_case_pools, winner), do: winner.calibration

  defp repo_group_generalization(nil, _baseline) do
    %{mode: "winner_repo_group_slice", rows: [], repo_groups_passing: 0, repo_group_count: 0}
  end

  defp repo_group_generalization(winner, baseline) do
    base_by_case = Map.new(baseline.per_case, &{&1.case_id, &1})

    groups =
      winner.per_case
      |> Enum.map(& &1.repo_group)
      |> Enum.uniq()
      |> Enum.sort()

    rows =
      Enum.map(groups, fn group ->
        policy_rows = Enum.filter(winner.per_case, &(&1.repo_group == group))
        score = aggregate_case_rows(policy_rows)

        baseline_rows =
          policy_rows
          |> Enum.map(&Map.fetch!(base_by_case, &1.case_id))

        baseline_score = aggregate_case_rows(baseline_rows)
        usefulness_adjusted_f1 = score.f1 * score.usefulness

        %{
          repo_group: group,
          policy_id: winner.id,
          score: score,
          usefulness_adjusted_f1: usefulness_adjusted_f1,
          baseline: baseline_score,
          baseline_usefulness_adjusted_f1: baseline_score.f1 * baseline_score.usefulness,
          uaf1_delta: usefulness_adjusted_f1 - baseline_score.f1 * baseline_score.usefulness,
          noise_delta: score.noise - baseline_score.noise,
          hit_delta: score.hits - baseline_score.hits,
          passes: usefulness_adjusted_f1 >= baseline_score.f1 * baseline_score.usefulness
        }
      end)

    %{
      mode: "winner_repo_group_slice",
      rows: rows,
      repo_groups_passing: Enum.count(rows, & &1.passes),
      repo_group_count: length(rows)
    }
  end

  defp repo_group_deltas(policy_reports, baseline) do
    Map.new(policy_reports, fn report ->
      {report.id, repo_group_delta_rows(report, baseline)}
    end)
  end

  defp repo_group_delta_rows(report, baseline) do
    base_by_case = Map.new(baseline.per_case, &{&1.case_id, &1})

    report.per_case
    |> Enum.group_by(& &1.repo_group)
    |> Enum.map(fn {group, policy_rows} ->
      score = aggregate_case_rows(policy_rows)

      baseline_rows =
        policy_rows
        |> Enum.map(&Map.fetch!(base_by_case, &1.case_id))

      baseline_score = aggregate_case_rows(baseline_rows)
      policy_uaf1 = score.f1 * score.usefulness
      baseline_uaf1 = baseline_score.f1 * baseline_score.usefulness

      %{
        repo_group: group,
        policy_id: report.id,
        score: score,
        baseline: baseline_score,
        uaf1_delta: policy_uaf1 - baseline_uaf1,
        f1_delta: score.f1 - baseline_score.f1,
        hit_delta: score.hits - baseline_score.hits,
        noise_delta: score.noise - baseline_score.noise,
        passes: policy_uaf1 >= baseline_uaf1
      }
    end)
    |> Enum.sort_by(& &1.repo_group)
  end

  defp frontier_report(policy_reports, baseline, pool_report) do
    v0 = Enum.find(policy_reports, &(&1.id == @v0_policy_id))
    product_default = best_product_default(policy_reports, v0)
    leaderboard = best_leaderboard(policy_reports, v0)
    best_f1 = best_f1(policy_reports)

    budget_tiers =
      policy_reports
      |> Enum.group_by(&(Map.get(&1.policy, :budget_tier) || Map.get(&1.policy, :total_budget)))
      |> Enum.map(fn {budget, reports} ->
        best = Enum.max_by(reports, & &1.score.f1)

        %{
          budget: budget,
          theoretical_max_f1:
            theoretical_max_f1(%{total_budget: budget}, pool_report.expected_claims),
          best_policy: policy_summary(best),
          policies: Enum.map(reports, &policy_summary/1)
        }
      end)
      |> Enum.sort_by(& &1.budget)

    %{
      objective: "budget_f1_pareto_frontier",
      baseline: score_summary("team-ev-max-2", baseline.score),
      v0_policy_id: @v0_policy_id,
      v0: if(v0, do: policy_summary(v0), else: nil),
      product_default: if(product_default, do: policy_summary(product_default), else: nil),
      leaderboard_candidate: if(leaderboard, do: policy_summary(leaderboard), else: nil),
      best_f1_policy: if(best_f1, do: policy_summary(best_f1), else: nil),
      budget_tiers: budget_tiers,
      decision_rules: %{
        product_default_retained:
          product_default != nil and v0 != nil and product_default.id == v0.id and
            product_default.score.f1 >= v0.score.f1 and
            uaf1(product_default.score) >= uaf1(v0.score),
        leaderboard_precision_floor: 0.70,
        leaderboard_min_f1_delta: 0.02,
        leaderboard_promoted:
          leaderboard != nil and v0 != nil and leaderboard.score.precision >= 0.70 and
            leaderboard.score.f1 >= v0.score.f1 + 0.02
      },
      no_official_score_claim: true
    }
  end

  defp best_product_default(policy_reports, v0) do
    policy_reports
    |> Enum.reject(&diagnostic?/1)
    |> Enum.filter(&(Map.get(&1.policy, :budget_tier, Map.get(&1.policy, :total_budget)) <= 52))
    |> Enum.filter(fn report ->
      is_nil(v0) or (report.score.f1 >= v0.score.f1 and uaf1(report.score) >= uaf1(v0.score))
    end)
    |> Enum.max_by(&{uaf1(&1.score), &1.score.f1, &1.score.precision}, fn -> v0 end)
  end

  defp best_leaderboard(policy_reports, v0) do
    policy_reports
    |> Enum.reject(&diagnostic?/1)
    |> Enum.filter(&(Map.get(&1.policy, :budget_tier, Map.get(&1.policy, :total_budget)) > 52))
    |> Enum.filter(&(&1.score.precision >= 0.70))
    |> Enum.filter(fn report -> is_nil(v0) or report.score.f1 >= v0.score.f1 + 0.02 end)
    |> Enum.max_by(&{&1.score.f1, uaf1(&1.score), &1.score.hits, -&1.score.noise}, fn -> nil end)
  end

  defp best_qualified_f1(policy_reports) do
    policy_reports
    |> Enum.reject(&diagnostic?/1)
    |> Enum.filter(&(Map.get(&1.policy, :mode) == "qualified_f1"))
    |> Enum.filter(&(&1.score.precision >= 0.70))
    |> Enum.max_by(&{&1.score.f1, &1.score.hits, uaf1(&1.score), -&1.score.noise}, fn -> nil end)
  end

  defp best_f1(policy_reports) do
    policy_reports
    |> Enum.reject(&diagnostic?/1)
    |> Enum.max_by(&{&1.score.f1, uaf1(&1.score), &1.score.precision}, fn -> nil end)
  end

  defp diagnostic?(report), do: Map.get(report.policy, :diagnostic, false) == true

  defp policy_summary(nil), do: nil

  defp policy_summary(report) do
    report
    |> Map.take([
      :id,
      :usefulness_adjusted_f1,
      :theoretical_max_f1_at_budget,
      :recall_at_budget,
      :suppressed_tp,
      :admitted_fp
    ])
    |> Map.put(:mode, Map.get(report.policy, :mode))
    |> Map.put(
      :budget_tier,
      Map.get(report.policy, :budget_tier, Map.get(report.policy, :total_budget))
    )
    |> Map.put(:score, score_summary(report.id, report.score))
  end

  defp score_summary(id, score) do
    %{
      id: id,
      f1: score.f1,
      usefulness_adjusted_f1: uaf1(score),
      precision: score.precision,
      recall: score.recall,
      hits: score.hits,
      noise: score.noise,
      comments: score.published_claims,
      avg_comments_per_pr: score.avg_comments_per_pr,
      snr: score.snr
    }
  end

  defp bootstrap_report(policy_reports, baseline) do
    v0 = Enum.find(policy_reports, &(&1.id == @v0_policy_id))

    Map.new(policy_reports, fn report ->
      {report.id,
       %{
         vs_team_ev_max_2: bootstrap_delta(report.per_case, baseline.per_case),
         vs_v0:
           if(v0 && v0.id != report.id,
             do: bootstrap_delta(report.per_case, v0.per_case),
             else: bootstrap_zero()
           )
       }}
    end)
  end

  defp bootstrap_delta(rows, baseline_rows) do
    count = length(rows)
    rows_by_case = Map.new(rows, &{&1.case_id, &1})
    baseline_by_case = Map.new(baseline_rows, &{&1.case_id, &1})
    case_ids = Map.keys(rows_by_case) |> Enum.sort()

    :rand.seed(:exsplus, {101, 102, 103})

    deltas =
      Enum.map(1..@bootstrap_samples, fn _index ->
        sample_ids = Enum.map(1..count, fn _ -> Enum.at(case_ids, :rand.uniform(count) - 1) end)
        sampled_rows = Enum.map(sample_ids, &Map.fetch!(rows_by_case, &1))
        sampled_baseline = Enum.map(sample_ids, &Map.fetch!(baseline_by_case, &1))
        sampled_score = aggregate_case_rows(sampled_rows)
        sampled_baseline_score = aggregate_case_rows(sampled_baseline)

        %{
          f1: sampled_score.f1 - sampled_baseline_score.f1,
          usefulness_adjusted_f1:
            sampled_score.f1 * sampled_score.usefulness -
              sampled_baseline_score.f1 * sampled_baseline_score.usefulness,
          precision: sampled_score.precision - sampled_baseline_score.precision,
          recall: sampled_score.recall - sampled_baseline_score.recall
        }
      end)

    %{
      samples: @bootstrap_samples,
      f1_delta: interval(deltas, :f1),
      usefulness_adjusted_f1_delta: interval(deltas, :usefulness_adjusted_f1),
      precision_delta: interval(deltas, :precision),
      recall_delta: interval(deltas, :recall)
    }
  end

  defp bootstrap_zero do
    zero = %{p025: 0.0, p50: 0.0, p975: 0.0}

    %{
      samples: @bootstrap_samples,
      f1_delta: zero,
      usefulness_adjusted_f1_delta: zero,
      precision_delta: zero,
      recall_delta: zero
    }
  end

  defp interval(deltas, key) do
    values = deltas |> Enum.map(&Map.fetch!(&1, key)) |> Enum.sort()

    %{
      p025: percentile(values, 0.025),
      p50: percentile(values, 0.5),
      p975: percentile(values, 0.975)
    }
  end

  defp percentile([], _p), do: 0.0

  defp percentile(values, p) do
    index = round((length(values) - 1) * p)
    Enum.at(values, index)
  end

  defp suppressed_true_positive_report(policy_reports) do
    Map.new(policy_reports, fn report ->
      {report.id,
       report.results
       |> Enum.flat_map(&suppressed_true_positive_rows/1)
       |> Enum.uniq_by(&{&1.case_id, &1.expected_id})
       |> Enum.sort_by(& &1.posterior, :desc)}
    end)
  end

  defp suppressed_true_positive_rows(result) do
    published_ids =
      result.final_claims
      |> Enum.filter(&(&1.publish_decision == "publish"))
      |> MapSet.new(& &1.id)

    result.candidate_claims
    |> Enum.reject(&MapSet.member?(published_ids, &1.id))
    |> Enum.filter(& &1.expected_id)
    |> Enum.map(&diagnostic_claim_row(result.case, &1))
  end

  defp admitted_false_positive_report(policy_reports) do
    Map.new(policy_reports, fn report ->
      {report.id,
       report.results
       |> Enum.flat_map(fn result ->
         result.final_claims
         |> Enum.filter(&(&1.publish_decision == "publish"))
         |> Enum.reject(& &1.expected_id)
         |> Enum.map(&diagnostic_claim_row(result.case, &1))
       end)
       |> Enum.sort_by(& &1.posterior, :desc)}
    end)
  end

  defp marginal_precision_bands(policy_reports) do
    Map.new(policy_reports, fn report ->
      bands =
        report.results
        |> Enum.flat_map(fn result ->
          result.final_claims
          |> Enum.filter(&(&1.publish_decision == "publish"))
          |> Enum.map(&Map.put(&1, :case_id, result.case.id))
        end)
        |> Enum.sort_by(& &1.posterior, :desc)
        |> Enum.chunk_every(10)
        |> Enum.with_index(1)
        |> Enum.map(fn {claims, index} ->
          tp = Enum.count(claims, & &1.is_true_positive)
          fp = length(claims) - tp

          %{
            band: index,
            start_rank: (index - 1) * 10 + 1,
            end_rank: (index - 1) * 10 + length(claims),
            claims: length(claims),
            hits: tp,
            noise: fp,
            marginal_precision: ratio(tp, length(claims)),
            min_posterior: claims |> Enum.map(& &1.posterior) |> Enum.min(fn -> 0.0 end),
            max_posterior: claims |> Enum.map(& &1.posterior) |> Enum.max(fn -> 0.0 end)
          }
        end)

      {report.id, bands}
    end)
  end

  defp diagnostic_claim_row(bench_case, claim) do
    %{
      case_id: bench_case.id,
      repo_group: repo_group(bench_case),
      claim_id: claim.id,
      expected_id: claim.expected_id,
      path: field(claim, :path),
      claim: claim.claim,
      posterior: claim.posterior,
      source_ids: claim.source_ids,
      source_pools: claim.source_pools,
      source_families: claim.source_families,
      classification: diagnostic_classification(claim),
      features: claim.features
    }
  end

  defp diagnostic_classification(%{is_true_positive: true} = claim) do
    cond do
      claim.features.tail_only and not claim.features.tail_verified ->
        "suppressed_tp_unverified_tail"

      claim.features.source_count == 1 ->
        "suppressed_tp_single_source"

      claim.posterior < 0.58 ->
        "suppressed_tp_low_posterior"

      true ->
        "suppressed_tp_budget_or_per_pr_limit"
    end
  end

  defp diagnostic_classification(claim) do
    cond do
      claim.features.tail_only and not claim.features.tail_verified ->
        "admitted_fp_unverified_tail"

      claim.features.low_style ->
        "admitted_fp_style_or_low_severity"

      not claim.features.changed_file_support ->
        "admitted_fp_no_changed_file_support"

      claim.features.weak_or_missing_evidence ->
        "admitted_fp_weak_evidence"

      claim.features.source_count == 1 ->
        "admitted_fp_single_source"

      true ->
        "admitted_fp_calibration_error"
    end
  end

  defp aggregate_case_rows(rows) do
    totals =
      Enum.reduce(
        rows,
        %{cases: 0, expected_claims: 0, published_claims: 0, hits: 0, noise: 0},
        fn row, acc ->
          %{
            cases: acc.cases + 1,
            expected_claims: acc.expected_claims + row.expected,
            published_claims: acc.published_claims + row.comments,
            hits: acc.hits + row.hits,
            noise: acc.noise + row.noise
          }
        end
      )

    precision = ratio(totals.hits, totals.published_claims)
    recall = ratio(totals.hits, totals.expected_claims)

    totals
    |> Map.put(:precision, precision)
    |> Map.put(:recall, recall)
    |> Map.put(
      :f1,
      if(precision + recall == 0, do: 0.0, else: 2 * precision * recall / (precision + recall))
    )
    |> Map.put(:usefulness, precision)
    |> Map.put(:avg_comments_per_pr, ratio(totals.published_claims, totals.cases))
  end

  defp decision(policy_reports, winner, _baseline, pool_report, leave_repo_out) do
    trust = Enum.find(policy_reports, &(&1.id == @v0_policy_id))
    qualified = best_qualified_f1(policy_reports)
    raw = best_raw_f1(policy_reports)
    checks = promotion_checks(trust, qualified, pool_report, leave_repo_out)
    passed = Enum.all?(Map.values(checks))

    %{
      decision: if(passed, do: "promote", else: "reject"),
      winner: winner && winner.id,
      trust_default: trust && trust.id,
      qualified_f1: qualified && qualified.id,
      raw_f1_diagnostic: raw && raw.id,
      checks: checks,
      reason:
        if(passed,
          do: "PCRS Ensemble Publisher v2 cleared the no-key local proxy gates.",
          else: "PCRS Ensemble Publisher v2 did not clear all no-key local proxy gates."
        )
    }
  end

  defp best_raw_f1(policy_reports) do
    policy_reports
    |> Enum.filter(&(Map.get(&1.policy, :mode) == "raw_f1_diagnostic"))
    |> Enum.max_by(&{&1.score.f1, &1.score.hits, -&1.score.noise}, fn -> nil end)
  end

  defp promotion_checks(nil, _qualified, _pool_report, _leave_repo_out),
    do: %{trust_default_exists: false}

  defp promotion_checks(_trust, nil, _pool_report, _leave_repo_out),
    do: %{qualified_f1_exists: false}

  defp promotion_checks(trust, qualified, pool_report, leave_repo_out) do
    trust_score = trust.score
    qualified_score = qualified.score

    %{
      trust_default_f1: trust_score.f1 >= 0.444,
      trust_default_precision: trust_score.precision >= 0.800,
      qualified_f1: qualified_score.f1 >= 0.520,
      qualified_precision: qualified_score.precision >= 0.700,
      qualified_hits: qualified_score.hits >= 56,
      candidate_pool_oracle_recall: pool_report.oracle_recall >= 0.570,
      no_duplicate_or_near_duplicate_inflation:
        pool_report.merged_candidates <= pool_report.raw_claims,
      leave_repo_out: leave_repo_out.repo_groups_passing >= 4,
      not_official_score: true
    }
  end

  defp write_artifacts!(out_dir, data) do
    report_policies = Enum.map(data.policies, &drop_results/1)
    winner = if(data.winner, do: drop_results(data.winner), else: nil)

    Sugary.Json.write!(Path.join(out_dir, "config.json"), %{
      suite: data.suite,
      limit: data.limit,
      offset: data.offset,
      baseline_run: data.baseline_run,
      candidate_run: data.candidate_run,
      sources: data.sources,
      method_id: @method_id,
      official_score_claim: false,
      martian_api_used: false
    })

    Sugary.Json.write!(Path.join(out_dir, "baseline-scorecard.json"), data.baseline.score)

    Sugary.Json.write!(
      Path.join(out_dir, "candidate-pool.json"),
      Map.drop(data.pool_report, [:per_case])
    )

    Sugary.Json.write!(
      Path.join(out_dir, "candidate-pool-per-case.json"),
      data.pool_report.per_case
    )

    write_candidate_details!(out_dir, data.policies)
    Sugary.Json.write!(Path.join(out_dir, "policy-scorecards.json"), report_policies)
    Sugary.Json.write!(Path.join(out_dir, "leave-repo-out.json"), data.leave_repo_out)
    Sugary.Json.write!(Path.join(out_dir, "repo-group-deltas.json"), data.repo_group_deltas)
    Sugary.Json.write!(Path.join(out_dir, "budget-frontier.json"), data.frontier)
    Sugary.Json.write!(Path.join(out_dir, "bootstrap.json"), data.bootstrap)

    Sugary.Json.write!(
      Path.join(out_dir, "suppressed-true-positives.json"),
      data.suppressed_true_positives
    )

    Sugary.Json.write!(
      Path.join(out_dir, "admitted-false-positives.json"),
      data.admitted_false_positives
    )

    Sugary.Json.write!(
      Path.join(out_dir, "calibration-by-policy.json"),
      Map.new(data.policies, &{&1.id, &1.calibration})
    )

    Sugary.Json.write!(Path.join(out_dir, "calibration.json"), data.calibration)

    Sugary.Json.write!(
      Path.join(out_dir, "marginal-precision-bands.json"),
      data.marginal_precision_bands
    )

    Sugary.Json.write!(Path.join(out_dir, "decision.json"), data.decision)
    write_policy_claims!(out_dir, data.policies)

    if data.winner do
      write_winner_claims!(out_dir, data.winner)
    end

    File.write!(Path.join(out_dir, "report.md"), render_report(data, winner, report_policies))
  end

  defp write_candidate_details!(out_dir, policies) do
    best = Enum.max_by(policies, &uaf1(&1.score), fn -> nil end)

    if best do
      details =
        best.results
        |> Enum.flat_map(fn result ->
          published_ids =
            result.final_claims
            |> Enum.filter(&(&1.publish_decision == "publish"))
            |> MapSet.new(& &1.id)

          Enum.map(result.candidate_claims, fn claim ->
            %{
              case_id: result.case.id,
              repo_group: repo_group(result.case),
              id: claim.id,
              claim: claim.claim,
              path: field(claim, :path),
              expected_id: claim.expected_id,
              is_true_positive: claim.is_true_positive,
              is_noise: claim.is_noise,
              posterior: claim.posterior,
              raw_posterior_score: claim.raw_posterior_score,
              published_by_best_uaf1_policy: MapSet.member?(published_ids, claim.id),
              features: claim.features,
              source_ids: claim.source_ids,
              source_methods: claim.source_methods,
              source_pools: claim.source_pools,
              source_families: claim.source_families,
              classification: diagnostic_classification(claim)
            }
          end)
        end)

      lines = Enum.map(details, &(Sugary.Json.encode!(&1) <> "\n"))
      File.write!(Path.join(out_dir, "candidate-details.jsonl"), lines)
    end
  end

  defp write_winner_claims!(out_dir, winner) do
    Enum.each(winner.results, fn result ->
      Sugary.Json.write!(
        Path.join([out_dir, "claims", "#{@method_id}--#{result.case.id}.json"]),
        result.final_claims
      )

      Sugary.Json.write!(
        Path.join([out_dir, @method_id, "claims", "#{result.case.id}.json"]),
        result.final_claims
      )
    end)
  end

  defp write_policy_claims!(out_dir, policies) do
    Enum.each(policies, fn policy ->
      Enum.each(policy.results, fn result ->
        Sugary.Json.write!(
          Path.join([out_dir, "claims", "#{policy.id}--#{result.case.id}.json"]),
          result.final_claims
        )

        Sugary.Json.write!(
          Path.join([out_dir, policy.id, "claims", "#{result.case.id}.json"]),
          result.final_claims
        )
      end)
    end)
  end

  defp render_report(data, winner, policy_reports) do
    baseline = data.baseline.score

    policy_rows =
      policy_reports
      |> Enum.map(fn report ->
        score = report.score

        "| #{report.id} | #{Map.get(report.policy, :mode, "candidate")} | #{Map.get(report.policy, :budget_tier, Map.get(report.policy, :total_budget))} | #{fmt(score.f1)} | #{fmt(report.theoretical_max_f1_at_budget)} | #{fmt(report.usefulness_adjusted_f1)} | #{fmt(score.precision)} | #{fmt(score.recall)} | #{score.hits} | #{score.noise} | #{score.published_claims} | #{fmt(score.avg_comments_per_pr)} | #{fmt(report.recall_at_budget.recall)} | #{report.suppressed_tp} | #{report.admitted_fp} |"
      end)
      |> Enum.join("\n")

    frontier_rows =
      data.frontier.budget_tiers
      |> Enum.map(fn tier ->
        best = tier.best_policy
        score = best.score

        "| #{tier.budget} | #{fmt(tier.theoretical_max_f1)} | #{best.id} | #{fmt(score.f1)} | #{fmt(score.precision)} | #{fmt(score.recall)} | #{score.hits} | #{score.noise} | #{score.comments} |"
      end)
      |> Enum.join("\n")

    bootstrap_rows =
      [
        data.frontier.product_default,
        data.frontier.leaderboard_candidate,
        data.frontier.best_f1_policy
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.map(fn summary ->
        bootstrap = Map.fetch!(data.bootstrap, summary.id)
        vs_baseline = bootstrap.vs_team_ev_max_2.usefulness_adjusted_f1_delta
        vs_v0 = bootstrap.vs_v0.usefulness_adjusted_f1_delta

        "| #{summary.id} | #{fmt(vs_baseline.p50)} [#{fmt(vs_baseline.p025)}, #{fmt(vs_baseline.p975)}] | #{fmt(vs_v0.p50)} [#{fmt(vs_v0.p025)}, #{fmt(vs_v0.p975)}] |"
      end)
      |> Enum.join("\n")

    lroo_rows =
      data.leave_repo_out.rows
      |> Enum.map(fn row ->
        "| #{row.repo_group} | #{row.policy_id} | #{fmt(row.uaf1_delta)} | #{row.hit_delta} | #{row.noise_delta} | #{row.passes} |"
      end)
      |> Enum.join("\n")

    band_rows =
      [
        data.frontier.product_default,
        data.frontier.leaderboard_candidate,
        data.frontier.best_f1_policy
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)
      |> Enum.flat_map(fn summary ->
        data.marginal_precision_bands
        |> Map.get(summary.id, [])
        |> Enum.map(fn band ->
          "| #{summary.id} | #{band.band} | #{band.start_rank}-#{band.end_rank} | #{band.claims} | #{band.hits} | #{band.noise} | #{fmt(band.marginal_precision)} | #{fmt(band.min_posterior)} | #{fmt(band.max_posterior)} |"
        end)
      end)
      |> Enum.join("\n")

    checks =
      data.decision.checks
      |> Enum.map(fn {key, value} -> "- #{key}: #{value}" end)
      |> Enum.join("\n")

    """
    # PCRS Ensemble Publisher Frontier

    No Martian API key was used. This is a no-key local proxy report, not an official Martian score.

    ## Baseline

    - Method: `pcrs-codex-repo-low-strict + team-ev-max-2`
    - F1: #{fmt(baseline.f1)}
    - UAF1: #{fmt(uaf1(baseline))}
    - Hits: #{baseline.hits}
    - Noise: #{baseline.noise}
    - Avg comments/PR: #{fmt(baseline.avg_comments_per_pr)}

    ## Candidate Pool

    - Raw claims: #{data.pool_report.raw_claims}
    - Merged candidates: #{data.pool_report.merged_candidates}
    - Candidate-pool oracle recall: #{fmt(data.pool_report.oracle_recall)}
    - Pool hits: #{data.pool_report.pool_hits}/#{data.pool_report.expected_claims}
    - Tail candidates: #{data.pool_report.tail_candidates}
    - Tail-only candidates: #{data.pool_report.tail_only_candidates}
    - Tail-verified candidates: #{data.pool_report.tail_verified_candidates}

    ## Budget Frontier

    | Budget | Max Possible F1 | Best Policy | F1 | Precision | Recall | Hits | Noise | Comments |
    | ---: | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
    #{frontier_rows}

    ## Policies

    | Policy | Mode | Budget | F1 | Max F1 | UAF1 | Precision | Recall | Hits | Noise | Comments | Avg Comments/PR | Recall@Budget | Suppressed TP | Admitted FP |
    | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    #{policy_rows}

    ## Bootstrap

    Paired bootstrap over cases. Intervals show UAF1 delta p50 [p025, p975].

    | Policy | vs team-ev-max-2 | vs v0 |
    | --- | ---: | ---: |
    #{bootstrap_rows}

    ## Marginal Precision Bands

    | Policy | Band | Rank Range | Claims | Hits | Noise | Marginal Precision | Min Posterior | Max Posterior |
    | --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: |
    #{band_rows}

    ## Repo Group Generalization

    Mode: `#{data.leave_repo_out.mode}`

    | Repo Group | Policy | UAF1 Delta | Hit Delta | Noise Delta | Passes |
    | --- | --- | ---: | ---: | ---: | --- |
    #{lroo_rows}

    ## Decision

    - Decision: `#{data.decision.decision}`
    - Winner: `#{if(winner, do: winner.id, else: "none")}`

    #{checks}

    #{data.decision.reason}
    """
  end

  defp drop_results(report) do
    report
    |> Map.drop([:results])
    |> Map.update!(:score, &Map.from_struct/1)
  end

  defp publish_team_ev(claims, policy) do
    claims
    |> Enum.sort_by(&team_ev_score/1, :desc)
    |> Enum.with_index()
    |> Enum.map(fn {claim, index} ->
      score = team_ev_score(claim)

      if index < policy.max_published and score >= policy.min_score do
        Map.put(claim, :publish_decision, "publish")
      else
        claim
        |> Map.put(:publish_decision, "suppress")
        |> Map.put(:suppressed_reason, "ranking_policy_threshold")
      end
    end)
  end

  defp team_ev_score(claim) do
    confidence = field(claim, :confidence, 0.0) || 0.0
    confidence * severity_weight(field(claim, :severity)) * agreement_count(claim)
  end

  defp case_row(result) do
    published = Enum.filter(result.final_claims, &(&1.publish_decision == "publish"))

    matched =
      published
      |> Enum.flat_map(fn claim ->
        case Sugary.ClaimMatcher.expected_claim(result.case, claim) do
          nil -> []
          expected -> [field(expected, :id)]
        end
      end)

    hit_ids = MapSet.new(matched)

    %{
      case_id: result.case.id,
      repo_group: repo_group(result.case),
      expected: Sugary.ClaimMatcher.expected_ids(result.case) |> MapSet.size(),
      comments: length(published),
      hits: MapSet.size(hit_ids),
      noise: length(published) - MapSet.size(hit_ids)
    }
  end

  defp score(method_id, results), do: Sugary.Scorer.score(method_id, results)
  defp uaf1(score), do: score.f1 * score.usefulness

  defp repo_group(bench_case) do
    source_repo =
      bench_case
      |> field(:source_metadata, %{})
      |> field(:repo, nil)

    repo =
      source_repo ||
        bench_case
        |> field(:repo, %{})
        |> field(:name, "unknown")

    repo
    |> to_string()
    |> String.replace(~r/-greptile$/, "")
    |> String.replace(~r/-graphite$/, "")
  end

  defp changed_file_support?(bench_case, path) do
    normalized = normalize_path(path)

    if normalized in ["", "unknown"] do
      false
    else
      changed_files =
        bench_case.diff
        |> to_string()
        |> changed_files_from_diff()

      normalized in changed_files or Enum.any?(changed_files, &String.ends_with?(normalized, &1))
    end
  end

  defp changed_files_from_diff(diff) do
    ~r/^diff --git a\/(.+?) b\/(.+)$/m
    |> Regex.scan(diff)
    |> Enum.map(fn [_line, _old, new] -> new end)
    |> Enum.uniq()
  end

  defp risk_category?(categories) do
    Enum.any?(categories, fn category ->
      category in [
        "security",
        "auth",
        "authorization",
        "runtime",
        "contract",
        "schema",
        "migration",
        "concurrency",
        "cache",
        "correctness"
      ]
    end)
  end

  defp evidence_score(tier), do: (6 - min(max(int(tier), 1), 5)) / 5
  defp normalize(value, max_value), do: clamp(value / max_value)
  defp clamp(value), do: value |> max(0.0) |> min(1.0)

  defp severity_weight(severity) do
    %{"critical" => 4, "high" => 3, "medium" => 2, "low" => 1}
    |> Map.get(severity |> to_string() |> String.downcase(), 1)
  end

  defp agreement_count(claim), do: field(field(claim, :source, %{}), :agreement_count, 1) || 1

  defp base_rank(claim), do: team_ev_score(claim)

  defp explicit_key(claim) do
    claim
    |> field(:dedupe_key, "")
    |> to_string()
    |> String.trim()
  end

  defp merge_key(claim), do: explicit_key(claim) <> ":" <> normalize_path(field(claim, :path))

  defp token_jaccard(left, right) do
    left_tokens = tokens(left)
    right_tokens = tokens(right)
    union = MapSet.union(left_tokens, right_tokens) |> MapSet.size()

    if union == 0 do
      0.0
    else
      MapSet.intersection(left_tokens, right_tokens) |> MapSet.size() |> Kernel./(union)
    end
  end

  defp claim_text(claim) do
    [
      field(claim, :claim),
      field(claim, :failure_path, []) |> List.wrap() |> Enum.join(" "),
      field(claim, :evidence, [])
      |> List.wrap()
      |> Enum.map(&field(&1, :summary))
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
    |> Enum.reject(&(String.length(&1) < 4))
    |> MapSet.new()
  end

  defp uniq_by_summary(evidence) do
    evidence
    |> Enum.map(&atomize/1)
    |> Enum.uniq_by(&field(&1, :summary, ""))
  end

  defp normalize_path(path), do: path |> to_string() |> String.trim()

  defp short_hash(value),
    do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower) |> String.slice(0, 12)

  defp atomize(%{} = map) do
    Map.new(map, fn {key, value} ->
      key =
        cond do
          is_atom(key) -> key
          is_binary(key) -> String.to_atom(key)
          true -> key
        end

      {key, atomize(value)}
    end)
  end

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value

  defp field(map, key, default \\ nil)

  defp field(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp field(_other, _key, default), do: default

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_float(value), do: trunc(value)
  defp int(value) when is_binary(value), do: String.to_integer(value)
  defp int(_value), do: 0

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)

  defp make_out_dir(id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(@root, "#{timestamp}-#{id}")
  end
end

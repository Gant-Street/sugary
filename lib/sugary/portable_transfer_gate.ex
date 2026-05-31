defmodule Sugary.PortableTransferGate do
  @moduledoc false

  alias Sugary.Protocol.ExperimentManifest

  @root ".sugary/research/transfer-gates"
  @portable_id "pcrs-v4-portable-codex-repo-low"
  @baseline_id "baseline-diff-only"
  @static_id "public-static-proof-gate"

  @trust_policy "posterior-max1-plus-source5-qualified-triad-budget52"
  @qualified_policy "qualified-f1-judge-risk-budget84-max3"

  @aacr_pool_hit_target 10
  @aacr_precision_floor 0.5
  @martian_trust_f1_floor 0.466
  @martian_trust_precision_floor 0.840
  @martian_qualified_f1_floor 0.552
  @martian_qualified_precision_floor 0.720

  def run!(opts \\ %{}) do
    opts = stringify(opts)
    id = Map.get(opts, "id", "pcrs-v4-portable-transfer-gate-v0")

    suites =
      opts |> Map.get("suites", Map.get(opts, "suite", "martian-offline,aacr-bench")) |> csv()

    limit = opts |> Map.get("limit", "50") |> int()
    offset = opts |> Map.get("offset", "0") |> int()
    replay_mode = Map.get(opts, "replay-mode", "cache-first")
    transfer_dir = transfer_dir(id)

    File.mkdir_p!(transfer_dir)

    suite_reports =
      Enum.map(suites, fn suite ->
        run_suite!(suite, opts, limit, offset, replay_mode, transfer_dir)
      end)

    martian_publisher =
      suite_reports
      |> Enum.find(&(&1.suite == "martian-offline"))
      |> maybe_run_martian_publisher(opts, limit, offset, transfer_dir)

    scorecard = %{
      id: id,
      variable: portable_variable(opts),
      limit: limit,
      offset: offset,
      replay_mode: replay_mode,
      official_score_claim: false,
      martian_api_used: false,
      aacr_specific_static_patterns: false,
      targets: targets(),
      suites: suite_reports,
      martian_publisher: martian_publisher,
      decision: decision(suite_reports, martian_publisher)
    }

    Sugary.Json.write!(Path.join(transfer_dir, "portable-transfer-scorecard.json"), scorecard)
    File.write!(Path.join(transfer_dir, "portable-transfer-report.md"), render_report(scorecard))

    transfer_dir
  end

  defp run_suite!(suite, opts, limit, offset, replay_mode, transfer_dir) do
    case Map.get(opts, "#{suite}-run") || Map.get(opts, run_opt_name(suite)) do
      nil ->
        run_suite_live!(suite, opts, limit, offset, replay_mode, transfer_dir)

      run_dir ->
        load_suite_run!(suite, run_dir, limit, offset, transfer_dir)
    end
  end

  defp run_suite_live!(suite, opts, limit, offset, replay_mode, transfer_dir) do
    manifest =
      ExperimentManifest.new(%{
        id: "#{Map.get(opts, "id", "pcrs-v4-portable-transfer-gate-v0")}-#{suite}",
        suite: suite,
        limit: limit,
        offset: offset,
        replay_mode: replay_mode,
        description:
          "PCRS v4 portable candidate-source transfer gate. Unofficial local scoring only.",
        methods: [
          %{id: @baseline_id, reviewer: @baseline_id},
          %{id: @static_id, reviewer: @static_id}
        ],
        reviewers: [portable_reviewer(opts)]
      })

    {run_dir, method_reports, cases} =
      Sugary.Runner.run_experiment_manifest_with_reports!(manifest)

    File.write!(Path.join(transfer_dir, "#{suite}-run-dir.txt"), run_dir <> "\n")

    suite_report(suite, run_dir, method_reports, cases)
  end

  defp load_suite_run!(suite, run_dir, limit, offset, transfer_dir) do
    cases = Sugary.PublicBenchmarks.load_cases!(suite, limit: limit, offset: offset)

    method_reports =
      [@baseline_id, @static_id, @portable_id]
      |> Enum.map(&method_report_from_run(run_dir, &1, cases))
      |> Enum.reject(&is_nil/1)

    File.write!(Path.join(transfer_dir, "#{suite}-run-dir.txt"), run_dir <> "\n")
    suite_report(suite, run_dir, method_reports, cases)
  end

  defp suite_report(suite, run_dir, method_reports, cases) do
    method_ids = [@baseline_id, @static_id, @portable_id]
    method_summaries = Map.new(method_ids, &{&1, summarize_method(method_reports, &1)})
    leakage = Sugary.PublicBenchmarks.leakage_report(run_dir, cases)

    %{
      suite: suite,
      run_dir: run_dir,
      cases: length(cases),
      expected_claims:
        Enum.sum(Enum.map(cases, &(Sugary.ClaimMatcher.expected_ids(&1) |> MapSet.size()))),
      methods: method_summaries,
      static_proof_ablation: static_proof_ablation(method_summaries),
      leakage: leakage,
      workspace: workspace_summary(method_reports),
      replay: replay_summary(method_reports),
      decision: suite_decision(suite, method_summaries, leakage)
    }
  end

  defp method_report_from_run(run_dir, method_id, cases) do
    results =
      Enum.map(cases, fn bench_case ->
        reviewer_result =
          read_case_json(run_dir, method_id, "reviewer-results", bench_case.id) ||
            %{"claims" => [], "cost" => 0.0, "latency_ms" => 0, "artifacts" => [], "errors" => []}

        final_claims = read_case_json(run_dir, method_id, "claims", bench_case.id) || []
        input = read_case_json(run_dir, method_id, "input-bundles", bench_case.id) || %{}
        reviewer_result = atomize(reviewer_result)

        %{
          case: bench_case,
          input: atomize(input),
          reviewer_result: reviewer_result,
          candidate_claims: atomize(Map.get(reviewer_result, :claims, [])),
          final_claims: atomize(final_claims)
        }
      end)

    if Enum.any?(
         results,
         &(Map.get(&1.reviewer_result, :claims, []) != [] or &1.final_claims != [])
       ) do
      %{
        method: %{id: method_id},
        score: Sugary.Scorer.score(method_id, results),
        failures: Sugary.Scorer.failures(method_id, results),
        results: results
      }
    end
  end

  defp read_case_json(run_dir, method_id, kind, case_id) do
    aggregate = Path.join([run_dir, kind, "#{method_id}--#{case_id}.json"])
    method_local = Path.join([run_dir, method_id, kind, "#{case_id}.json"])

    cond do
      File.exists?(aggregate) -> Sugary.Json.read!(aggregate)
      File.exists?(method_local) -> Sugary.Json.read!(method_local)
      true -> nil
    end
  end

  defp portable_reviewer(opts) do
    %{
      id: Map.get(opts, "reviewer-id", @portable_id),
      type: "command",
      class: "research",
      context: "repo_optional_public_diff",
      candidate_generation: "portable_codex_repo_reviewer",
      evidence: Map.get(opts, "evidence", "none"),
      refutation: Map.get(opts, "refutation", "generic_refuter_stub"),
      ranking: Map.get(opts, "ranking", "expected_value_stub"),
      enabled: true,
      required_executable: Map.get(opts, "required-executable", "codex"),
      command: Map.get(opts, "command", "elixir"),
      args: Map.get(opts, "args", ["scripts/reviewers/codex_repo_reviewer.exs"]),
      timeout_ms: opts |> Map.get("timeout-ms", "180000") |> int(),
      stdout_limit: 262_144,
      stderr_limit: 262_144,
      cwd: ".",
      include_workspace: true,
      requires_network: true,
      requires_secrets: [],
      cost_model: "chatgpt_auth_or_user_provider",
      capabilities: ["llm", "codex_cli", "repo_optional", "benchmark_agnostic"],
      env: portable_env(opts),
      metadata: %{
        scorer_labels_blinded: true,
        aacr_specific_patterns: false,
        official_submission: false
      }
    }
  end

  defp portable_env(opts) do
    [
      "SUGARY_REVIEWER_ID=#{Map.get(opts, "reviewer-id", @portable_id)}",
      "SUGARY_CODEX_MODEL=#{Map.get(opts, "model", "gpt-5.5")}",
      "SUGARY_CODEX_REASONING_EFFORT=#{Map.get(opts, "reasoning-effort", "low")}",
      "SUGARY_CODEX_MAX_CLAIMS=#{Map.get(opts, "max-claims", "3")}",
      "SUGARY_CODEX_INNER_TIMEOUT_MS=#{Map.get(opts, "inner-timeout-ms", "120000")}",
      "SUGARY_CODEX_REVIEW_FOCUS=#{portable_focus()}"
    ]
  end

  defp portable_focus do
    "Benchmark-agnostic code review. Look for concrete bugs, security issues, contract violations, runtime failures, and meaningful missing tests. Avoid style-only comments, benchmark names, and fixture-shaped reasoning."
  end

  defp summarize_method(method_reports, method_id) do
    case Enum.find(method_reports, &(&1.method.id == method_id)) do
      nil ->
        %{status: "missing", method_id: method_id}

      report ->
        %{
          status: "available",
          method_id: method_id,
          published: score_map(report.score),
          candidate_pool: candidate_pool_metrics(report.results),
          reviewer_errors: reviewer_error_count(report.results),
          adapter_modes: adapter_modes(report.results)
        }
    end
  end

  defp candidate_pool_metrics(results) do
    per_case = Enum.map(results, &candidate_case_metrics/1)
    expected = Enum.sum(Enum.map(per_case, & &1.expected_claims))
    hits = Enum.sum(Enum.map(per_case, & &1.hits))
    claims = Enum.sum(Enum.map(per_case, & &1.claims))
    noise = Enum.sum(Enum.map(per_case, & &1.noise))

    %{
      expected_claims: expected,
      claims: claims,
      hits: hits,
      noise: noise,
      precision: ratio(hits, claims),
      recall: ratio(hits, expected),
      per_case: per_case
    }
  end

  defp candidate_case_metrics(result) do
    claims = result.candidate_claims || []

    matched_ids =
      claims
      |> Enum.flat_map(fn claim ->
        case Sugary.ClaimMatcher.expected_claim(result.case, claim) do
          nil -> []
          expected -> [Map.get(expected, :id) || Map.get(expected, "id")]
        end
      end)

    hit_count = matched_ids |> MapSet.new() |> MapSet.size()
    duplicate_noise = length(matched_ids) - hit_count

    unsupported_noise =
      Enum.count(claims, fn claim ->
        is_nil(Sugary.ClaimMatcher.expected_claim(result.case, claim)) or
          not is_nil(Sugary.ClaimMatcher.known_non_issue(result.case, claim))
      end)

    %{
      case_id: result.case.id,
      expected_claims: Sugary.ClaimMatcher.expected_ids(result.case) |> MapSet.size(),
      claims: length(claims),
      hits: hit_count,
      noise: duplicate_noise + unsupported_noise
    }
  end

  defp static_proof_ablation(methods) do
    baseline = methods[@baseline_id]
    static = methods[@static_id]
    portable = methods[@portable_id]

    %{
      baseline: score_or_empty(baseline),
      static_proof_gate: score_or_empty(static),
      portable_candidate_source: score_or_empty(portable),
      static_delta_f1: metric(static, [:published, :f1]) - metric(baseline, [:published, :f1]),
      portable_delta_f1: metric(portable, [:published, :f1]) - metric(baseline, [:published, :f1])
    }
  end

  defp maybe_run_martian_publisher(nil, _opts, _limit, _offset, _transfer_dir),
    do: %{status: "skipped", reason: "martian suite was not run"}

  defp maybe_run_martian_publisher(%{run_dir: run_dir}, opts, limit, offset, transfer_dir) do
    if truthy?(Map.get(opts, "publisher", "true")) do
      publisher_id =
        "#{Map.get(opts, "id", "pcrs-v4-portable-transfer-gate-v0")}-martian-publisher"

      try do
        out_dir =
          Sugary.PCRSEnsemblePublisher.run!(
            suite: "martian-offline",
            limit: limit,
            offset: offset,
            id: publisher_id,
            extra_sources: [
              %{
                run: run_dir,
                method: @portable_id,
                source: "v4-portable-codex-repo-low",
                pool: :tail,
                family: "portable_codex_repo",
                source_prior: 0.48
              }
            ]
          )

        File.write!(Path.join(transfer_dir, "martian-publisher-dir.txt"), out_dir <> "\n")
        publisher_summary(out_dir)
      rescue
        error ->
          %{
            status: "skipped",
            reason: "publisher run failed: #{Exception.message(error)}"
          }
      end
    else
      %{status: "skipped", reason: "publisher disabled"}
    end
  end

  defp publisher_summary(out_dir) do
    policies = read_json(Path.join(out_dir, "policy-scorecards.json")) || []
    pool = read_json(Path.join(out_dir, "candidate-pool.json")) || %{}
    decision = read_json(Path.join(out_dir, "decision.json")) || %{}
    trust = policy_score(policies, @trust_policy)
    qualified = policy_score(policies, @qualified_policy)

    %{
      status: "available",
      run_dir: out_dir,
      candidate_pool: pool,
      decision: decision,
      trust_default: trust,
      qualified: qualified,
      guardrail: %{
        trust_default_passed:
          metric(trust, ["score", "f1"]) >= @martian_trust_f1_floor and
            metric(trust, ["score", "precision"]) >= @martian_trust_precision_floor,
        qualified_passed:
          metric(qualified, ["score", "f1"]) >= @martian_qualified_f1_floor and
            metric(qualified, ["score", "precision"]) >= @martian_qualified_precision_floor
      }
    }
  end

  defp policy_score(policies, id) do
    Enum.find(policies, %{"status" => "missing", "id" => id}, &(&1["id"] == id))
  end

  defp suite_decision("aacr-bench", methods, leakage) do
    portable = methods[@portable_id]
    pool_hits = metric(portable, [:candidate_pool, :hits])
    precision = metric(portable, [:published, :precision])
    leaked? = leakage[:fatal?] || leakage["fatal?"] || false

    cond do
      leaked? -> "invalid_due_to_leakage"
      pool_hits < @aacr_pool_hit_target -> "reject_candidate_pool_recall"
      precision < @aacr_precision_floor -> "reject_published_precision"
      true -> "pass_local_transfer_gate"
    end
  end

  defp suite_decision(_suite, _methods, leakage) do
    if leakage[:fatal?] || leakage["fatal?"] || false do
      "invalid_due_to_leakage"
    else
      "measured"
    end
  end

  defp decision(suite_reports, martian_publisher) do
    aacr = Enum.find(suite_reports, &(&1.suite == "aacr-bench"))

    leakage_failed? =
      Enum.any?(
        suite_reports,
        &(get_in(&1, [:leakage, :fatal?]) || get_in(&1, [:leakage, "fatal?"]) || false)
      )

    aacr_passed? = is_nil(aacr) or aacr.decision == "pass_local_transfer_gate"

    martian_passed? =
      case martian_publisher do
        %{status: "available", guardrail: guardrail} ->
          guardrail.trust_default_passed and guardrail.qualified_passed

        _other ->
          false
      end

    cond do
      leakage_failed? -> "invalid_due_to_leakage"
      not aacr_passed? -> "reject_aacr_transfer"
      not martian_passed? -> "needs_more_data_or_martian_regression"
      true -> "pass_portable_transfer_gate"
    end
  end

  defp workspace_summary(method_reports) do
    results =
      method_reports
      |> Enum.find(&(&1.method.id == @portable_id))
      |> case do
        nil -> Enum.flat_map(method_reports, & &1.results)
        report -> report.results
      end

    %{
      cases_seen: length(results),
      workspace_inputs:
        Enum.count(results, fn result ->
          metadata = Map.get(result.input || %{}, :metadata, %{})
          workspace = Map.get(metadata, :workspace) || Map.get(metadata, "workspace")
          is_map(workspace)
        end)
    }
  end

  defp replay_summary(method_reports) do
    method_reports
    |> Enum.flat_map(& &1.results)
    |> Enum.flat_map(fn result ->
      result.reviewer_result
      |> Map.get(:artifacts, [])
      |> List.wrap()
      |> Enum.map(&(Map.get(&1, :execution_mode) || Map.get(&1, "execution_mode") || "unknown"))
    end)
    |> Enum.frequencies()
  end

  defp reviewer_error_count(results) do
    Enum.count(results, fn result ->
      errors = Map.get(result.reviewer_result, :errors, [])
      is_list(errors) and errors != []
    end)
  end

  defp adapter_modes(results) do
    results
    |> Enum.flat_map(fn result ->
      result.reviewer_result
      |> Map.get(:artifacts, [])
      |> List.wrap()
      |> Enum.map(&(Map.get(&1, :execution_mode) || Map.get(&1, "execution_mode") || "unknown"))
    end)
    |> Enum.frequencies()
  end

  defp score_or_empty(%{published: score}), do: score
  defp score_or_empty(_other), do: %{}

  defp score_map(score) do
    score
    |> Map.from_struct()
    |> Map.drop([:__struct__])
  rescue
    _error -> score || %{}
  end

  defp render_report(scorecard) do
    suite_sections =
      scorecard.suites
      |> Enum.map(&render_suite_section/1)
      |> Enum.join("\n\n")

    publisher = render_publisher(scorecard.martian_publisher)

    """
    # PCRS v4 Portable Transfer Gate

    This is an unofficial local transfer gate. It does not use a Martian API, does not submit benchmark results, and does not claim official benchmark rank.

    ## Variable

    - Candidate source: `#{scorecard.variable.id}`
    - Command: `#{scorecard.variable.command} #{Enum.join(scorecard.variable.args, " ")}`
    - Model: `#{scorecard.variable.model}`
    - Reasoning effort: `#{scorecard.variable.reasoning_effort}`
    - Max claims per PR: #{scorecard.variable.max_claims}
    - No oracle input: true
    - AACR-specific static patterns: false

    ## Targets

    - AACR first-50 candidate-pool hits >= #{@aacr_pool_hit_target}
    - AACR published precision >= #{fmt(@aacr_precision_floor)}
    - Martian trust/default: F1 >= #{fmt(@martian_trust_f1_floor)}, precision >= #{fmt(@martian_trust_precision_floor)}
    - Martian qualified: F1 >= #{fmt(@martian_qualified_f1_floor)}, precision >= #{fmt(@martian_qualified_precision_floor)}

    #{suite_sections}

    #{publisher}

    ## Decision

    `#{scorecard.decision}`
    """
  end

  defp render_suite_section(suite) do
    baseline = suite.methods[@baseline_id]
    static = suite.methods[@static_id]
    portable = suite.methods[@portable_id]

    """
    ## #{suite.suite}

    - Run: `#{suite.run_dir}`
    - Cases: #{suite.cases}
    - Expected claims: #{suite.expected_claims}
    - Workspace inputs: #{suite.workspace.workspace_inputs} / #{suite.workspace.cases_seen}
    - Leakage fatal: #{suite.leakage[:fatal?] || suite.leakage["fatal?"] || false}
    - Decision: `#{suite.decision}`

    | Method | Pool Hits | Pool Recall | Pool Claims | Published Hits | Noise | Precision | F1 | Comments |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    | Baseline | #{pool_metric(baseline, :hits)} | #{pool_fmt(baseline, :recall)} | #{pool_metric(baseline, :claims)} | #{pub_metric(baseline, :hits)} | #{pub_metric(baseline, :noise)} | #{pub_fmt(baseline, :precision)} | #{pub_fmt(baseline, :f1)} | #{pub_metric(baseline, :published_claims)} |
    | Static proof ablation | #{pool_metric(static, :hits)} | #{pool_fmt(static, :recall)} | #{pool_metric(static, :claims)} | #{pub_metric(static, :hits)} | #{pub_metric(static, :noise)} | #{pub_fmt(static, :precision)} | #{pub_fmt(static, :f1)} | #{pub_metric(static, :published_claims)} |
    | Portable candidate source | #{pool_metric(portable, :hits)} | #{pool_fmt(portable, :recall)} | #{pool_metric(portable, :claims)} | #{pub_metric(portable, :hits)} | #{pub_metric(portable, :noise)} | #{pub_fmt(portable, :precision)} | #{pub_fmt(portable, :f1)} | #{pub_metric(portable, :published_claims)} |
    """
  end

  defp render_publisher(%{status: "available"} = publisher) do
    trust = publisher.trust_default["score"] || publisher.trust_default[:score] || %{}
    qualified = publisher.qualified["score"] || publisher.qualified[:score] || %{}

    """
    ## Martian Publisher Guardrail

    - Publisher run: `#{publisher.run_dir}`
    - Trust/default passed: #{publisher.guardrail.trust_default_passed}
    - Qualified passed: #{publisher.guardrail.qualified_passed}

    | Policy | Recall | Precision | F1 | Hits | Noise | Comments |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: |
    | Trust/default | #{fmt(metric(trust, "recall"))} | #{fmt(metric(trust, "precision"))} | #{fmt(metric(trust, "f1"))} | #{fmt(metric(trust, "hits"))} | #{fmt(metric(trust, "noise"))} | #{fmt(metric(trust, "published_claims"))} |
    | Qualified | #{fmt(metric(qualified, "recall"))} | #{fmt(metric(qualified, "precision"))} | #{fmt(metric(qualified, "f1"))} | #{fmt(metric(qualified, "hits"))} | #{fmt(metric(qualified, "noise"))} | #{fmt(metric(qualified, "published_claims"))} |
    """
  end

  defp render_publisher(publisher) do
    """
    ## Martian Publisher Guardrail

    Skipped: #{publisher.reason}
    """
  end

  defp pub_metric(method, key), do: method |> metric([:published, key]) |> fmt()
  defp pub_fmt(method, key), do: method |> metric([:published, key]) |> fmt()
  defp pool_metric(method, key), do: method |> metric([:candidate_pool, key]) |> fmt()
  defp pool_fmt(method, key), do: method |> metric([:candidate_pool, key]) |> fmt()

  defp metric(nil, _path), do: 0.0
  defp metric(value, key) when is_atom(key) or is_binary(key), do: field(value, key, 0.0)

  defp metric(value, path) when is_list(path) do
    Enum.reduce(path, value, fn key, acc ->
      case acc do
        nil -> nil
        map -> field(map, key, nil)
      end
    end) || 0.0
  end

  defp field(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp field(_other, _key, default), do: default

  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den

  defp portable_variable(opts) do
    %{
      id: Map.get(opts, "reviewer-id", @portable_id),
      command: Map.get(opts, "command", "elixir"),
      args: Map.get(opts, "args", ["scripts/reviewers/codex_repo_reviewer.exs"]),
      model: Map.get(opts, "model", "gpt-5.5"),
      reasoning_effort: Map.get(opts, "reasoning-effort", "low"),
      max_claims: opts |> Map.get("max-claims", "3") |> int()
    }
  end

  defp targets do
    %{
      aacr_candidate_pool_hits: @aacr_pool_hit_target,
      aacr_published_precision: @aacr_precision_floor,
      martian_trust_f1: @martian_trust_f1_floor,
      martian_trust_precision: @martian_trust_precision_floor,
      martian_qualified_f1: @martian_qualified_f1_floor,
      martian_qualified_precision: @martian_qualified_precision_floor
    }
  end

  defp transfer_dir(id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(@root, "#{timestamp}-#{id}")
  end

  defp run_opt_name("martian-offline"), do: "martian-run"
  defp run_opt_name("aacr-bench"), do: "aacr-run"
  defp run_opt_name(suite), do: "#{suite}-run"

  defp csv(value) when is_list(value), do: value

  defp csv(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp read_json(path), do: if(File.exists?(path), do: Sugary.Json.read!(path), else: nil)

  defp stringify(opts) when is_map(opts),
    do: Map.new(opts, fn {key, value} -> {to_string(key), value} end)

  defp stringify(opts) when is_list(opts), do: opts |> Enum.into(%{}) |> stringify()

  defp atomize(%{} = map),
    do: Map.new(map, fn {key, value} -> {atom_key(key), atomize(value)} end)

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value

  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_float(value), do: trunc(value)

  defp int(value) do
    value
    |> to_string()
    |> Integer.parse()
    |> case do
      {number, _rest} -> number
      :error -> raise ArgumentError, "invalid integer #{inspect(value)}"
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false

  defp fmt(nil), do: "n/a"
  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)
end

defmodule Sugary.AACRV6Gate do
  @moduledoc false

  alias Sugary.Protocol.ExperimentManifest

  @root ".sugary/research/aacr-v6-gates"
  @defect_id "pcrs-v4-portable-codex-repo-low"
  @broad_id "pcrs-v6-broad-actionable-codex-low"
  @evidence_id "pcrs-v6-evidence-pack-codex-low"
  @martian_run ".sugary/research/runs/20260531T153346Z-pcrs-v4-portable-transfer-first50-martian-offline"
  @martian_f1_floor 0.561
  @martian_precision_floor 0.730

  def run!(opts \\ %{}) do
    opts = stringify(opts)
    id = Map.get(opts, "id", "pcrs-v6-aacr-claim-space-evidence-pack")
    limit = opts |> Map.get("limit", "50") |> int()
    offset = opts |> Map.get("offset", "0") |> int()
    replay_mode = Map.get(opts, "replay-mode", "cache-first")
    out_dir = make_out_dir(id)
    File.mkdir_p!(out_dir)

    sparse_dir =
      if truthy?(Map.get(opts, "ensure-sparse-context", "true")) do
        Sugary.SparseRepoContext.run!(%{
          "suite" => "aacr-bench",
          "limit" => limit,
          "offset" => offset,
          "id" => "#{id}-sparse-context"
        })
      else
        nil
      end

    manifest =
      ExperimentManifest.new(%{
        id: "#{id}-aacr-bench",
        suite: "aacr-bench",
        limit: limit,
        offset: offset,
        replay_mode: replay_mode,
        description:
          "PCRS v6 AACR claim-space and evidence-pack generator ablation. Unofficial local scoring only.",
        methods: [],
        reviewers: [
          reviewer(@defect_id, defect_focus(), 3, false),
          reviewer(@broad_id, broad_focus(), 8, false),
          reviewer(@evidence_id, evidence_focus(), 8, true)
        ]
      })

    {run_dir, method_reports, cases} =
      Sugary.Runner.run_experiment_manifest_with_reports!(manifest)

    File.write!(Path.join(out_dir, "aacr-run-dir.txt"), run_dir <> "\n")

    if sparse_dir,
      do: File.write!(Path.join(out_dir, "sparse-context-dir.txt"), sparse_dir <> "\n")

    martian_guardrail = martian_guardrail(opts, limit, offset)
    claim_space = claim_space_audit(cases)
    method_summaries = Enum.map(method_reports, &method_summary/1)

    scorecard = %{
      id: id,
      suite: "aacr-bench",
      limit: limit,
      offset: offset,
      replay_mode: replay_mode,
      official_score_claim: false,
      api_key_used: false,
      aacr_specific_static_patterns: false,
      sparse_context_dir: sparse_dir,
      run_dir: run_dir,
      claim_space: claim_space,
      methods: method_summaries,
      martian_guardrail: martian_guardrail,
      targets: targets(),
      decision: decision(method_summaries, martian_guardrail)
    }

    Sugary.Json.write!(Path.join(out_dir, "aacr-v6-scorecard.json"), scorecard)
    Sugary.Json.write!(Path.join(out_dir, "claim-space-audit.json"), claim_space)
    File.write!(Path.join(out_dir, "aacr-v6-report.md"), render_report(scorecard))

    out_dir
  end

  defp reviewer(id, focus, max_claims, evidence_pack?) do
    %{
      id: id,
      type: "command",
      class: "research",
      context: if(evidence_pack?, do: "sparse_workspace_evidence_pack", else: "sparse_workspace"),
      candidate_generation:
        if(evidence_pack?, do: "evidence_pack_review", else: "portable_codex_repo"),
      evidence: if(evidence_pack?, do: "evidence_pack", else: "none"),
      refutation: "generic_refuter_stub",
      ranking: "expected_value_stub",
      enabled: true,
      required_executable: "codex",
      command: "elixir",
      args: ["scripts/reviewers/codex_repo_reviewer.exs"],
      timeout_ms: 180_000,
      stdout_limit: 262_144,
      stderr_limit: 262_144,
      cwd: ".",
      include_workspace: true,
      include_evidence_pack: evidence_pack?,
      requires_network: true,
      requires_secrets: [],
      cost_model: "chatgpt_auth_or_user_provider",
      capabilities: ["llm", "codex_cli", "aacr_transfer", "benchmark_agnostic"],
      env: [
        "SUGARY_REVIEWER_ID=#{id}",
        "SUGARY_CODEX_MODEL=gpt-5.5",
        "SUGARY_CODEX_REASONING_EFFORT=low",
        "SUGARY_CODEX_MAX_CLAIMS=#{max_claims}",
        "SUGARY_CODEX_INNER_TIMEOUT_MS=120000",
        "SUGARY_CODEX_REVIEW_FOCUS=#{focus}"
      ],
      metadata:
        %{
          scorer_labels_blinded: true,
          aacr_specific_patterns: false,
          official_submission: false
        }
        |> maybe_put_evidence_pack_metadata(evidence_pack?)
    }
    |> maybe_match_v4_portable_shape(id)
  end

  defp maybe_put_evidence_pack_metadata(metadata, true),
    do: Map.put(metadata, :evidence_pack, true)

  defp maybe_put_evidence_pack_metadata(metadata, false), do: metadata

  defp maybe_match_v4_portable_shape(reviewer, @defect_id) do
    reviewer
    |> Map.put(:context, "repo_optional_public_diff")
    |> Map.put(:candidate_generation, "portable_codex_repo_reviewer")
    |> Map.put(:capabilities, ["llm", "codex_cli", "repo_optional", "benchmark_agnostic"])
  end

  defp maybe_match_v4_portable_shape(reviewer, _id), do: reviewer

  defp method_summary(report) do
    candidate_accounting = aggregate_accounting(report.results, :candidate_claims)
    published_accounting = aggregate_accounting(report.results, :final_claims, true)

    %{
      method_id: report.method.id,
      score: score_map(report.score),
      candidate_pool: candidate_accounting,
      published_accounting: published_accounting,
      expected_claim_type_distribution: %{},
      generated_claim_type_distribution:
        generated_distribution(report.results, :candidate_claims),
      published_claim_type_distribution:
        generated_distribution(report.results, :final_claims, true),
      unmatched_generated_claims: unmatched_summary(report.results),
      missed_expected_claims: missed_summary(report.results),
      near_match_risk: near_match_summary(report.results),
      context_use: context_use(report.results),
      reviewer_errors: reviewer_error_count(report.results),
      adapter_modes: adapter_modes(report.results)
    }
  end

  defp aggregate_accounting(results, field, published_only? \\ false) do
    per_case =
      Enum.map(results, fn result ->
        claims =
          result
          |> Map.get(field, [])
          |> List.wrap()
          |> maybe_published_only(published_only?)

        accounting = Sugary.ScoreAccounting.claim_accounting(result.case, claims)

        %{
          case_id: result.case.id,
          expected_claims: Sugary.ClaimMatcher.expected_ids(result.case) |> MapSet.size(),
          claims: accounting.comments,
          precision_denominator: accounting.precision_denominator,
          hits: accounting.unique_hits,
          matched_comments: accounting.matched_comments,
          noisy_or_trap_comments: accounting.noisy_or_trap_comments,
          unsupported_comments: accounting.unsupported_comments,
          known_non_issue_comments: accounting.known_non_issue_comments,
          hit_and_trap_comments: accounting.hit_and_trap_comments,
          duplicate_hit_events: accounting.duplicate_hit_events,
          noise_events: accounting.noise_events
        }
      end)

    totals =
      Enum.reduce(
        per_case,
        %{
          cases: 0,
          expected_claims: 0,
          claims: 0,
          precision_denominator: 0,
          hits: 0,
          matched_comments: 0,
          noisy_or_trap_comments: 0,
          unsupported_comments: 0,
          known_non_issue_comments: 0,
          hit_and_trap_comments: 0,
          duplicate_hit_events: 0,
          noise_events: 0
        },
        fn row, acc ->
          acc
          |> Map.update!(:cases, &(&1 + 1))
          |> Map.update!(:expected_claims, &(&1 + row.expected_claims))
          |> Map.update!(:claims, &(&1 + row.claims))
          |> Map.update!(:precision_denominator, &(&1 + row.precision_denominator))
          |> Map.update!(:hits, &(&1 + row.hits))
          |> Map.update!(:matched_comments, &(&1 + row.matched_comments))
          |> Map.update!(:noisy_or_trap_comments, &(&1 + row.noisy_or_trap_comments))
          |> Map.update!(:unsupported_comments, &(&1 + row.unsupported_comments))
          |> Map.update!(:known_non_issue_comments, &(&1 + row.known_non_issue_comments))
          |> Map.update!(:hit_and_trap_comments, &(&1 + row.hit_and_trap_comments))
          |> Map.update!(:duplicate_hit_events, &(&1 + row.duplicate_hit_events))
          |> Map.update!(:noise_events, &(&1 + row.noise_events))
        end
      )

    totals
    |> Map.put(:precision, ratio(totals.hits, totals.precision_denominator))
    |> Map.put(:recall, ratio(totals.hits, totals.expected_claims))
    |> Map.put(:per_case, per_case)
  end

  defp claim_space_audit(cases) do
    expected = Enum.flat_map(cases, &expected_claims/1)

    %{
      expected_claims: length(expected),
      cases: length(cases),
      avg_expected_claims_per_case: ratio(length(expected), max(length(cases), 1)),
      category: frequency(expected, &field(&1, :category, "unknown")),
      type: frequency(expected, &Sugary.EvidencePack.classify_claim_type/1),
      severity: frequency(expected, &field(&1, :severity, "unknown")),
      difficulty: frequency(expected, &field(&1, :difficulty, "unknown")),
      required_context:
        frequency_many(expected, &(field(&1, :required_context, []) |> List.wrap()))
    }
  end

  defp generated_distribution(results, field, published_only? \\ false) do
    claims =
      results
      |> Enum.flat_map(fn result ->
        result
        |> Map.get(field, [])
        |> List.wrap()
        |> maybe_published_only(published_only?)
      end)

    %{
      category: frequency(claims, &field(&1, :category, "unknown")),
      type: frequency(claims, &Sugary.EvidencePack.classify_claim_type/1),
      severity: frequency(claims, &field(&1, :severity, "unknown"))
    }
  end

  defp unmatched_summary(results) do
    rows =
      results
      |> Enum.flat_map(fn result ->
        result.final_claims
        |> Enum.filter(&(&1.publish_decision == "publish"))
        |> Enum.reject(&Sugary.ClaimMatcher.expected_claim(result.case, &1))
        |> Enum.map(fn claim ->
          %{
            case_id: result.case.id,
            path: field(claim, :path, "unknown"),
            category: field(claim, :category, "unknown"),
            reason:
              if(Sugary.ClaimMatcher.known_non_issue(result.case, claim),
                do: "known_non_issue_or_trap",
                else: "unsupported_by_reference"
              )
          }
        end)
      end)

    %{count: length(rows), by_reason: frequency(rows, & &1.reason), examples: Enum.take(rows, 12)}
  end

  defp missed_summary(results) do
    rows =
      results
      |> Enum.flat_map(fn result ->
        published_hit_ids =
          result.final_claims
          |> Enum.filter(&(&1.publish_decision == "publish"))
          |> Enum.flat_map(fn claim ->
            case Sugary.ClaimMatcher.expected_claim(result.case, claim) do
              nil -> []
              expected -> [field(expected, :id)]
            end
          end)
          |> MapSet.new()

        result.case
        |> expected_claims()
        |> Enum.reject(&MapSet.member?(published_hit_ids, field(&1, :id)))
        |> Enum.map(fn expected ->
          %{
            case_id: result.case.id,
            expected_id: field(expected, :id),
            path: field(expected, :path, "unknown"),
            type: Sugary.EvidencePack.classify_claim_type(expected),
            category: field(expected, :category, "unknown"),
            required_context: field(expected, :required_context, [])
          }
        end)
      end)

    %{
      count: length(rows),
      by_type: frequency(rows, & &1.type),
      by_category: frequency(rows, & &1.category),
      examples: Enum.take(rows, 12)
    }
  end

  defp near_match_summary(results) do
    rows =
      results
      |> Enum.flat_map(fn result ->
        expected = expected_claims(result.case)

        result.final_claims
        |> Enum.filter(&(&1.publish_decision == "publish"))
        |> Enum.reject(&Sugary.ClaimMatcher.expected_claim(result.case, &1))
        |> Enum.flat_map(fn claim ->
          case best_near_match(claim, expected) do
            nil ->
              []

            near ->
              [
                %{
                  case_id: result.case.id,
                  claim_path: field(claim, :path, "unknown"),
                  expected_id: field(near.expected, :id),
                  expected_path: field(near.expected, :path, "unknown"),
                  overlap: near.overlap,
                  same_path: near.same_path
                }
              ]
          end
        end)
      end)

    %{
      count: length(rows),
      same_path_count: Enum.count(rows, & &1.same_path),
      examples: Enum.take(rows, 12)
    }
  end

  defp context_use(results) do
    cited =
      results
      |> Enum.flat_map(fn result ->
        result.final_claims
        |> Enum.filter(&(&1.publish_decision == "publish"))
        |> Enum.flat_map(fn claim ->
          claim
          |> field(:source, %{})
          |> field(:evidence_pack_sections_cited, [])
          |> List.wrap()
        end)
      end)
      |> Enum.map(&to_string/1)
      |> Enum.reject(&(&1 == ""))

    %{cited_sections: Enum.frequencies(cited), cited_claims: length(cited)}
  end

  defp martian_guardrail(opts, limit, offset) do
    martian_run = Map.get(opts, "martian-run", @martian_run)

    if File.dir?(martian_run) do
      out_dir =
        Sugary.PortableTransferGate.run!(%{
          "id" => "#{Map.get(opts, "id", "pcrs-v6")}-martian-guardrail",
          "suites" => "martian-offline",
          "limit" => limit,
          "offset" => offset,
          "replay-mode" => "cache-first",
          "martian-run" => martian_run
        })

      scorecard = Sugary.Json.read!(Path.join(out_dir, "portable-transfer-scorecard.json"))
      guardrail = get_in(scorecard, ["martian_publisher", "guardrail"]) || %{}
      qualified = get_in(scorecard, ["martian_publisher", "qualified", "score"]) || %{}

      %{
        status: "available",
        run_dir: out_dir,
        qualified_f1: metric(qualified, "f1"),
        qualified_precision: metric(qualified, "precision"),
        qualified_passed:
          metric(qualified, "f1") >= @martian_f1_floor and
            metric(qualified, "precision") >= @martian_precision_floor,
        source_guardrail: guardrail
      }
    else
      %{status: "skipped", reason: "cached Martian run not found: #{martian_run}"}
    end
  rescue
    error -> %{status: "skipped", reason: Exception.message(error)}
  end

  defp decision(methods, martian_guardrail) do
    best = Enum.max_by(methods, &metric(&1.score, :f1), fn -> nil end)

    cond do
      is_nil(best) ->
        "invalid_no_methods"

      not martian_passed?(martian_guardrail) ->
        "needs_more_data_or_martian_regression"

      metric(best.candidate_pool, :hits) >= 20 and metric(best.score, :hits) >= 15 and
        metric(best.score, :precision) >= 0.25 and metric(best.score, :f1) > 0.031 ->
        "pass_aacr_v6_minimum_gate"

      metric(best.candidate_pool, :hits) >= 20 and metric(best.score, :f1) > 0.031 ->
        "partial_candidate_generation_lift"

      true ->
        "reject_aacr_claim_generation_transfer"
    end
  end

  defp render_report(scorecard) do
    methods =
      scorecard.methods
      |> Enum.map(&method_row/1)
      |> Enum.join("\n")

    candidate_rows =
      scorecard.methods
      |> Enum.map(&candidate_row/1)
      |> Enum.join("\n")

    distribution_rows =
      scorecard.methods
      |> Enum.map(&distribution_row/1)
      |> Enum.join("\n")

    failure_rows =
      scorecard.methods
      |> Enum.map(&failure_row/1)
      |> Enum.join("\n")

    near_match_rows =
      scorecard.methods
      |> Enum.map(&near_match_row/1)
      |> Enum.join("\n")

    context_rows =
      scorecard.methods
      |> Enum.map(&context_row/1)
      |> Enum.join("\n")

    """
    # PCRS v6 AACR Claim-Space + Evidence-Pack Gate

    This is an unofficial local transfer run. It does not use an API key, does not submit benchmark results, and does not claim official benchmark rank.

    ## Decision

    `#{scorecard.decision}`

    ## Claim Space

    - Cases: #{scorecard.claim_space.cases}
    - Expected claims: #{scorecard.claim_space.expected_claims}
    - Avg expected claims per PR: #{fmt(scorecard.claim_space.avg_expected_claims_per_case)}

    Expected claim types:

    #{frequency_lines(scorecard.claim_space.type)}

    Expected claim categories:

    #{frequency_lines(scorecard.claim_space.category)}

    ## Published Metrics

    | Method | Hits | Precision | Recall | F1 | Comments | Noise Events | Noisy/Trap Comments |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    #{methods}

    ## Candidate Pool Metrics

    | Method | Pool Hits | Pool Precision | Pool Recall | Pool Claims | Pool Noise Events | Hit+Trap Overlap |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: |
    #{candidate_rows}

    Accounting note: precision uses comments or candidate claims as the denominator. `Noise Events` includes noisy/trap comments plus duplicate-hit events, so unique hits plus noise events is not intended to equal comments.

    ## Generated Claim Distributions

    | Method | Candidate Types | Published Types | Candidate Categories | Published Categories |
    | --- | --- | --- | --- | --- |
    #{distribution_rows}

    ## Unmatched And Missed Summary

    | Method | Unmatched Generated | Unmatched Reasons | Missed Expected | Missed Types |
    | --- | ---: | --- | ---: | --- |
    #{failure_rows}

    ## Near-Match / Matcher-Risk Report

    | Method | Near-Match Count | Same-Path Count | Example Expected IDs |
    | --- | ---: | ---: | --- |
    #{near_match_rows}

    ## Context-Use Report

    | Method | Evidence-Pack Citations | Top Evidence Sections | Adapter Modes | Reviewer Errors |
    | --- | ---: | --- | --- | ---: |
    #{context_rows}

    ## Martian Guardrail

    - Status: #{scorecard.martian_guardrail.status}
    - Qualified F1: #{fmt(metric(scorecard.martian_guardrail, :qualified_f1))}
    - Qualified precision: #{fmt(metric(scorecard.martian_guardrail, :qualified_precision))}
    - Qualified passed: #{martian_passed?(scorecard.martian_guardrail)}

    ## Failure Diagnosis

    #{diagnosis(scorecard)}
    """
  end

  defp method_row(method) do
    score = method.score

    "| `#{method.method_id}` | #{metric(score, :hits)} | #{fmt(metric(score, :precision))} | #{fmt(metric(score, :recall))} | #{fmt(metric(score, :f1))} | #{metric(score, :published_claims)} | #{metric(score, :noise)} | #{metric(score, :noisy_or_trap_comments)} |"
  end

  defp candidate_row(method) do
    pool = method.candidate_pool

    "| `#{method.method_id}` | #{metric(pool, :hits)} | #{fmt(metric(pool, :precision))} | #{fmt(metric(pool, :recall))} | #{metric(pool, :claims)} | #{metric(pool, :noise_events)} | #{metric(pool, :hit_and_trap_comments)} |"
  end

  defp distribution_row(method) do
    candidate = method.generated_claim_type_distribution
    published = method.published_claim_type_distribution

    "| `#{method.method_id}` | #{format_frequency(candidate.type)} | #{format_frequency(published.type)} | #{format_frequency(candidate.category)} | #{format_frequency(published.category)} |"
  end

  defp failure_row(method) do
    unmatched = method.unmatched_generated_claims
    missed = method.missed_expected_claims

    "| `#{method.method_id}` | #{unmatched.count} | #{format_frequency(unmatched.by_reason)} | #{missed.count} | #{format_frequency(missed.by_type)} |"
  end

  defp near_match_row(method) do
    near = method.near_match_risk

    examples =
      near.examples
      |> List.wrap()
      |> Enum.map(&field(&1, :expected_id, "unknown"))
      |> Enum.uniq()
      |> Enum.take(5)
      |> Enum.join(", ")

    "| `#{method.method_id}` | #{near.count} | #{near.same_path_count} | #{blank(examples)} |"
  end

  defp context_row(method) do
    context = method.context_use

    "| `#{method.method_id}` | #{context.cited_claims} | #{format_frequency(context.cited_sections, 3)} | #{format_frequency(method.adapter_modes)} | #{method.reviewer_errors} |"
  end

  defp diagnosis(scorecard) do
    best = Enum.max_by(scorecard.methods, &metric(&1.score, :f1), fn -> nil end)

    if best do
      """
      - Best method by F1: `#{best.method_id}`.
      - Best AACR candidate-pool hits: #{metric(best.candidate_pool, :hits)}.
      - Best AACR published hits: #{metric(best.score, :hits)}.
      - Best AACR precision: #{fmt(metric(best.score, :precision))}.
      - Best AACR F1: #{fmt(metric(best.score, :f1))}.
      - Unmatched generated claims: #{best.unmatched_generated_claims.count}.
      - Missed expected claims: #{best.missed_expected_claims.count}.
      - Near-match risks: #{best.near_match_risk.count}.
      - Evidence-pack citations: #{best.context_use.cited_claims}.
      """
    else
      "No method reports were available."
    end
  end

  defp best_near_match(claim, expected_claims) do
    expected_claims
    |> Enum.map(fn expected ->
      same_path = normalize_path(field(claim, :path)) == normalize_path(field(expected, :path))
      overlap = token_overlap(claim, expected)
      %{expected: expected, same_path: same_path, overlap: overlap}
    end)
    |> Enum.filter(&(&1.same_path or &1.overlap >= 0.25))
    |> Enum.max_by(&{&1.same_path, &1.overlap}, fn -> nil end)
  end

  defp token_overlap(claim, expected) do
    claim_tokens = tokens([field(claim, :claim), field(claim, :category)] |> Enum.join(" "))

    expected_tokens =
      tokens([field(expected, :description), field(expected, :category)] |> Enum.join(" "))

    if MapSet.size(expected_tokens) == 0 do
      0.0
    else
      MapSet.intersection(claim_tokens, expected_tokens)
      |> MapSet.size()
      |> Kernel./(MapSet.size(expected_tokens))
    end
  end

  defp tokens(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_]+/, " ")
    |> String.split()
    |> Enum.flat_map(&String.split(&1, "_"))
    |> Enum.reject(&(String.length(&1) < 3))
    |> MapSet.new()
  end

  defp expected_claims(case_), do: field(case_.oracle, :expectedClaims, []) |> List.wrap()

  defp maybe_published_only(claims, false), do: claims

  defp maybe_published_only(claims, true),
    do: Enum.filter(claims, &(field(&1, :publish_decision) == "publish"))

  defp score_map(score), do: Map.from_struct(score)

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

  defp frequency(values, fun) do
    values
    |> Enum.map(&(fun.(&1) |> to_string()))
    |> Enum.frequencies()
    |> sort_frequency()
  end

  defp frequency_many(values, fun) do
    values
    |> Enum.flat_map(fn value ->
      value
      |> fun.()
      |> List.wrap()
      |> Enum.map(&to_string/1)
    end)
    |> Enum.frequencies()
    |> sort_frequency()
  end

  defp sort_frequency(map) do
    map
    |> Enum.sort_by(fn {key, value} -> {-value, key} end)
    |> Map.new()
  end

  defp frequency_lines(map) do
    map
    |> Enum.map(fn {key, value} -> "- `#{key}`: #{value}" end)
    |> Enum.join("\n")
  end

  defp format_frequency(map, limit \\ 5)
  defp format_frequency(nil, _limit), do: "none"

  defp format_frequency(map, _limit) when map == %{}, do: "none"

  defp format_frequency(map, limit) when is_map(map) do
    map
    |> Enum.sort_by(fn {key, value} -> {-value, to_string(key)} end)
    |> Enum.take(limit)
    |> Enum.map(fn {key, value} -> "`#{key}` #{value}" end)
    |> Enum.join(", ")
    |> blank()
  end

  defp blank(""), do: "none"
  defp blank(value), do: value

  defp martian_passed?(%{status: "available"} = guardrail),
    do:
      guardrail.qualified_f1 >= @martian_f1_floor and
        guardrail.qualified_precision >= @martian_precision_floor

  defp martian_passed?(_guardrail), do: false

  defp targets do
    %{
      aacr_pool_hits: 20,
      aacr_published_hits: 15,
      aacr_precision_minimum: 0.25,
      aacr_precision_stretch: 0.30,
      aacr_f1_floor: 0.031,
      martian_qualified_f1: @martian_f1_floor,
      martian_qualified_precision: @martian_precision_floor
    }
  end

  defp defect_focus do
    "Benchmark-agnostic code review. Look for concrete bugs, security issues, contract violations, runtime failures, and meaningful missing tests. Avoid style-only comments, benchmark names, and fixture-shaped reasoning."
  end

  defp broad_focus do
    "Benchmark-agnostic broad actionable code review. Look for correctness bugs, security issues, API/contract mismatches, missing or weak tests, performance issues, maintainability problems that can cause future defects, config/schema/i18n consistency issues, and clear edge cases. Avoid style-only nits unless they are concrete maintainability defects."
  end

  defp evidence_focus do
    "Benchmark-agnostic evidence-pack review. Use metadata.evidence_pack as the primary source. Generate actionable claims only when changed hunks, base/head snippets, related tests/config, or symbol evidence support the issue. Cover correctness, security, contracts, tests, performance, maintainability, config/schema/i18n consistency, and edge cases. Cite evidence_pack section ids."
  end

  defp make_out_dir(id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(@root, "#{timestamp}-#{id}")
  end

  defp normalize_path(path), do: path |> to_string() |> String.trim()

  defp metric(value, key) when is_atom(key) or is_binary(key), do: field(value, key, 0)
  defp ratio(_num, 0), do: 0.0
  defp ratio(num, den), do: num / den
  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(%_module{} = struct, key, default),
    do: struct |> Map.from_struct() |> field(key, default)

  defp field(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp field(_other, _key, default), do: default

  defp stringify(opts) when is_map(opts),
    do: Map.new(opts, fn {key, value} -> {to_string(key), value} end)

  defp stringify(opts) when is_list(opts), do: opts |> Enum.into(%{}) |> stringify()
  defp int(value) when is_integer(value), do: value
  defp int(value), do: value |> to_string() |> Integer.parse() |> elem(0)
  defp truthy?(value) when value in [true, "true", "1", 1], do: true
  defp truthy?(_value), do: false
end

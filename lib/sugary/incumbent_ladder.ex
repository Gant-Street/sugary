defmodule Sugary.IncumbentLadder do
  alias Sugary.Json

  @trust_policy "posterior-max1-plus-source5-qualified-triad-budget52"
  @qualified_policy "qualified-f1-judge-risk-budget84-max3"
  @diagnostic_policy "raw-recall-diagnostic-budget160-deduped-max6"

  def report!(opts) when is_map(opts) do
    opts
    |> Enum.map(fn {key, value} ->
      key = key |> to_string() |> String.replace("-", "_") |> String.to_atom()
      {key, value}
    end)
    |> report!()
  end

  def report!(opts) when is_list(opts) do
    source_run = Keyword.fetch!(opts, :source_run)
    target_f1 = opts |> Keyword.get(:target_f1, 0.70) |> parse_float()
    id = Keyword.get(opts, :id, "incumbent-ladder-v0")
    suite = Keyword.get(opts, :suite, "martian-offline")
    output_root = Keyword.get(opts, :output_root, ".sugary/research/incumbents")

    policies = Json.read!(Path.join(source_run, "policy-scorecards.json"))
    candidate_pool = Json.read!(Path.join(source_run, "candidate-pool.json"))
    source_decision = Json.read!(Path.join(source_run, "decision.json"))

    policy_by_id = Map.new(policies, &{&1["id"], &1})
    trust = fetch_policy!(policy_by_id, source_decision["trust_default"] || @trust_policy)
    qualified = fetch_policy!(policy_by_id, source_decision["qualified_f1"] || @qualified_policy)

    diagnostic =
      fetch_policy!(policy_by_id, source_decision["raw_f1_diagnostic"] || @diagnostic_policy)

    online = best_online_policy!(policies)

    report =
      build_report(
        source_run,
        suite,
        target_f1,
        trust,
        online,
        qualified,
        diagnostic,
        candidate_pool
      )

    out_dir = make_out_dir(output_root, id)
    File.mkdir_p!(out_dir)
    Json.write!(Path.join(out_dir, "incumbent-ladder.json"), report)
    File.write!(Path.join(out_dir, "incumbent-ladder.md"), render_markdown(report))
    out_dir
  end

  defp build_report(source_run, suite, target_f1, trust, online, qualified, diagnostic, pool) do
    online_score = online["score"]
    qualified_score = qualified["score"]
    diagnostic_score = diagnostic["score"]
    expected = pool["expected_claims"] || 0
    pool_hits = pool["pool_hits"] || 0

    %{
      version: "incumbent-ladder-v0",
      generated_at: DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ"),
      source_run: Path.expand(source_run),
      scope: %{
        suite: suite,
        cases: qualified_score["cases"],
        official_score: false,
        warning: "Local benchmark proxy. Not an official leaderboard score."
      },
      target: %{
        f1: target_f1,
        corpus: "thousands of diverse real pull requests",
        product_outcome: "improve final-patch correctness without harmful repair regressions"
      },
      incumbents: %{
        trust_default: summarize(trust),
        online_product: summarize(online),
        offline_qualified_f1: summarize(qualified),
        recall_diagnostic: summarize(diagnostic)
      },
      candidate_pool: %{
        expected_claims: expected,
        pool_hits: pool_hits,
        missing_expected_claims: max(expected - pool_hits, 0),
        oracle_recall: pool["oracle_recall"],
        raw_claims: pool["raw_claims"],
        merged_candidates: pool["merged_candidates"]
      },
      gaps: %{
        online_product_f1_to_target: round4(target_f1 - online_score["f1"]),
        qualified_f1_to_target: round4(target_f1 - qualified_score["f1"]),
        diagnostic_f1_to_target: round4(target_f1 - diagnostic_score["f1"]),
        qualified_recall_to_pool_oracle:
          round4((pool["oracle_recall"] || 0.0) - qualified_score["recall"])
      },
      promotion_contract: %{
        primary: "candidate F1 must exceed the locked online product incumbent",
        precision_floor: online_score["precision"],
        snr_floor: online_score["snr"] * 0.90,
        max_avg_comments_per_pr: online_score["avg_comments_per_pr"],
        product_gate:
          "fresh holdout or transfer result plus non-regression in repair safety, latency, and cost",
        forbidden: [
          "oracle leakage",
          "tuning on holdout labels",
          "promoting diagnostic operating points",
          "reporting unofficial scores as leaderboard results"
        ]
      },
      diagnosis: diagnose(qualified_score, diagnostic_score, pool),
      next_loop: [
        "Keep the online product policy and its candidate inputs locked as the deployable incumbent.",
        "Treat cross-PR global-budget policies as offline diagnostics, never product defaults.",
        "Improve proof-compatible candidate recall and false-positive refutation before increasing the comment budget.",
        "Replay publisher changes on a fixed pool before paying for a live end-to-end run.",
        "Add final-patch correctness and harmful-repair evaluation before declaring an MVP win."
      ]
    }
  end

  defp summarize(policy) do
    score = policy["score"]

    %{
      policy_id: policy["id"],
      mode: policy["policy"]["mode"],
      f1: score["f1"],
      precision: score["precision"],
      recall: score["recall"],
      usefulness: score["usefulness"],
      snr: score["snr"],
      hits: score["hits"],
      noise: score["noise"],
      published_claims: score["published_claims"],
      avg_comments_per_pr: score["avg_comments_per_pr"]
    }
  end

  defp diagnose(qualified, diagnostic, pool) do
    cond do
      (pool["oracle_recall"] || 0.0) < 0.70 ->
        "Candidate generation is the primary bottleneck: the union pool cannot reach target recall."

      diagnostic["precision"] < qualified["precision"] * 0.90 ->
        "The pool has recall headroom, but verification and ranking cannot spend it without excessive noise."

      true ->
        "The pool and publisher are near the current target; validate transfer and repair outcomes."
    end
  end

  defp fetch_policy!(policies, id) do
    Map.fetch!(policies, id)
  rescue
    KeyError ->
      raise ArgumentError,
            "source run does not contain required incumbent policy #{inspect(id)}"
  end

  defp best_online_policy!(policies) do
    policies
    |> Enum.filter(&(&1["policy"]["mode"] == "online_qualified_f1"))
    |> Enum.filter(&(&1["score"]["precision"] >= 0.70))
    |> Enum.max_by(
      &{&1["score"]["f1"], &1["score"]["precision"], -&1["score"]["noise"]},
      fn ->
        raise ArgumentError,
              "source run does not contain an online product policy clearing 0.70 precision"
      end
    )
  end

  defp render_markdown(report) do
    trust = report.incumbents.trust_default
    online = report.incumbents.online_product
    qualified = report.incumbents.offline_qualified_f1
    diagnostic = report.incumbents.recall_diagnostic
    pool = report.candidate_pool
    gaps = report.gaps

    """
    # Sugary Incumbent Ladder

    > #{report.scope.warning}

    Long-term target: **F1 > #{pct(report.target.f1)}** over #{report.target.corpus}.

    | Operating point | Policy | F1 | Precision | Recall | SNR | Hits | Noise | Avg comments |
    | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    | Trust default | `#{trust.policy_id}` | #{pct(trust.f1)} | #{pct(trust.precision)} | #{pct(trust.recall)} | #{num(trust.snr)} | #{trust.hits} | #{trust.noise} | #{num(trust.avg_comments_per_pr)} |
    | Online product | `#{online.policy_id}` | #{pct(online.f1)} | #{pct(online.precision)} | #{pct(online.recall)} | #{num(online.snr)} | #{online.hits} | #{online.noise} | #{num(online.avg_comments_per_pr)} |
    | Offline qualified F1 | `#{qualified.policy_id}` | #{pct(qualified.f1)} | #{pct(qualified.precision)} | #{pct(qualified.recall)} | #{num(qualified.snr)} | #{qualified.hits} | #{qualified.noise} | #{num(qualified.avg_comments_per_pr)} |
    | Recall diagnostic | `#{diagnostic.policy_id}` | #{pct(diagnostic.f1)} | #{pct(diagnostic.precision)} | #{pct(diagnostic.recall)} | #{num(diagnostic.snr)} | #{diagnostic.hits} | #{diagnostic.noise} | #{num(diagnostic.avg_comments_per_pr)} |

    ## Gap To Target

    - Online-product F1 gap: #{pct(gaps.online_product_f1_to_target)}.
    - Offline qualified-F1 gap: #{pct(gaps.qualified_f1_to_target)}.
    - Diagnostic-F1 gap: #{pct(gaps.diagnostic_f1_to_target)}.
    - Candidate-pool oracle recall: #{pct(pool.oracle_recall)} (#{pool.pool_hits}/#{pool.expected_claims} expected claims).
    - Expected claims missing from every candidate source: #{pool.missing_expected_claims}.

    ## Diagnosis

    #{report.diagnosis}

    ## Promotion Contract

    A challenger must beat the locked online product incumbent, preserve at least
    #{pct(report.promotion_contract.precision_floor)} precision, stay at or above
    #{num(report.promotion_contract.snr_floor)} SNR, and publish no more than
    #{num(report.promotion_contract.max_avg_comments_per_pr)} comments per PR on
    average. Product promotion additionally requires a fresh holdout or transfer
    result and repair-safety, latency, and cost non-regression.

    ## Next Loop

    #{Enum.map_join(report.next_loop, "\n", &"- #{&1}")}
    """
  end

  defp make_out_dir(root, id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(root, "#{timestamp}-#{id}")
  end

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value / 1
  defp parse_float(value) when is_binary(value), do: String.to_float(value)

  defp round4(value), do: Float.round(value, 4)
  defp pct(value), do: :erlang.float_to_binary(value * 100, decimals: 1) <> "%"
  defp num(value), do: :erlang.float_to_binary(value * 1.0, decimals: 3)
end

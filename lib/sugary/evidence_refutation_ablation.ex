defmodule Sugary.EvidenceRefutationAblation do
  @version "evidence-refutation-ablation-v0"
  @required_variants [
    "baseline",
    "evidence_only",
    "refutation_only",
    "evidence_refutation",
    "evidence_refutation_ranker"
  ]

  def maybe_write!(run_dir, manifest, method_reports, research_scorecard) do
    if ablation_run?(manifest, method_reports) do
      ablation = build(manifest, method_reports, research_scorecard)
      Sugary.Json.write!(Path.join(run_dir, "evidence-refutation-ablation.json"), ablation)

      File.write!(
        Path.join(run_dir, "evidence-refutation-ablation.md"),
        render_markdown(ablation)
      )

      ablation
    end
  end

  def build(manifest, method_reports, research_scorecard) do
    method_by_id = Map.new(research_scorecard.methods, &{&1.method_id, &1})

    variants =
      method_reports
      |> Enum.map(fn report ->
        method_card = Map.fetch!(method_by_id, report.method.id)
        variant(report.method, method_card)
      end)
      |> Enum.sort_by(&variant_order/1)

    baseline = Enum.find(variants, &(&1.variant == "baseline"))

    variants =
      Enum.map(variants, fn variant ->
        Map.put(variant, :delta_vs_baseline, delta(variant, baseline))
      end)

    shared_path = shared_path(variants)

    decision =
      decision(variants, baseline, research_scorecard.summary.expected_defects, shared_path)

    %{
      version: @version,
      manifest_id: manifest.id,
      suite: manifest.suite,
      split: manifest.split,
      research_scorecard_version: research_scorecard.version,
      shared_candidate_path: shared_path,
      required_variants_present: required_variants_present?(variants),
      variants: variants,
      decision: decision
    }
  end

  def render_markdown(ablation) do
    rows =
      ablation.variants
      |> Enum.map(fn variant ->
        delta = variant.delta_vs_baseline

        "| #{variant.variant} | #{variant.method_id} | #{fmt(variant.research_utility)} | #{fmt(delta.research_utility)} | #{variant.defect_hits} | #{delta.defect_hits} | #{variant.noise} | #{delta.noise} | #{fmt(variant.usefulness)} |"
      end)
      |> Enum.join("\n")

    tier_rows =
      ablation.variants
      |> Enum.flat_map(fn variant ->
        Enum.map(variant.evidence_tier_distribution, fn tier ->
          "| #{variant.variant} | #{tier.tier} | #{tier.published_comments} | #{tier.defect_hits} | #{tier.noise} | #{fmt(tier.utility)} |"
        end)
      end)
      |> Enum.join("\n")

    marginal_rows =
      ablation.variants
      |> Enum.flat_map(fn variant ->
        Enum.map(variant.marginal_utility_by_rank, fn rank ->
          "| #{variant.variant} | #{rank.rank} | #{rank.published_comments} | #{rank.defect_hits} | #{rank.noise} | #{fmt(rank.utility)} |"
        end)
      end)
      |> Enum.join("\n")

    """
    # Evidence/Refutation Ablation

    This artifact compares the same candidate generation and context path across evidence/refutation/ranking variants. It is a research artifact only and does not change publishing behavior.

    ## Decision

    - Decision: `#{ablation.decision.decision}`
    - Promoted variant: `#{ablation.decision.promoted_variant || "none"}`
    - Reason: #{ablation.decision.reason}
    - Required variants present: #{ablation.required_variants_present}
    - Shared context: #{ablation.shared_candidate_path.shared_context}
    - Shared candidate generation: #{ablation.shared_candidate_path.shared_candidate_generation}

    ## Research Scorecard Deltas

    | Variant | Method | Utility | Delta Utility | Hits | Delta Hits | Noise | Delta Noise | Usefulness |
    | --- | --- | --- | --- | --- | --- | --- | --- | --- |
    #{rows}

    ## Evidence Tier Distribution

    | Variant | Evidence Tier | Comments | Hits | Noise | Utility |
    | --- | --- | --- | --- | --- | --- |
    #{tier_rows}

    ## Marginal Utility By Rank

    | Variant | Rank | Comments | Hits | Noise | Utility |
    | --- | --- | --- | --- | --- | --- |
    #{marginal_rows}
    """
  end

  defp ablation_run?(manifest, method_reports) do
    String.contains?(manifest.id || "", "evidence-refutation-ablation") or
      method_reports
      |> Enum.map(&variant_key(&1.method))
      |> MapSet.new()
      |> then(&Enum.all?(@required_variants, fn variant -> MapSet.member?(&1, variant) end))
  end

  defp variant(method, method_card) do
    %{
      variant: variant_key(method),
      method_id: method.id,
      context: Map.get(method, :context),
      candidate_generation: Map.get(method, :candidate_generation),
      evidence: Map.get(method, :evidence),
      refutation: Map.get(method, :refutation),
      ranking: Map.get(method, :ranking),
      research_utility: method_card.research_utility,
      defect_hits: method_card.defect_hits,
      expected_defects: method_card.expected_defects,
      recall: method_card.recall,
      noise: method_card.noise,
      usefulness: method_card.usefulness,
      published_comments: method_card.published_comments,
      avg_comments_per_pr: method_card.avg_comments_per_pr,
      unresolved_expected_defects: method_card.unresolved_expected_defects,
      evidence_tier_distribution: method_card.evidence_tier_distribution,
      marginal_utility_by_rank: method_card.marginal_utility_by_rank
    }
  end

  defp variant_key(method) do
    evidence? = active_stage?(Map.get(method, :evidence))
    refutation? = active_stage?(Map.get(method, :refutation))
    ranker? = Map.get(method, :ranking) == "expected_value_stub"

    cond do
      evidence? and refutation? and ranker? -> "evidence_refutation_ranker"
      evidence? and refutation? -> "evidence_refutation"
      evidence? -> "evidence_only"
      refutation? -> "refutation_only"
      true -> "baseline"
    end
  end

  defp active_stage?(value), do: value not in [nil, "", "none"]

  defp delta(_variant, nil), do: zero_delta()

  defp delta(variant, baseline) do
    %{
      research_utility: variant.research_utility - baseline.research_utility,
      defect_hits: variant.defect_hits - baseline.defect_hits,
      noise: variant.noise - baseline.noise,
      usefulness: variant.usefulness - baseline.usefulness,
      published_comments: variant.published_comments - baseline.published_comments
    }
  end

  defp zero_delta do
    %{
      research_utility: 0.0,
      defect_hits: 0,
      noise: 0,
      usefulness: 0.0,
      published_comments: 0
    }
  end

  defp shared_path(variants) do
    contexts = variants |> Enum.map(& &1.context) |> Enum.uniq()
    generators = variants |> Enum.map(& &1.candidate_generation) |> Enum.uniq()

    %{
      shared_context: length(contexts) == 1,
      context: List.first(contexts),
      shared_candidate_generation: length(generators) == 1,
      candidate_generation: List.first(generators)
    }
  end

  defp required_variants_present?(variants) do
    present = variants |> Enum.map(& &1.variant) |> MapSet.new()
    Enum.all?(@required_variants, &MapSet.member?(present, &1))
  end

  defp decision(variants, baseline, expected_defects, shared_path) do
    targets =
      variants
      |> Enum.filter(&(&1.variant in ["evidence_refutation", "evidence_refutation_ranker"]))
      |> Enum.sort_by(&{&1.research_utility, &1.defect_hits, -&1.noise}, :desc)

    best_target = List.first(targets)

    cond do
      baseline == nil or best_target == nil or not required_variants_present?(variants) ->
        %{
          decision: "needs_harder_fixtures",
          promoted_variant: nil,
          reason: "Ablation is incomplete; all five variants are required for a decision."
        }

      not shared_path.shared_context or not shared_path.shared_candidate_generation ->
        %{
          decision: "needs_harder_fixtures",
          promoted_variant: nil,
          reason:
            "Variants do not share the same context and candidate-generation path, so evidence/refutation cannot be isolated."
        }

      expected_defects == 0 ->
        %{
          decision: "needs_harder_fixtures",
          promoted_variant: nil,
          reason: "No expected defects were present in the evaluated cases."
        }

      baseline.defect_hits == expected_defects and baseline.noise == 0 ->
        %{
          decision: "needs_harder_fixtures",
          promoted_variant: nil,
          reason:
            "The baseline already found every expected defect with zero noise, so this suite cannot test the mechanism."
        }

      best_target.research_utility > baseline.research_utility and
        best_target.defect_hits >= baseline.defect_hits and best_target.noise <= baseline.noise ->
        %{
          decision: "promote_evidence_refutation_path",
          promoted_variant: best_target.variant,
          reason:
            "Evidence/refutation improved research utility without reducing defect hits or increasing noise."
        }

      best_target.research_utility <= baseline.research_utility and
          best_target.noise > baseline.noise ->
        %{
          decision: "reject_evidence_refutation_path",
          promoted_variant: nil,
          reason:
            "Evidence/refutation failed to improve utility and increased noise against the same candidate path."
        }

      true ->
        %{
          decision: "needs_harder_fixtures",
          promoted_variant: nil,
          reason:
            "The result is mixed or too small; use harder fixtures before promoting or rejecting the mechanism."
        }
    end
  end

  defp variant_order(%{variant: variant}) do
    Enum.find_index(@required_variants, &(&1 == variant)) || 99
  end

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)
end

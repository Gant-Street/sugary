defmodule Sugary.ArchitectureGauntlet do
  alias Sugary.Protocol.ExperimentManifest

  @root ".sugary/research/architecture-gauntlets"
  @version "architecture-gauntlet-v0"
  @metadata_keys ~w(
    role ingredients members description expectation compare_to enabled
  )

  def run!(path, opts \\ []) do
    manifest = parse_manifest!(path, opts)
    out_dir = make_run_dir(manifest.id)
    File.mkdir_p!(out_dir)

    experiment_manifest = experiment_manifest(manifest)

    {experiment_run, method_reports, cases} =
      Sugary.Runner.run_experiment_manifest_with_reports!(experiment_manifest)

    analysis = analyze(manifest, method_reports, cases, experiment_run)

    File.cp!(path, Path.join(out_dir, "gauntlet.toml"))
    File.write!(Path.join(out_dir, "underlying-run.txt"), experiment_run <> "\n")
    Sugary.Json.write!(Path.join(out_dir, "config.json"), json_safe(manifest))
    Sugary.Json.write!(Path.join(out_dir, "scorecards.json"), json_safe(analysis.scorecards))
    Sugary.Json.write!(Path.join(out_dir, "decision.json"), json_safe(analysis))
    File.write!(Path.join(out_dir, "architecture-gauntlet-report.md"), render_report(analysis))

    out_dir
  end

  def parse_manifest!(path, opts \\ []) do
    raw =
      path
      |> Sugary.Toml.parse_file_raw!()
      |> atomize()

    replay_mode = Keyword.get(opts, :replay_mode) || raw[:replay_mode] || "cache-first"

    %{
      id: raw[:id] || Path.basename(path, ".toml"),
      description: raw[:description] || "",
      suite: raw[:suite] || "agent-written-hard-fixtures",
      split: raw[:split],
      limit: raw[:limit],
      offset: raw[:offset],
      replay_mode: replay_mode,
      primary_metric: raw[:primary_metric] || "usefulness_adjusted_f1",
      guardrails: raw[:guardrails] || %{},
      variables: raw[:variables] || [],
      compositions: raw[:compositions] || [],
      source_path: path,
      version: @version
    }
  end

  def analyze(manifest, method_reports, cases, experiment_run) do
    reports_by_id = Map.new(method_reports, &{&1.method.id, &1})
    variable_defs = Enum.filter(manifest.variables, &enabled?/1)
    composition_defs = Enum.filter(manifest.compositions, &enabled?/1)

    variable_cards = Enum.map(variable_defs, &scorecard_for_definition(&1, reports_by_id, cases))

    composition_cards =
      Enum.map(composition_defs, &scorecard_for_definition(&1, reports_by_id, cases))

    references = reference_cards(variable_cards)

    variable_decisions =
      variable_cards
      |> Enum.map(&decide_variable(&1, references, manifest.guardrails))

    all_cards = variable_cards ++ composition_cards

    composition_decisions =
      composition_cards
      |> Enum.map(&decide_composition(&1, all_cards, references, manifest.guardrails))

    best_variable = best_by_rank(variable_cards)
    best_composition = best_by_rank(composition_cards)
    best_overall = best_by_rank(variable_cards ++ composition_cards)

    %{
      version: @version,
      id: manifest.id,
      description: manifest.description,
      suite: manifest.suite,
      split: manifest.split,
      limit: manifest.limit,
      offset: manifest.offset,
      replay_mode: manifest.replay_mode,
      primary_metric: manifest.primary_metric,
      experiment_run: experiment_run,
      case_count: length(cases),
      expected_claims: total_expected(cases),
      scorecards: variable_cards ++ composition_cards,
      variable_decisions: variable_decisions,
      composition_decisions: composition_decisions,
      best_variable: summarize_card(best_variable),
      best_composition: summarize_card(best_composition),
      best_overall: summarize_card(best_overall),
      conclusion:
        conclusion(variable_decisions, composition_decisions, best_variable, best_composition),
      non_claims: [
        "This gauntlet is a local research comparison, not an official benchmark score.",
        "Native harness entries are references unless a locked promotion workflow later promotes them.",
        "Fixture or smoke results do not validate PCRS as a general approach."
      ]
    }
  end

  def render_report(analysis) do
    variable_rows =
      analysis.variable_decisions
      |> Enum.map(fn row ->
        card = row.card
        score = card.score

        "| `#{card.id}` | #{card.role} | #{Enum.join(card.ingredients, ", ")} | #{fmt(score.f1)} | #{fmt(score.usefulness)} | #{fmt(score.snr)} | #{score.hits} | #{score.noise} | #{fmt(score.avg_comments_per_pr)} | #{row.unique_hits_over_reference} | #{row.decision} |"
      end)
      |> Enum.join("\n")

    composition_rows =
      analysis.composition_decisions
      |> Enum.map(fn row ->
        card = row.card
        score = card.score

        comparator = get_in(row, [:best_comparator, :id]) || "none"

        "| `#{card.id}` | #{Enum.join(card.members, ", ")} | `#{comparator}` | #{fmt(score.f1)} | #{fmt(score.usefulness)} | #{fmt(score.snr)} | #{score.hits} | #{score.noise} | #{row.unique_hits_over_comparator} | #{if row.beats_best_comparator, do: "yes", else: "no"} | #{row.decision} |"
      end)
      |> Enum.join("\n")

    """
    # Architecture Gauntlet v0: #{analysis.id}

    #{analysis.description}

    Suite: `#{analysis.suite}`#{if analysis.split, do: " / split: `" <> analysis.split <> "`", else: ""}

    Underlying experiment run: `#{analysis.experiment_run}`

    ## Decision

    #{analysis.conclusion}

    ## Variable Scorecards

    | Variable | Role | Ingredients | F1 | Usefulness | SNR | Hits | Noise | Avg Comments | Unique Hits vs Reference | Decision |
    | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
    #{if variable_rows == "", do: "| none | n/a | n/a | 0 | 0 | 0 | 0 | 0 | 0 | 0 | discard |", else: variable_rows}

    ## Composition Scorecards

    | Composition | Members | Best Comparator | F1 | Usefulness | SNR | Hits | Noise | Unique Hits vs Comparator | Beats Comparator? | Decision |
    | --- | --- | --- | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- |
    #{if composition_rows == "", do: "| none | n/a | none | 0 | 0 | 0 | 0 | 0 | 0 | no | reject |", else: composition_rows}

    ## Best Results

    - Best variable: #{maybe_id(analysis.best_variable)}
    - Best composition: #{maybe_id(analysis.best_composition)}
    - Best overall: #{maybe_id(analysis.best_overall)}

    ## Interpretation

    This gauntlet deliberately treats the five candidate directions as ingredients, not mutually exclusive products. A solo variable can be kept for independent lift. A composition can be promoted only if it beats its best declared member and the best usable reference baseline after merge/ranking while preserving SNR, usefulness, and comment budget.

    ## Non-Claims

    - This is an unofficial local research run.
    - It does not claim public benchmark superiority.
    - It does not prove PCRS generalizes until a locked candidate survives holdout and public benchmark smoke.
    """
  end

  defp experiment_manifest(manifest) do
    definitions = Enum.filter(manifest.variables ++ manifest.compositions, &enabled?/1)

    {methods, reviewers} =
      definitions
      |> Enum.map(&experiment_entry/1)
      |> Enum.split_with(fn {kind, _entry} -> kind == :method end)

    ExperimentManifest.new(%{
      id: "#{manifest.id}-experiment",
      description: manifest.description,
      suite: manifest.suite,
      split: manifest.split,
      limit: manifest.limit,
      offset: manifest.offset,
      replay_mode: manifest.replay_mode,
      methods: Enum.map(methods, &elem(&1, 1)),
      reviewers: Enum.map(reviewers, &elem(&1, 1))
    })
  end

  defp experiment_entry(definition) do
    entry =
      definition
      |> Map.drop(Enum.map(@metadata_keys, &String.to_atom/1))
      |> maybe_method_alias()

    if command_reviewer?(entry) do
      {:reviewer, entry}
    else
      {:method, entry}
    end
  end

  defp maybe_method_alias(%{method: method} = entry) do
    if Map.has_key?(entry, :team) or command_reviewer?(entry) or Map.has_key?(entry, :reviewer) do
      entry
    else
      entry |> Map.delete(:method) |> Map.put(:reviewer, method)
    end
  end

  defp maybe_method_alias(entry), do: entry

  defp command_reviewer?(entry),
    do: Map.get(entry, :type) == "command" or Map.has_key?(entry, :command)

  defp scorecard_for_definition(definition, reports_by_id, _cases) do
    id = definition[:id] || definition["id"]
    report = Map.fetch!(reports_by_id, id)
    hit_keys = hit_keys(report.results)
    noise_keys = noise_keys(report.results)

    %{
      id: id,
      role: definition[:role] || "candidate",
      kind:
        definition[:kind] ||
          if(Map.has_key?(definition, :members), do: "composition", else: "variable"),
      description: definition[:description] || "",
      ingredients: List.wrap(definition[:ingredients]),
      members: List.wrap(definition[:members]),
      score: report.score,
      failures: length(report.failures),
      reviewer_failures: reviewer_failures(report.results),
      hit_keys: hit_keys,
      noise_keys: noise_keys,
      published_keys: published_keys(report.results),
      method_class: report.method.class
    }
  end

  defp decide_variable(card, references, guardrails) do
    reference = reference_for(card, references)

    if reference == nil or reference.id == card.id or reference_role?(card.role) do
      reference_decision =
        cond do
          not reference_role?(card.role) -> "needs_reference"
          usable_reference?(card) -> "reference"
          true -> "reference_unavailable"
        end

      %{
        card: summarize_card(card),
        reference: summarize_card(reference),
        decision: reference_decision,
        reason:
          case reference_decision do
            "reference" -> "Reference baseline."
            "reference_unavailable" -> "Reference baseline was unavailable or failed every case."
            _ -> "No reference was available."
          end,
        unique_hits_over_reference: 0,
        checks: %{}
      }
    else
      unique = unique_hits(card, reference)
      checks = guardrail_checks(card, reference, unique, guardrails)

      decision =
        cond do
          Enum.all?(Map.values(checks)) -> "keep"
          unique > 0 or improves?(card.score, reference.score) -> "quarantine"
          true -> "discard"
        end

      %{
        card: summarize_card(card),
        reference: summarize_card(reference),
        decision: decision,
        reason: decision_reason(decision, "variable"),
        unique_hits_over_reference: unique,
        score_delta: score_delta(card.score, reference.score),
        checks: checks
      }
    end
  end

  defp decide_composition(card, comparison_cards, references, guardrails) do
    member_cards =
      case card.members do
        [] ->
          Enum.reject(comparison_cards, &(&1.id == card.id))

        members ->
          comparison_cards |> Enum.reject(&(&1.id == card.id)) |> Enum.filter(&(&1.id in members))
      end

    comparator_cards =
      (member_cards ++ Enum.reject(references, &(&1.id == card.id)))
      |> Enum.uniq_by(& &1.id)

    best_member = best_by_rank(member_cards)
    best_comparator = best_by_rank(comparator_cards)

    if best_comparator == nil do
      %{
        card: summarize_card(card),
        best_member: nil,
        best_comparator: nil,
        decision: "reject",
        reason: "No member or reference baseline was available.",
        unique_hits_over_comparator: 0,
        beats_best_member: false,
        beats_best_comparator: false,
        checks: %{}
      }
    else
      unique = unique_hits(card, best_comparator)
      checks = guardrail_checks(card, best_comparator, unique, guardrails)
      beats_member = best_member != nil and improves?(card.score, best_member.score)
      beats_comparator = improves?(card.score, best_comparator.score)

      decision =
        cond do
          beats_member and beats_comparator and Enum.all?(Map.values(checks)) -> "promote"
          unique > 0 or beats_member or beats_comparator -> "quarantine"
          true -> "reject"
        end

      %{
        card: summarize_card(card),
        best_member: summarize_card(best_member),
        best_comparator: summarize_card(best_comparator),
        decision: decision,
        reason: decision_reason(decision, "composition"),
        unique_hits_over_comparator: unique,
        beats_best_member: beats_member,
        beats_best_comparator: beats_comparator,
        score_delta: score_delta(card.score, best_comparator.score),
        checks: checks
      }
    end
  end

  defp guardrail_checks(card, reference, unique_hits, guardrails) do
    min_snr_ratio = number_guardrail(guardrails, :min_snr_ratio, 0.9)
    min_usefulness_ratio = number_guardrail(guardrails, :min_usefulness_ratio, 1.0)
    min_relative_f1 = number_guardrail(guardrails, :min_relative_f1, 1.0)
    min_absolute_snr = number_guardrail(guardrails, :min_absolute_snr, 0.0)
    min_absolute_usefulness = number_guardrail(guardrails, :min_absolute_usefulness, 0.0)
    max_added_noise = number_guardrail(guardrails, :max_added_noise, 0)
    max_avg_comments = number_guardrail(guardrails, :max_avg_comments_per_pr, 3.0)
    min_unique_hits = number_guardrail(guardrails, :min_unique_hits, 1)

    %{
      improves_primary_metric: improves?(card.score, reference.score),
      f1_margin: card.score.f1 >= reference.score.f1 * min_relative_f1,
      usefulness: card.score.usefulness >= reference.score.usefulness * min_usefulness_ratio,
      absolute_usefulness: card.score.usefulness >= min_absolute_usefulness,
      snr: card.score.snr >= reference.score.snr * min_snr_ratio,
      absolute_snr: card.score.snr >= min_absolute_snr,
      noise: card.score.noise <= reference.score.noise + max_added_noise,
      comments: card.score.avg_comments_per_pr <= max_avg_comments,
      unique_signal_or_noise_reduction:
        unique_hits >= min_unique_hits or card.score.noise < reference.score.noise
    }
  end

  defp reference_cards(variable_cards) do
    references = Enum.filter(variable_cards, &reference_role?(&1.role))
    usable = Enum.filter(references, &usable_reference?/1)

    cond do
      usable != [] -> usable
      references != [] -> []
      true -> Enum.take(variable_cards, 1)
    end
  end

  defp usable_reference?(card), do: card.reviewer_failures < max(card.score.cases, 1)

  defp reference_for(card, references) do
    references
    |> Enum.reject(&(&1.id == card.id))
    |> best_by_rank()
  end

  defp reference_role?(role) do
    role = role |> to_string() |> String.downcase()
    role in ["reference", "baseline", "control", "native_harness_reference"]
  end

  defp conclusion(variable_decisions, composition_decisions, _best_variable, _best_composition) do
    promoted = Enum.filter(composition_decisions, &(&1.decision == "promote"))
    kept = Enum.filter(variable_decisions, &(&1.decision == "keep"))

    quarantined =
      Enum.filter(variable_decisions ++ composition_decisions, &(&1.decision == "quarantine"))

    cond do
      promoted != [] ->
        best = promoted |> Enum.max_by(&score_rank(&1.card.score))

        "Promote `#{best.card.id}` as the next locked candidate for this local gauntlet. It beat its best member and best usable reference while clearing guardrails."

      kept != [] ->
        ids = kept |> Enum.map(&"`#{&1.card.id}`") |> Enum.join(", ")
        "Keep #{ids} as independently useful ingredients, but no composition was promoted."

      quarantined != [] ->
        "Quarantine promising ingredients or compositions. They found signal or improved a metric, but failed at least one noise/usefulness/SNR guardrail."

      true ->
        "No ingredient or composition earned promotion. Keep the current baseline and change the research question."
    end
  end

  defp decision_reason("keep", "variable"),
    do:
      "Variable improved the reference while clearing usefulness, SNR, noise, comment, and unique-hit guardrails."

  defp decision_reason("promote", "composition"),
    do: "Composition beat its best member and best usable reference while clearing guardrails."

  defp decision_reason("quarantine", _kind),
    do: "Found signal or metric lift, but failed one or more guardrails."

  defp decision_reason("discard", _kind), do: "No measurable value over the reference."
  defp decision_reason("reject", _kind), do: "Did not beat the best member or reference."

  defp hit_keys(case_results) do
    case_results
    |> Enum.flat_map(fn result ->
      result.final_claims
      |> Enum.filter(&(&1.publish_decision == "publish"))
      |> Enum.flat_map(fn claim ->
        case Sugary.ClaimMatcher.expected_claim(result.case, claim) do
          nil -> []
          expected -> ["#{result.case.id}::#{field(expected, :id)}"]
        end
      end)
    end)
    |> MapSet.new()
  end

  defp noise_keys(case_results) do
    case_results
    |> Enum.flat_map(fn result ->
      result.final_claims
      |> Enum.filter(&(&1.publish_decision == "publish"))
      |> Enum.reject(&Sugary.ClaimMatcher.expected_claim(result.case, &1))
      |> Enum.map(fn claim ->
        kind =
          if Sugary.ClaimMatcher.known_non_issue(result.case, claim) do
            "known"
          else
            "unsupported"
          end

        "#{result.case.id}::#{kind}:#{claim.dedupe_key}"
      end)
    end)
    |> MapSet.new()
  end

  defp published_keys(case_results) do
    case_results
    |> Enum.flat_map(fn result ->
      result.final_claims
      |> Enum.filter(&(&1.publish_decision == "publish"))
      |> Enum.map(&"#{result.case.id}::#{&1.dedupe_key}")
    end)
    |> MapSet.new()
  end

  defp reviewer_failures(case_results) do
    Enum.count(case_results, fn result ->
      result.reviewer_result.errors not in [nil, []]
    end)
  end

  defp unique_hits(left, right) do
    left.hit_keys
    |> MapSet.difference(right.hit_keys)
    |> MapSet.size()
  end

  defp improves?(left, right),
    do: left.f1 > right.f1 or usefulness_adjusted_f1(left) > usefulness_adjusted_f1(right)

  defp usefulness_adjusted_f1(score), do: score.f1 * score.usefulness

  defp score_delta(left, right) do
    %{
      f1: left.f1 - right.f1,
      usefulness: left.usefulness - right.usefulness,
      snr: left.snr - right.snr,
      hits: left.hits - right.hits,
      noise: left.noise - right.noise,
      avg_comments_per_pr: left.avg_comments_per_pr - right.avg_comments_per_pr,
      cost: left.cost - right.cost,
      latency_ms: left.latency_ms - right.latency_ms
    }
  end

  defp summarize_card(nil), do: nil

  defp summarize_card(card) do
    card
    |> Map.drop([:hit_keys, :noise_keys, :published_keys])
  end

  defp best_by_rank([]), do: nil
  defp best_by_rank(cards), do: Enum.max_by(cards, &score_rank(&1.score))

  defp score_rank(score), do: {score.f1, score.usefulness, score.snr, score.recall}

  defp total_expected(cases) do
    cases
    |> Enum.map(&(Map.get(&1.oracle, :expectedClaims, []) |> length()))
    |> Enum.sum()
  end

  defp enabled?(definition), do: Map.get(definition, :enabled, true) != false

  defp number_guardrail(guardrails, key, default) do
    value = Map.get(guardrails, key) || Map.get(guardrails, to_string(key)) || default

    cond do
      is_integer(value) -> value
      is_float(value) -> value
      true -> default
    end
  end

  defp make_run_dir(id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(@root, "#{timestamp}-#{id}")
  end

  defp maybe_id(nil), do: "none"
  defp maybe_id(%{id: id}), do: "`#{id}`"

  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value) when is_integer(value), do: to_string(value)
  defp fmt(nil), do: "0.000"
  defp fmt(value), do: to_string(value)

  defp atomize(%{} = map),
    do: Map.new(map, fn {key, value} -> {atom_key(key), atomize(value)} end)

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value
  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)

  defp json_safe(%MapSet{} = set), do: set |> MapSet.to_list() |> Enum.sort()
  defp json_safe(%_module{} = struct), do: struct |> Map.from_struct() |> json_safe()
  defp json_safe(%{} = map), do: Map.new(map, fn {key, value} -> {key, json_safe(value)} end)
  defp json_safe(list) when is_list(list), do: Enum.map(list, &json_safe/1)
  defp json_safe(value), do: value

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(%_module{} = struct, key, default),
    do: struct |> Map.from_struct() |> field(key, default)

  defp field(%{} = map, key, default), do: map[key] || map[to_string(key)] || default
  defp field(_value, _key, default), do: default
end

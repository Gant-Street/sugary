defmodule Sugary.Protocol do
  def validate!(module, attrs) when is_atom(module) and is_map(attrs) do
    required = module.required_fields()
    keys = MapSet.new(Enum.map(Map.keys(attrs), &normalize_key/1))
    missing = Enum.reject(required, &MapSet.member?(keys, &1))

    if missing == [] do
      :ok
    else
      raise ArgumentError,
            "#{inspect(module)} missing required fields: #{Enum.join(Enum.map(missing, &to_string/1), ", ")}"
    end
  end

  def build!(module, attrs) when is_atom(module) and is_map(attrs) do
    validate!(module, attrs)
    struct(module, atomize_known(module, attrs))
  end

  def to_map(%module{} = struct) when is_atom(module) do
    struct
    |> Map.from_struct()
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
    |> Enum.into(%{})
  end

  defp atomize_known(module, attrs) do
    known = MapSet.new(module.__struct__() |> Map.from_struct() |> Map.keys())

    Map.new(attrs, fn {key, value} ->
      atom_key = normalize_key(key)

      if MapSet.member?(known, atom_key) do
        {atom_key, value}
      else
        {key, value}
      end
    end)
  end

  defp normalize_key(key) when is_atom(key), do: key
  defp normalize_key(key) when is_binary(key), do: String.to_atom(key)

  defmodule ReviewInputBundle do
    @required ~w(case_id suite pr diff context method)a
    defstruct @required ++ [:metadata]
    def required_fields, do: @required
    def new(attrs), do: Sugary.Protocol.build!(__MODULE__, attrs)
  end

  defmodule Evidence do
    @required ~w(type tier strength summary)a
    defstruct @required ++ [:source]
    def required_fields, do: @required
    def new(attrs), do: Sugary.Protocol.build!(__MODULE__, attrs)
  end

  defmodule ReviewClaim do
    @required ~w(id claim category severity confidence path introduced_by_pr evidence dedupe_key source)a
    defstruct @required ++
                [
                  :start_line,
                  :end_line,
                  :failure_path,
                  :suggested_fix,
                  :suggested_test,
                  :counterarguments,
                  :publish_decision,
                  :suppressed_reason
                ]

    def required_fields, do: @required
    def new(attrs), do: Sugary.Protocol.build!(__MODULE__, attrs)
  end

  defmodule ReviewerResult do
    @required ~w(reviewer_id method_id class claims cost latency_ms)a
    defstruct @required ++ [:artifacts, :errors]
    def required_fields, do: @required
    def new(attrs), do: Sugary.Protocol.build!(__MODULE__, attrs)
  end

  defmodule BenchmarkCase do
    @required ~w(id suite pr diff oracle)a
    defstruct @required ++
                [
                  :repo,
                  :context,
                  :tags,
                  :split,
                  :code_before,
                  :code_after,
                  :traps,
                  :labels,
                  :source_metadata,
                  :public_benchmark
                ]

    def required_fields, do: @required
    def new(attrs), do: Sugary.Protocol.build!(__MODULE__, attrs)
  end

  defmodule ExperimentManifest do
    @required ~w(id suite methods)a
    defstruct @required ++
                [
                  :reviewers,
                  :description,
                  :split,
                  :limit,
                  :replay_mode,
                  :max_cost_usd,
                  :max_duration_seconds,
                  :promotion
                ]

    def required_fields, do: @required
    def new(attrs), do: Sugary.Protocol.build!(__MODULE__, attrs)
  end

  defmodule CampaignManifest do
    @required ~w(id suite search_space)a
    defstruct @required ++
                [
                  :description,
                  :split,
                  :fixed_baselines,
                  :budget,
                  :replay_mode,
                  :primary_metric,
                  :guardrails,
                  :stop_conditions,
                  :promotion_policy,
                  :metadata,
                  :path
                ]

    def required_fields, do: @required
    def new(attrs), do: Sugary.Protocol.build!(__MODULE__, attrs)
  end

  defmodule ReviewTeam do
    @required ~w(id reviewers)a
    defstruct @required ++
                [
                  :description,
                  :merge_strategy,
                  :failure_policy,
                  :max_published_claims,
                  :metadata,
                  :artifact_fields,
                  :path
                ]

    def required_fields, do: @required
    def new(attrs), do: Sugary.Protocol.build!(__MODULE__, attrs)
  end

  defmodule ReviewerPack do
    @required ~w(id reviewers)a
    defstruct @required ++ [:description, :metadata, :path]

    def required_fields, do: @required
    def new(attrs), do: Sugary.Protocol.build!(__MODULE__, attrs)
  end

  defmodule Scorecard do
    @required ~w(cases expected_claims published_claims hits valid_suggestions noise suppressed_true_claims precision recall f1 usefulness snr avg_comments_per_pr cost latency_ms)a
    defstruct @required ++ [:method_id]
    def required_fields, do: @required
    def new(attrs), do: Sugary.Protocol.build!(__MODULE__, attrs)
  end

  defmodule FailureRecord do
    @required ~w(id case_id method_id type category summary)a
    defstruct @required ++ [:expected_claim_id, :claim_id, :suggested_experiment]
    def required_fields, do: @required
    def new(attrs), do: Sugary.Protocol.build!(__MODULE__, attrs)
  end
end

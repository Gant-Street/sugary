defmodule Sugary.Toml do
  alias Sugary.Protocol.ExperimentManifest
  alias Sugary.Protocol.CampaignManifest
  alias Sugary.Protocol.ReviewerPack
  alias Sugary.Protocol.ReviewTeam

  def parse_file!(path) do
    path
    |> File.read!()
    |> parse!()
    |> ExperimentManifest.new()
  end

  def parse_file_raw!(path) do
    path
    |> File.read!()
    |> parse!()
  end

  def parse_campaign_file!(path) do
    path
    |> File.read!()
    |> parse!()
    |> Map.put_new("split", "dev")
    |> Map.put_new("fixed_baselines", %{})
    |> Map.put_new("budget", %{})
    |> Map.put_new("replay_mode", "cache-first")
    |> Map.put_new("primary_metric", "research_utility")
    |> Map.put_new("guardrails", %{})
    |> Map.put_new("stop_conditions", %{})
    |> Map.put_new("promotion_policy", %{})
    |> Map.put_new("metadata", %{})
    |> Map.put("path", path)
    |> CampaignManifest.new()
  end

  def parse_team_file!(path) do
    path
    |> File.read!()
    |> parse!()
    |> Map.put_new("failure_policy", "continue")
    |> Map.put_new("merge_strategy", "dedupe_by_key_location_and_claim")
    |> Map.put_new("max_published_claims", 3)
    |> Map.put_new("metadata", %{})
    |> Map.put_new("artifact_fields", [])
    |> Map.put("path", path)
    |> ReviewTeam.new()
  end

  def parse_reviewer_pack_file!(path) do
    path
    |> File.read!()
    |> parse!()
    |> Map.put_new("metadata", %{})
    |> Map.put("path", path)
    |> ReviewerPack.new()
  end

  def parse!(text) do
    text
    |> String.split("\n")
    |> Enum.reduce({%{"methods" => [], "reviewers" => []}, :root}, &parse_line/2)
    |> elem(0)
  end

  defp parse_line(raw, {doc, section}) do
    line =
      raw
      |> String.split("#", parts: 2)
      |> hd()
      |> String.trim()

    cond do
      line == "" ->
        {doc, section}

      line == "[[methods]]" ->
        methods = Map.get(doc, "methods", []) ++ [%{}]
        {%{doc | "methods" => methods}, :method}

      line == "[[reviewers]]" ->
        reviewers = Map.get(doc, "reviewers", []) ++ [%{}]
        {%{doc | "reviewers" => reviewers}, :reviewer}

      line == "[promotion]" ->
        {Map.put_new(doc, "promotion", %{}), :promotion}

      line == "[suite]" ->
        {Map.put_new(doc, "suite", %{}), {:table, ["suite"]}}

      String.starts_with?(line, "[split.") ->
        split =
          line
          |> String.trim_leading("[split.")
          |> String.trim_trailing("]")

        doc =
          doc
          |> Map.put_new("split", %{})
          |> put_in(["split", split], Map.get(doc["split"] || %{}, split, %{}))

        {doc, {:table, ["split", split]}}

      String.starts_with?(line, "[") ->
        table =
          line
          |> String.trim_leading("[")
          |> String.trim_trailing("]")
          |> String.split(".")

        doc =
          if get_in(doc, table) == nil do
            put_in(doc, table, %{})
          else
            doc
          end

        {doc, {:table, table}}

      true ->
        [key, value] = String.split(line, "=", parts: 2)
        put_value(doc, section, String.trim(key), parse_value(String.trim(value)))
    end
  end

  defp put_value(doc, :method, key, value) do
    methods = Map.get(doc, "methods", [])
    {last, rest} = List.pop_at(methods, -1)
    {%{doc | "methods" => rest ++ [Map.put(last || %{}, key, value)]}, :method}
  end

  defp put_value(doc, :reviewer, key, value) do
    reviewers = Map.get(doc, "reviewers", [])
    {last, rest} = List.pop_at(reviewers, -1)
    {%{doc | "reviewers" => rest ++ [Map.put(last || %{}, key, value)]}, :reviewer}
  end

  defp put_value(doc, :promotion, key, value) do
    promotion = doc |> Map.get("promotion", %{}) |> Map.put(key, value)
    {Map.put(doc, "promotion", promotion), :promotion}
  end

  defp put_value(doc, {:table, path}, key, value) do
    {put_in(doc, path ++ [key], value), {:table, path}}
  end

  defp put_value(doc, section, key, value), do: {Map.put(doc, key, value), section}

  defp parse_value("\"" <> rest), do: rest |> String.trim_trailing("\"")
  defp parse_value("true"), do: true
  defp parse_value("false"), do: false

  defp parse_value("[" <> _rest = value) do
    value
    |> String.trim_leading("[")
    |> String.trim_trailing("]")
    |> split_array()
    |> Enum.map(&parse_value/1)
  end

  defp parse_value("{" <> _rest = value) do
    value
    |> String.trim_leading("{")
    |> String.trim_trailing("}")
    |> split_array()
    |> Enum.map(fn entry ->
      [key, raw_value] = String.split(entry, "=", parts: 2)
      {trim_key(key), parse_value(String.trim(raw_value))}
    end)
    |> Map.new()
  end

  defp parse_value(value) do
    cond do
      String.contains?(value, ".") ->
        case Float.parse(value) do
          {number, ""} -> number
          _ -> value
        end

      true ->
        case Integer.parse(value) do
          {number, ""} -> number
          _ -> value
        end
    end
  end

  defp split_array(""), do: []

  defp split_array(value) do
    Regex.scan(~r/"[^"]*"|[^,]+/, value)
    |> Enum.map(fn [part] -> String.trim(part) end)
    |> Enum.reject(&(&1 == ""))
  end

  defp trim_key(key) do
    key
    |> String.trim()
    |> String.trim_leading("\"")
    |> String.trim_trailing("\"")
  end
end

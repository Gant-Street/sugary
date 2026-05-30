defmodule Sugary.MartianNoKey do
  @moduledoc false

  @root ".sugary/research/martian-no-key"
  @default_tool "sugary-pcrs-repo-budget-max2"
  @default_model_dir "sugary_local_parity_v0"

  @focus_tools [
    "coderabbit",
    "cubic-dev",
    "cubic-v2",
    "greptile",
    "greptile-v4",
    "greptile-v4-1"
  ]

  def report!(opts) when is_map(opts) do
    opts
    |> Enum.map(fn {key, value} ->
      {String.to_atom(to_string(key) |> String.replace("-", "_")), value}
    end)
    |> report!()
  end

  def report!(opts) when is_list(opts) do
    tool = Keyword.get(opts, :sugary_tool, Keyword.get(opts, :tool, @default_tool))
    model_dir = Keyword.get(opts, :model_dir, @default_model_dir)
    id = Keyword.get(opts, :id, "martian-no-key-comparison-v0")
    {martian_root, offline_dir} = martian_paths(Keyword.get(opts, :martian_dir))

    out_dir = make_out_dir(id)
    File.rm_rf!(out_dir)
    File.mkdir_p!(out_dir)

    model_scorecards =
      offline_dir
      |> Path.join("results/*/evaluations.json")
      |> Path.wildcard()
      |> Enum.sort()
      |> Enum.map(&model_scorecard/1)

    summary = %{
      id: id,
      generated_at: DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ"),
      martian_root: martian_root,
      martian_commit_sha: git_sha(martian_root),
      evaluation_models: Enum.map(model_scorecards, & &1.model),
      model_scorecards: model_scorecards,
      consensus_scorecard: consensus(model_scorecards),
      focus_tools: focus_table(model_scorecards),
      sugary_candidate_summary: sugary_candidate_summary(offline_dir, model_dir, tool),
      no_key_mode: true,
      official_sugary_score: "unavailable_without_MARTIAN_API_KEY"
    }

    Sugary.Json.write!(Path.join(out_dir, "model-scorecards.json"), model_scorecards)

    Sugary.Json.write!(
      Path.join(out_dir, "consensus-scorecard.json"),
      summary.consensus_scorecard
    )

    Sugary.Json.write!(Path.join(out_dir, "focus-tools.json"), summary.focus_tools)

    Sugary.Json.write!(
      Path.join(out_dir, "sugary-candidate-summary.json"),
      summary.sugary_candidate_summary
    )

    Sugary.Json.write!(Path.join(out_dir, "summary.json"), Map.drop(summary, [:model_scorecards]))
    File.write!(Path.join(out_dir, "report.md"), render_report(summary))

    out_dir
  end

  defp martian_paths(nil) do
    case Sugary.Martian.locate() do
      nil ->
        raise ArgumentError,
              "Martian offline benchmark not found. Set --martian-dir or MARTIAN_BENCH_DIR."

      root ->
        martian_paths(root)
    end
  end

  defp martian_paths(path) do
    expanded = Path.expand(path)

    cond do
      File.exists?(Path.join([expanded, "results", "benchmark_data.json"])) ->
        {Path.dirname(expanded), expanded}

      File.exists?(Path.join([expanded, "offline", "results", "benchmark_data.json"])) ->
        {expanded, Path.join(expanded, "offline")}

      true ->
        raise ArgumentError, "Martian offline results not found under #{path}"
    end
  end

  defp model_scorecard(path) do
    model = path |> Path.dirname() |> Path.basename()

    tools =
      path
      |> Sugary.Json.read!()
      |> aggregate_tools()
      |> Enum.sort_by(&{-&1.f1, -&1.precision, -&1.recall, &1.tool})

    %{
      model: model,
      evaluations_path: Path.expand(path),
      tool_count: length(tools),
      best_tool: List.first(tools),
      tools: tools
    }
  end

  defp aggregate_tools(evaluations) do
    evaluations
    |> Enum.flat_map(fn {_url, tools} -> Map.values(tools) end)
    |> Enum.reduce(%{}, fn result, acc ->
      tool = field(result, :tool)

      if tool in [nil, ""] or field(result, :skipped, false) == true do
        acc
      else
        Map.update(acc, tool, init_tool(tool, result), &merge_result(&1, result))
      end
    end)
    |> Map.values()
    |> Enum.map(&finish_tool/1)
  end

  defp init_tool(tool, result),
    do:
      merge_result(
        %{tool: tool, reviews: 0, tp: 0, fp: 0, fn: 0, candidates: 0, golden: 0, errors: 0},
        result
      )

  defp merge_result(acc, result) do
    %{
      acc
      | reviews: acc.reviews + 1,
        tp: acc.tp + int(field(result, :tp, 0)),
        fp: acc.fp + int(field(result, :fp, 0)),
        fn: acc.fn + int(field(result, :fn, 0)),
        candidates: acc.candidates + int(field(result, :total_candidates, 0)),
        golden: acc.golden + int(field(result, :total_golden, 0)),
        errors: acc.errors + int(field(result, :errors_count, 0))
    }
  end

  defp finish_tool(tool) do
    precision = ratio(tool.tp, tool.tp + tool.fp)
    recall = ratio(tool.tp, tool.tp + tool.fn)
    f1 = if precision + recall == 0, do: 0.0, else: 2 * precision * recall / (precision + recall)

    Map.merge(tool, %{
      precision: precision,
      recall: recall,
      f1: f1,
      avg_candidates_per_pr: ratio(tool.candidates, tool.reviews)
    })
  end

  defp consensus(model_scorecards) do
    model_scorecards
    |> Enum.flat_map(fn model ->
      Enum.map(model.tools, fn tool -> {tool.tool, model.model, tool} end)
    end)
    |> Enum.group_by(fn {tool, _model, _score} -> tool end)
    |> Enum.map(fn {tool, rows} ->
      scores = Enum.map(rows, fn {_tool, _model, score} -> score end)

      %{
        tool: tool,
        judged_models: Enum.map(rows, fn {_tool, model, _score} -> model end) |> Enum.sort(),
        avg_f1: avg(scores, :f1),
        max_f1: max_metric(scores, :f1),
        min_f1: min_metric(scores, :f1),
        avg_precision: avg(scores, :precision),
        avg_recall: avg(scores, :recall),
        avg_candidates_per_pr: avg(scores, :avg_candidates_per_pr)
      }
    end)
    |> Enum.sort_by(&{-&1.avg_f1, -&1.avg_precision, &1.tool})
  end

  defp focus_table(model_scorecards) do
    by_tool = Map.new(consensus(model_scorecards), &{&1.tool, &1})

    @focus_tools
    |> Enum.map(fn tool ->
      Map.get(by_tool, tool, %{
        tool: tool,
        judged_models: [],
        avg_f1: nil,
        max_f1: nil,
        min_f1: nil,
        avg_precision: nil,
        avg_recall: nil,
        avg_candidates_per_pr: nil
      })
    end)
  end

  defp sugary_candidate_summary(offline_dir, model_dir, tool) do
    benchmark_data_path = Path.join([offline_dir, "results", "benchmark_data.json"])
    candidates_path = Path.join([offline_dir, "results", model_dir, "candidates.json"])
    dedup_path = Path.join([offline_dir, "results", model_dir, "dedup_groups.json"])

    if File.exists?(benchmark_data_path) and File.exists?(candidates_path) do
      benchmark_data = Sugary.Json.read!(benchmark_data_path)
      candidates = Sugary.Json.read!(candidates_path)
      dedup = if File.exists?(dedup_path), do: Sugary.Json.read!(dedup_path), else: %{}

      rows =
        Enum.map(benchmark_data, fn {url, entry} ->
          candidate_count = length(get_in(candidates, [url, tool]) || [])
          golden_count = length(field(entry, :golden_comments, []))

          %{
            url: url,
            candidates: candidate_count,
            golden_comments: golden_count,
            judge_pairs: candidate_count * golden_count,
            dedup_groups: length(get_in(dedup, [url, tool]) || []),
            has_review_entry: has_review_entry?(entry, tool)
          }
        end)

      %{
        tool: tool,
        model_dir: model_dir,
        candidates_path: Path.expand(candidates_path),
        dedup_groups_path: if(File.exists?(dedup_path), do: Path.expand(dedup_path), else: nil),
        prs: length(rows),
        prs_with_candidates: Enum.count(rows, &(&1.candidates > 0)),
        prs_with_review_entry: Enum.count(rows, & &1.has_review_entry),
        candidates: Enum.sum(Enum.map(rows, & &1.candidates)),
        golden_comments: Enum.sum(Enum.map(rows, & &1.golden_comments)),
        judge_pair_calls: Enum.sum(Enum.map(rows, & &1.judge_pairs)),
        dedup_groups: Enum.sum(Enum.map(rows, & &1.dedup_groups)),
        status: "exported_unjudged",
        official_f1: nil,
        reason: "MARTIAN_API_KEY is not configured, so Martian has not judged these candidates."
      }
    else
      %{
        tool: tool,
        model_dir: model_dir,
        status: "missing_candidates",
        candidates_path: Path.expand(candidates_path),
        official_f1: nil
      }
    end
  end

  defp has_review_entry?(entry, tool) do
    entry
    |> field(:reviews, [])
    |> Enum.any?(&(field(&1, :tool) == tool))
  end

  defp render_report(summary) do
    model_sections =
      summary.model_scorecards
      |> Enum.map(&render_model_section/1)
      |> Enum.join("\n\n")

    focus_rows =
      summary.focus_tools
      |> Enum.map(fn row ->
        "| #{row.tool} | #{fmt(row.avg_f1)} | #{fmt(row.avg_precision)} | #{fmt(row.avg_recall)} | #{fmt(row.avg_candidates_per_pr)} | #{length(row.judged_models)} |"
      end)
      |> Enum.join("\n")

    consensus_rows =
      summary.consensus_scorecard
      |> Enum.take(15)
      |> Enum.map(fn row ->
        "| #{row.tool} | #{fmt(row.avg_f1)} | #{fmt(row.max_f1)} | #{fmt(row.min_f1)} | #{fmt(row.avg_precision)} | #{fmt(row.avg_recall)} | #{fmt(row.avg_candidates_per_pr)} |"
      end)
      |> Enum.join("\n")

    sugary = summary.sugary_candidate_summary

    """
    # Martian No-Key Comparison

    Local-only report. This uses bundled Martian evaluation files for existing tools and does not judge Sugary. No API key was used, no result was submitted, and this is not an official Sugary benchmark score.

    ## Sugary Status

    - Tool: `#{sugary.tool}`
    - Status: `#{sugary.status}`
    - PRs with review entry: #{Map.get(sugary, :prs_with_review_entry, 0)}/#{Map.get(sugary, :prs, 0)}
    - Candidates awaiting Martian judge: #{Map.get(sugary, :candidates, 0)}
    - Candidate/golden judge pairs: #{Map.get(sugary, :judge_pair_calls, 0)}
    - Official F1: unavailable without `MARTIAN_API_KEY`

    ## Competitor Focus

    | Tool | Avg F1 | Avg Precision | Avg Recall | Avg Candidates/PR | Judge Models |
    | --- | ---: | ---: | ---: | ---: | ---: |
    #{focus_rows}

    ## Top Bundled Tools By Average F1

    | Tool | Avg F1 | Max F1 | Min F1 | Avg Precision | Avg Recall | Avg Candidates/PR |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: |
    #{consensus_rows}

    #{model_sections}

    ## Interpretation

    Without a Martian API key, the useful work is target analysis and proxy iteration. This report tells us the official bundled landscape and keeps Sugary clearly marked as exported but unjudged.
    """
  end

  defp render_model_section(model) do
    rows =
      model.tools
      |> Enum.take(10)
      |> Enum.map(fn tool ->
        "| #{tool.tool} | #{fmt(tool.f1)} | #{fmt(tool.precision)} | #{fmt(tool.recall)} | #{tool.tp} | #{tool.fp} | #{tool.fn} | #{fmt(tool.avg_candidates_per_pr)} |"
      end)
      |> Enum.join("\n")

    """
    ## #{model.model}

    | Tool | F1 | Precision | Recall | TP | FP | FN | Avg Candidates/PR |
    | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
    #{rows}
    """
  end

  defp make_out_dir(id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(@root, "#{timestamp}-#{id}")
  end

  defp avg([], _key), do: nil

  defp avg(rows, key) do
    values = Enum.map(rows, &Map.fetch!(&1, key))
    Enum.sum(values) / max(length(values), 1)
  end

  defp max_metric([], _key), do: nil
  defp max_metric(rows, key), do: rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.max()
  defp min_metric([], _key), do: nil
  defp min_metric(rows, key), do: rows |> Enum.map(&Map.fetch!(&1, key)) |> Enum.min()

  defp ratio(_numerator, 0), do: 0.0
  defp ratio(numerator, denominator), do: numerator / denominator

  defp fmt(nil), do: "n/a"
  defp fmt(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 3)
  defp fmt(value), do: to_string(value)

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_float(value), do: trunc(value)
  defp int(value) when is_binary(value), do: String.to_integer(value)
  defp int(_value), do: 0

  defp git_sha(path) do
    case System.cmd("git", ["-C", path, "rev-parse", "--short", "HEAD"], stderr_to_stdout: true) do
      {sha, 0} -> String.trim(sha)
      _other -> nil
    end
  end

  defp field(map, key, default \\ nil)

  defp field(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp field(_other, _key, default), do: default
end

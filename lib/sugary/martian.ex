defmodule Sugary.Martian do
  @behaviour Sugary.BenchmarkAdapter

  @candidates [
    ".sugary/research/benchmarks/martian-offline",
    "benchmarks/martian-offline",
    "vendor/martian-offline"
  ]

  def locate do
    env = System.get_env("MARTIAN_BENCH_DIR")

    if env not in [nil, ""] do
      if File.dir?(env), do: env
    else
      Enum.find(@candidates, &File.dir?/1)
    end
  end

  def fetch_local_only do
    case locate() do
      nil ->
        {:error,
         "Martian offline benchmark not found. Set MARTIAN_BENCH_DIR or place it at .sugary/research/benchmarks/martian-offline. No network fetch is attempted in local-only mode."}

      path ->
        {:ok, path}
    end
  end

  @impl Sugary.BenchmarkAdapter
  def fetch(_opts), do: fetch_local_only()

  def list_cases(limit \\ 3)

  @impl Sugary.BenchmarkAdapter
  def list_cases(opts) when is_list(opts) do
    limit = opts |> Keyword.get(:limit) |> default_limit()
    offset = opts |> Keyword.get(:offset, 0) |> default_offset()
    list_cases(limit, offset)
  end

  def list_cases(limit) when is_integer(limit), do: list_cases(limit, 0)

  def list_cases(limit, offset) when is_integer(limit) and is_integer(offset) do
    with {:ok, path} <- fetch_local_only() do
      {:ok, load_martian_cases(path, limit, offset)}
    end
  end

  defp default_limit(nil), do: 3
  defp default_limit(""), do: 3
  defp default_limit(limit), do: limit
  defp default_offset(nil), do: 0
  defp default_offset(""), do: 0
  defp default_offset(offset), do: offset

  defp load_martian_cases(path, limit, offset) do
    benchmark_data = Path.join([path, "offline", "results", "benchmark_data.json"])
    sugary_cases = Path.join([path, "offline", "sugary_cases", "*.json"]) |> Path.wildcard()

    cond do
      File.exists?(benchmark_data) ->
        benchmark_data
        |> Sugary.Json.read!()
        |> Enum.sort_by(fn {url, _case} -> url end)
        |> Enum.drop(offset)
        |> Enum.take(limit)
        |> Enum.with_index(offset + 1)
        |> Enum.map(fn {{url, raw_case}, index} ->
          raw_case
          |> normalize_martian_record(url, path)
          |> Sugary.Json.encode!()
          |> then(
            &Sugary.PublicBenchmarks.normalize_case(
              "martian-offline",
              benchmark_data,
              &1,
              path,
              index
            )
          )
        end)

      sugary_cases != [] ->
        Sugary.PublicBenchmarks.normalize_files(
          sugary_cases,
          "martian-offline",
          path,
          limit,
          offset
        )

      true ->
        path
        |> public_case_files()
        |> Sugary.PublicBenchmarks.normalize_files("martian-offline", path, limit, offset)
    end
  end

  defp normalize_martian_record(raw_case, url, root) do
    pr_title = text_field(raw_case, "pr_title") || "Martian offline smoke case"
    repo = text_field(raw_case, "source_repo") || "unknown"
    diff_url = text_field(raw_case, "original_url") || url
    diff = cached_diff(root, diff_url) || "Martian PR diff not cached locally for #{diff_url}."

    %{
      "id" => url,
      "repo" => repo,
      "pr" => %{
        "title" => pr_title,
        "body" => "Unofficial local Martian offline smoke case.",
        "original_id" => url
      },
      "diff" => diff,
      "changed_files" => changed_files_from_diff(diff),
      "expectedClaims" => expected_claims(raw_case),
      "source_url" => url,
      "metadata" => %{
        "martian_source_repo" => repo,
        "diff_cached" => cached_diff(root, diff_url) != nil
      }
    }
  end

  defp expected_claims(raw_case) do
    raw_case
    |> Map.get("golden_comments", [])
    |> Enum.with_index(1)
    |> Enum.map(fn {comment, index} ->
      body = text_field(comment, "comment") || "Expected Martian benchmark finding"

      %{
        "id" => "martian-golden-#{index}",
        "description" => body,
        "category" => "public_benchmark",
        "severity" => text_field(comment, "severity") || "medium",
        "path" => "unknown",
        "difficulty" => "public",
        "specialist" => "public_benchmark"
      }
    end)
  end

  defp cached_diff(root, url) do
    path = Path.join([root, "offline", "results", "sugary_pr_diffs", "#{hash(url)}.diff"])
    if File.exists?(path), do: File.read!(path)
  end

  defp changed_files_from_diff(diff) do
    ~r/^diff --git a\/(.+?) b\/(.+)$/m
    |> Regex.scan(diff)
    |> Enum.map(fn [_line, _old, new] -> new end)
    |> Enum.uniq()
  end

  defp hash(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp text_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      _other -> nil
    end
  end

  defp text_field(_map, _key), do: nil

  defp public_case_files(path) do
    root_cases = path |> Path.join("*.json") |> Path.wildcard()
    golden_cases = path |> Path.join("offline/golden_comments/*.json") |> Path.wildcard()

    (root_cases ++ golden_cases)
    |> Enum.filter(&File.regular?/1)
    |> Enum.reject(&hidden_or_generated?/1)
    |> Enum.sort()
  end

  defp hidden_or_generated?(path) do
    basename = Path.basename(path)
    ext = Path.extname(path)

    String.starts_with?(basename, ".") or
      String.contains?(path, "/.git/") or
      ext in [".png", ".jpg", ".jpeg", ".gif", ".zip", ".tar", ".gz"]
  end
end

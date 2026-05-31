defmodule Sugary.AACRBench do
  @behaviour Sugary.BenchmarkAdapter

  @candidates [
    ".sugary/research/benchmarks/aacr-bench",
    "benchmarks/aacr-bench",
    "vendor/aacr-bench"
  ]

  def locate do
    env = System.get_env("AACR_BENCH_DIR")

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
         "AACR-Bench data not found. Set AACR_BENCH_DIR or place it at .sugary/research/benchmarks/aacr-bench. No API key is required; no network fetch is attempted by fetch."}

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
    with {:ok, path} <- fetch_local_only(),
         {:ok, positives} <- read_samples(path, "positive_samples.json") do
      negatives =
        case read_samples(path, "negative_samples.json") do
          {:ok, samples} -> samples
          {:error, _message} -> []
        end

      negative_by_url =
        negatives
        |> Enum.group_by(&text_field(&1, "githubPrUrl"))

      cases =
        positives
        |> Enum.sort_by(&(text_field(&1, "githubPrUrl") || ""))
        |> Enum.drop(offset)
        |> Enum.take(limit)
        |> Enum.with_index(offset + 1)
        |> Enum.map(fn {sample, index} ->
          sample
          |> normalize_sample(
            path,
            Map.get(negative_by_url, text_field(sample, "githubPrUrl"), [])
          )
          |> Sugary.Json.encode!()
          |> then(
            &Sugary.PublicBenchmarks.normalize_case(
              "aacr-bench",
              dataset_path(path),
              &1,
              path,
              index
            )
          )
        end)

      {:ok, cases}
    end
  end

  defp read_samples(path, filename) do
    sample_path = Path.join([path, "dataset", filename])

    if File.exists?(sample_path) do
      {:ok, Sugary.Json.read!(sample_path)}
    else
      {:error, "AACR-Bench #{filename} not found under #{Path.join(path, "dataset")}"}
    end
  end

  defp default_limit(nil), do: 3
  defp default_limit(""), do: 3
  defp default_limit(limit), do: limit
  defp default_offset(nil), do: 0
  defp default_offset(""), do: 0
  defp default_offset(offset), do: offset

  defp normalize_sample(sample, root, negative_samples) do
    url = text_field(sample, "githubPrUrl") || "unknown"
    repo = repo_from_url(url)
    diff = text_field(sample, "diff") || cached_or_fetch_diff(root, url)
    comments = comments(sample)
    non_issue_comments = Enum.flat_map(negative_samples, &comments/1)

    %{
      "id" => url,
      "repo" => repo,
      "pr" => %{
        "title" => "AACR-Bench smoke case for #{repo}",
        "body" => "Unofficial local AACR-Bench smoke case. Reference comments are scorer-only.",
        "original_id" => url
      },
      "diff" => diff || "AACR PR diff unavailable for #{url}.",
      "changed_files" => changed_files(diff, comments ++ non_issue_comments),
      "expectedClaims" => expected_claims(comments),
      "knownNonIssues" => known_non_issues(non_issue_comments),
      "source_url" => url,
      "metadata" => %{
        "github_pr_url" => url,
        "project_main_language" => text_field(sample, "project_main_language"),
        "source_commit" => text_field(sample, "source_commit"),
        "target_commit" => text_field(sample, "target_commit"),
        "change_line_count" => int_field(sample, "change_line_count"),
        "diff_cached_or_fetched" => diff_available?(diff),
        "positive_comment_count" => length(comments),
        "negative_comment_count" => length(non_issue_comments)
      }
    }
  end

  defp expected_claims(comments) do
    comments
    |> Enum.with_index(1)
    |> Enum.map(fn {comment, index} ->
      category = text_field(comment, "category") || "public_benchmark"
      context = text_field(comment, "context") || "unknown"

      %{
        "id" => "aacr-positive-#{index}-#{hash(comment_identity(comment))}",
        "description" => text_field(comment, "note") || "Expected AACR-Bench finding",
        "category" => category,
        "severity" => severity(category),
        "path" => text_field(comment, "path") || "unknown",
        "line" => int_field(comment, "from_line") || int_field(comment, "to_line") || 1,
        "difficulty" => difficulty(context),
        "specialist" => specialist(category),
        "required_context" => [context]
      }
    end)
  end

  defp known_non_issues(comments) do
    comments
    |> Enum.with_index(1)
    |> Enum.map(fn {comment, index} ->
      %{
        "id" => "aacr-negative-#{index}-#{hash(comment_identity(comment))}",
        "description" => text_field(comment, "note") || "AACR negative reference comment",
        "trapCategory" => "aacr_negative_reference",
        "path" => text_field(comment, "path") || "unknown",
        "line" => int_field(comment, "from_line") || int_field(comment, "to_line") || 1
      }
    end)
  end

  defp comments(sample) when is_map(sample) do
    case Map.get(sample, "comments") do
      list when is_list(list) -> list
      _other -> []
    end
  end

  defp comments(_sample), do: []

  defp cached_or_fetch_diff(root, url) do
    cache_path = diff_cache_path(root, url)

    cond do
      File.exists?(cache_path) ->
        File.read!(cache_path)

      String.starts_with?(url, "https://github.com/") ->
        fetch_diff(root, url, cache_path)

      true ->
        nil
    end
  end

  defp fetch_diff(root, url, cache_path) do
    File.mkdir_p!(Path.dirname(cache_path))

    case System.cmd("curl", ["-L", "--max-time", "30", "-sS", "#{url}.diff"],
           stderr_to_stdout: true
         ) do
      {body, 0} ->
        if String.contains?(body, "diff --git") do
          File.write!(cache_path, body)
          body
        end

      _other ->
        nil
    end
  rescue
    _error -> nil
  after
    File.mkdir_p!(Path.join([root, "dataset", "diff-cache"]))
  end

  defp diff_cache_path(root, url),
    do: Path.join([root, "dataset", "diff-cache", "#{hash(url)}.diff"])

  defp dataset_path(root), do: Path.join([root, "dataset", "positive_samples.json"])

  defp changed_files(diff, comments) do
    diff_files =
      if is_binary(diff) do
        ~r/^diff --git a\/(.+?) b\/(.+)$/m
        |> Regex.scan(diff)
        |> Enum.map(fn [_line, _old, new] -> new end)
      else
        []
      end

    comment_files =
      comments
      |> Enum.map(&text_field(&1, "path"))
      |> Enum.reject(&is_nil/1)

    (diff_files ++ comment_files)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp diff_available?(diff), do: is_binary(diff) and String.contains?(diff, "diff --git")

  defp repo_from_url("https://github.com/" <> rest) do
    rest
    |> String.split("/")
    |> Enum.take(2)
    |> Enum.join("/")
  end

  defp repo_from_url(_url), do: "unknown"

  defp severity("Security Vulnerability"), do: "high"
  defp severity("Code Defect"), do: "high"
  defp severity("Performance"), do: "medium"
  defp severity("Maintainability and Readability"), do: "low"
  defp severity(_category), do: "medium"

  defp specialist("Security Vulnerability"), do: "security"
  defp specialist("Performance"), do: "performance"
  defp specialist("Maintainability and Readability"), do: "maintainability"
  defp specialist("Code Defect"), do: "defect"
  defp specialist(_category), do: "public_benchmark"

  defp difficulty("Repo Level"), do: "hard"
  defp difficulty("File Level"), do: "medium"
  defp difficulty("Diff Level"), do: "public"
  defp difficulty(_context), do: "unknown"

  defp comment_identity(comment) do
    [
      text_field(comment, "path"),
      int_field(comment, "from_line"),
      int_field(comment, "to_line"),
      text_field(comment, "note")
    ]
    |> Enum.join(":")
  end

  defp text_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_binary(value) and value != "" -> value
      value when is_integer(value) -> to_string(value)
      _other -> nil
    end
  end

  defp text_field(_map, _key), do: nil

  defp int_field(map, key) when is_map(map) do
    case Map.get(map, key) do
      value when is_integer(value) ->
        value

      value when is_binary(value) ->
        case Integer.parse(value) do
          {number, _rest} -> number
          :error -> nil
        end

      _other ->
        nil
    end
  end

  defp int_field(_map, _key), do: nil

  defp hash(value), do: :crypto.hash(:sha256, to_string(value)) |> Base.encode16(case: :lower)
end

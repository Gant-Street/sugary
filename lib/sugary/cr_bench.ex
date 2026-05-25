defmodule Sugary.CRBench do
  @behaviour Sugary.BenchmarkAdapter

  @candidates [
    ".sugary/research/benchmarks/cr-bench",
    "benchmarks/cr-bench",
    "vendor/cr-bench"
  ]

  def locate do
    env = System.get_env("CR_BENCH_DIR")

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
         "CR-Bench data not found. Set CR_BENCH_DIR or place it at .sugary/research/benchmarks/cr-bench. No network fetch is attempted in local-only mode."}

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
      cases =
        path
        |> public_case_files()
        |> Sugary.PublicBenchmarks.normalize_files("cr-bench", path, limit, offset)

      {:ok, cases}
    end
  end

  defp default_limit(nil), do: 3
  defp default_limit(""), do: 3
  defp default_limit(limit), do: limit
  defp default_offset(nil), do: 0
  defp default_offset(""), do: 0
  defp default_offset(offset), do: offset

  defp public_case_files(path) do
    path
    |> Path.join("**/*")
    |> Path.wildcard()
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

defmodule Sugary.Martian do
  @behaviour Sugary.BenchmarkAdapter

  @candidates [
    ".sugary/research/benchmarks/martian-offline",
    "benchmarks/martian-offline",
    "vendor/martian-offline"
  ]

  def locate do
    env = System.get_env("MARTIAN_BENCH_DIR")
    candidates = Enum.reject([env | @candidates], &is_nil/1)
    Enum.find(candidates, &File.dir?/1)
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
    opts |> Keyword.get(:limit, 3) |> list_cases()
  end

  def list_cases(limit) when is_integer(limit) do
    with {:ok, path} <- fetch_local_only() do
      cases =
        path
        |> public_case_files()
        |> Sugary.PublicBenchmarks.normalize_files("martian-offline", path, limit)

      {:ok, cases}
    end
  end

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

args = System.argv()

get_opt = fn name, default ->
  case Enum.find_index(args, &(&1 == name)) do
    nil -> default
    index -> Enum.at(args, index + 1) || default
  end
end

limit = get_opt.("--limit", "5") |> String.to_integer()
root = get_opt.("--root", ".sugary/research/benchmarks/martian-offline")
benchmark_data = Path.join([root, "offline", "results", "benchmark_data.json"])
out_dir = Path.join([root, "offline", "results", "sugary_pr_diffs"])
manifest_path = Path.join(out_dir, "manifest.json")

unless File.exists?(benchmark_data) do
  raise "Martian benchmark_data.json not found at #{benchmark_data}"
end

File.mkdir_p!(out_dir)

hash = fn value ->
  :crypto.hash(:sha256, value)
  |> Base.encode16(case: :lower)
end

entries =
  benchmark_data
  |> File.read!()
  |> :json.decode()
  |> Enum.sort_by(fn {url, _case} -> url end)
  |> Enum.take(limit)

results =
  Enum.map(entries, fn {url, record} ->
    source_url = Map.get(record, "original_url") || url
    diff_url = source_url <> ".diff"
    out_path = Path.join(out_dir, "#{hash.(source_url)}.diff")

    cond do
      File.exists?(out_path) and File.stat!(out_path).size > 0 ->
        %{url: source_url, status: "cached", path: out_path, bytes: File.stat!(out_path).size}

      true ->
        IO.puts("fetching #{diff_url}")

        case System.cmd(
               "curl",
               ["-fsSL", "--max-time", "45", "-H", "User-Agent: sugary-benchmark-smoke", diff_url],
               stderr_to_stdout: true
             ) do
          {body, 0} ->
            File.write!(out_path, body)
            %{url: source_url, status: "fetched", path: out_path, bytes: byte_size(body)}

          {body, status} ->
            %{
              url: source_url,
              status: "failed",
              path: out_path,
              exit_status: status,
              error_preview: String.slice(body, 0, 500)
            }
        end
    end
  end)

File.write!(
  manifest_path,
  :json.encode(%{
    generated_at: DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ"),
    source: benchmark_data,
    limit: limit,
    results: results
  })
)

ok = Enum.count(results, &(&1.status in ["cached", "fetched"]))
failed = Enum.count(results, &(&1.status == "failed"))

IO.puts("Martian diff cache: #{ok} ready, #{failed} failed")
IO.puts(manifest_path)

defmodule Sugary.CLI do
  def main(args) do
    args
    |> dispatch()
    |> handle_result()
  rescue
    error ->
      IO.puts(:stderr, Exception.message(error))
      System.halt(1)
  end

  defp dispatch(["research", "init"]) do
    Sugary.Runner.init_research!()
    {:ok, "initialized .sugary/research"}
  end

  defp dispatch(["bench", "public", "list"]) do
    {:ok, Sugary.PublicBenchmarks.list() |> Sugary.PublicBenchmarks.render_list()}
  end

  defp dispatch(["bench", "list" | rest]) do
    opts = parse_opts(rest)

    case Map.get(opts, "suite") do
      nil ->
        public =
          Sugary.PublicBenchmarks.list()
          |> Enum.map(&%{id: &1.benchmark, cases: "unknown", source: &1.status})

        {:ok, Sugary.Json.encode!(Sugary.Fixtures.list_suites() ++ public)}

      suite when suite in ["martian-offline", "cr-bench"] ->
        limit = opts |> Map.get("limit", "3") |> parse_int()
        {:ok, Sugary.Json.encode!(Sugary.PublicBenchmarks.inspect_cases(suite, limit: limit))}

      suite ->
        {:ok, Sugary.Json.encode!(Sugary.Fixtures.load_suite!(suite))}
    end
  end

  defp dispatch(["bench", "inspect" | rest]) do
    opts = parse_opts(rest)
    suite = Map.fetch!(opts, "suite")
    limit = opts |> Map.get("limit", "3") |> parse_int()

    {:ok, Sugary.Json.encode!(Sugary.PublicBenchmarks.inspect_cases(suite, limit: limit))}
  end

  defp dispatch(["bench", "fetch", suite | rest]) when suite in ["martian-offline", "cr-bench"] do
    _opts = parse_opts(rest)

    case Sugary.PublicBenchmarks.fetch(suite, local_only: true) do
      {:ok, path} -> {:ok, "#{suite} located at #{path}"}
      {:error, message} -> {:error, message}
    end
  end

  defp dispatch(["bench", "run" | rest]) do
    opts = parse_opts(rest)
    suite = Map.fetch!(opts, "suite")
    method = Map.fetch!(opts, "method")
    limit = opts |> Map.get("limit", "3") |> parse_int()
    offset = opts |> Map.get("offset", "0") |> parse_int()
    split = Map.get(opts, "split")
    run_dir = Sugary.Runner.run_bench!(suite, method, limit: limit, offset: offset, split: split)
    {:ok, run_dir}
  end

  defp dispatch(["bench", "compare" | rest]) do
    opts = parse_opts_multi(rest)
    runs = Map.get(opts, "run", [])

    if runs == [] do
      {:error, "bench compare requires at least one --run <path>"}
    else
      {:ok, runs |> Sugary.PublicBenchmarks.compare() |> Sugary.PublicBenchmarks.render_compare()}
    end
  end

  defp dispatch(["experiment", "run", path | rest]) do
    opts = parse_opts(rest)
    manifest = Sugary.Toml.parse_file!(path)
    replay_mode = Map.get(opts, "replay-mode")

    manifest =
      if replay_mode in [nil, ""] do
        manifest
      else
        %{manifest | replay_mode: replay_mode}
      end

    {:ok, Sugary.Runner.run_experiment_manifest!(manifest)}
  end

  defp dispatch(["experiment", "report", run_dir]) do
    {:ok, Sugary.Runner.report!(run_dir)}
  end

  defp dispatch(["campaign", "run", path | rest]) do
    opts = parse_opts(rest)

    run_opts =
      []
      |> put_opt(:resume, Map.get(opts, "resume") == true)
      |> put_opt(:dry_run, Map.get(opts, "dry-run") == true)
      |> put_opt(:limit_experiments, parse_optional_int(Map.get(opts, "limit-experiments")))
      |> put_opt(:replay_mode, Map.get(opts, "replay-mode"))

    {:ok, Sugary.Campaign.run!(path, run_opts)}
  end

  defp dispatch(["tool", "gauntlet" | rest]) do
    opts = parse_opts(rest)

    capabilities =
      opts
      |> Map.get("tools")
      |> parse_csv()

    run_opts =
      [
        source_run: Map.fetch!(opts, "source-run"),
        method_id: Map.fetch!(opts, "method"),
        baseline_id: Map.fetch!(opts, "baseline"),
        suite: Map.get(opts, "suite", "martian-offline"),
        split: Map.get(opts, "split"),
        limit: opts |> Map.get("limit", "25") |> parse_int(),
        offset: opts |> Map.get("offset", "0") |> parse_int(),
        id: Map.get(opts, "id", "tool-gauntlet-v0"),
        max_published: opts |> Map.get("max-published", "2") |> parse_int(),
        min_score: opts |> Map.get("min-score", "2.0") |> parse_float()
      ]

    run_opts =
      if capabilities == [] do
        run_opts
      else
        Keyword.put(run_opts, :capabilities, capabilities)
      end

    {:ok, Sugary.ToolGauntlet.run!(run_opts)}
  end

  defp dispatch(["architecture", "gauntlet", path | rest]) do
    opts = parse_opts(rest)

    run_opts =
      []
      |> put_opt(:replay_mode, Map.get(opts, "replay-mode"))

    {:ok, Sugary.ArchitectureGauntlet.run!(path, run_opts)}
  end

  defp dispatch(["scientific", "pilot" | rest]) do
    opts = parse_opts_multi(rest)
    {:ok, Sugary.ScientificPilot.run!(opts)}
  end

  defp dispatch(["pcrs", "ensemble", "publisher" | rest]) do
    opts = parse_opts(rest)
    {:ok, Sugary.PCRSEnsemblePublisher.run!(opts)}
  end

  defp dispatch(["repo", "materialize" | rest]) do
    opts = parse_opts(rest)

    run_dir =
      Sugary.RepoMaterializer.run!(
        suite: Map.get(opts, "suite", "martian-offline"),
        split: Map.get(opts, "split"),
        limit: opts |> Map.get("limit", "30") |> parse_int(),
        offset: opts |> Map.get("offset", "0") |> parse_int(),
        mode: Map.get(opts, "mode", "plan"),
        id: Map.get(opts, "id", "repo-materialization-v0")
      )

    {:ok, run_dir}
  end

  defp dispatch(["martian", "parity", "export" | rest]) do
    opts = parse_opts(rest)
    {:ok, Sugary.MartianParity.export!(opts)}
  end

  defp dispatch(["martian", "no-key", "report" | rest]) do
    opts = parse_opts(rest)
    {:ok, Sugary.MartianNoKey.report!(opts)}
  end

  defp dispatch(["team", "search" | rest]) do
    opts = parse_opts(rest)
    pack = Map.fetch!(opts, "pack")
    suite = Map.get(opts, "suite", "agent-written-fixtures")
    split = Map.get(opts, "split")
    max_team_size = opts |> Map.get("max-team-size", "3") |> parse_int()
    {:ok, Sugary.TeamSearch.run!(pack, suite, max_team_size: max_team_size, split: split)}
  end

  defp dispatch(["promotion", "lock" | rest]) do
    opts = parse_opts_multi(rest)
    {:ok, Sugary.Promotion.lock!(opts)}
  end

  defp dispatch(["promotion", "run", lock_path | rest]) do
    opts = parse_opts(rest)
    split = Map.get(opts, "split", "holdout")
    {:ok, Sugary.Promotion.run!(lock_path, split: split)}
  end

  defp dispatch(["reviewers", "check" | rest]) do
    opts = parse_opts(rest)
    pack = Map.fetch!(opts, "pack")

    {:ok,
     pack |> Sugary.ExternalReviewers.check_pack!() |> Sugary.ExternalReviewers.render_check()}
  end

  defp dispatch(_args) do
    {:error,
     "usage: sugary research init | sugary bench public list | sugary bench list [--suite <suite>] | sugary bench inspect --suite <suite> --limit <n> | sugary bench fetch <martian-offline|cr-bench> --local-only | sugary bench run --suite <suite> --method <id> | sugary bench compare --run <dir> [--run <dir>] | sugary experiment run <manifest> [--replay-mode <mode>] | sugary experiment report <run-dir> | sugary campaign run <manifest> [--resume] [--dry-run] [--limit-experiments <n>] [--replay-mode <mode>] | sugary tool gauntlet --source-run <dir> --method <id> --baseline <id> [--tools a,b] | sugary architecture gauntlet <manifest> [--replay-mode <mode>] | sugary scientific pilot --candidate <id|team.toml> --baseline <id|team.toml> [--experiment <manifest>] [--limit <n>] | sugary pcrs ensemble publisher [--limit <n>] | sugary repo materialize --suite <suite> [--mode plan|metadata|fetch] [--limit <n>] | sugary martian parity export --source-run <dir> --method <id> [--policy team-ev-max-2] | sugary martian no-key report [--sugary-tool <tool>] | sugary team search --pack <pack> --suite <suite> --max-team-size <n> | sugary reviewers check --pack <pack> | sugary promotion lock --candidate <path> --suite <suite> --dev-run <run-dir> --out <path> [--baseline-method <id>] [--baseline-team <path>] | sugary promotion run <lock> --split holdout"}
  end

  defp handle_result({:ok, message}) do
    IO.puts(message)
  end

  defp handle_result({:error, message}) do
    IO.puts(:stderr, message)
    System.halt(1)
  end

  defp parse_opts(args), do: parse_opts(args, %{})

  defp parse_opts([], acc), do: acc

  defp parse_opts(["--local-only" | rest], acc),
    do: parse_opts(rest, Map.put(acc, "local-only", true))

  defp parse_opts(["--resume" | rest], acc),
    do: parse_opts(rest, Map.put(acc, "resume", true))

  defp parse_opts(["--dry-run" | rest], acc),
    do: parse_opts(rest, Map.put(acc, "dry-run", true))

  defp parse_opts(["--" <> key, value | rest], acc),
    do: parse_opts(rest, Map.put(acc, key, value))

  defp parse_opts([_unknown | rest], acc), do: parse_opts(rest, acc)

  defp parse_opts_multi(args), do: parse_opts_multi(args, %{})

  defp parse_opts_multi([], acc), do: acc

  defp parse_opts_multi(["--local-only" | rest], acc),
    do: parse_opts_multi(rest, Map.put(acc, "local-only", true))

  defp parse_opts_multi(["--" <> key, value | rest], acc)
       when key in ["baseline", "baseline-method", "baseline-team", "run"] do
    parse_opts_multi(rest, Map.update(acc, key, [value], &(&1 ++ [value])))
  end

  defp parse_opts_multi(["--" <> key, value | rest], acc),
    do: parse_opts_multi(rest, Map.put(acc, key, value))

  defp parse_opts_multi([_unknown | rest], acc), do: parse_opts_multi(rest, acc)

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value), do: value |> to_string() |> Integer.parse() |> elem(0)

  defp parse_float(value) when is_float(value), do: value
  defp parse_float(value) when is_integer(value), do: value * 1.0

  defp parse_float(value) do
    case Float.parse(to_string(value)) do
      {number, ""} -> number
      _ -> raise ArgumentError, "invalid float #{inspect(value)}"
    end
  end

  defp parse_csv(nil), do: []

  defp parse_csv(value) do
    value
    |> to_string()
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_optional_int(nil), do: nil
  defp parse_optional_int(value), do: parse_int(value)

  defp put_opt(opts, _key, nil), do: opts
  defp put_opt(opts, _key, false), do: opts
  defp put_opt(opts, key, value), do: Keyword.put(opts, key, value)
end

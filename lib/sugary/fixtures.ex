defmodule Sugary.Fixtures do
  alias Sugary.Protocol.{BenchmarkCase, ReviewInputBundle}

  @fixture_root "fixtures/review"
  @suite_root "fixtures/suites"

  def list_suites do
    cases = load_all()

    cases
    |> Enum.group_by(& &1.suite)
    |> Enum.map(fn {suite, values} -> %{id: suite, cases: length(values), source: "fixtures"} end)
    |> Enum.sort_by(& &1.id)
  end

  def load_suite!("local-fixtures") do
    load_all()
    |> Enum.filter(&(&1.suite == "local-fixtures"))
  end

  def load_suite!("agent-written-pr") do
    load_all()
    |> Enum.filter(&(&1.suite == "agent-written-pr"))
  end

  def load_suite!("agent-written-fixtures"), do: load_suite!("agent-written-pr")

  def load_suite!("agent-written-hard-fixtures"),
    do: load_split!("agent-written-hard-fixtures", nil)

  def load_suite!(suite) do
    raise ArgumentError, "unknown local fixture suite #{inspect(suite)}"
  end

  def load_suite!(suite, opts) do
    split = Keyword.get(opts, :split)

    case suite do
      "agent-written-hard-fixtures" -> load_split!(suite, split)
      _suite when split in [nil, ""] -> load_suite!(suite)
      _suite -> load_suite!(suite) |> Enum.filter(&(&1.split == split))
    end
  end

  def suite_manifest!(suite) do
    path = Path.join([@suite_root, "#{suite}.toml"])

    if File.exists?(path) do
      path |> Sugary.Toml.parse_file_raw!() |> atomize()
    else
      raise ArgumentError, "suite manifest not found for #{suite}"
    end
  end

  def load_all(root \\ @fixture_root) do
    root
    |> Path.join("**/case.json")
    |> Path.wildcard()
    |> Enum.map(&load_case!/1)
    |> Enum.sort_by(& &1.id)
  end

  def load_case!(path) do
    path
    |> Sugary.Json.read!()
    |> atomize()
    |> BenchmarkCase.new()
  end

  def input_bundle(%BenchmarkCase{} = bench_case, method) do
    blind? = bench_case.split == "holdout" or public_benchmark?(bench_case)
    metadata = input_metadata(bench_case, method, blind?)

    ReviewInputBundle.new(%{
      case_id: if(blind?, do: blind_case_id(bench_case.id), else: bench_case.id),
      suite: if(blind?, do: "blind", else: bench_case.suite),
      pr: if(blind?, do: sanitize_blind_pr(bench_case.pr), else: bench_case.pr),
      diff: bench_case.diff,
      context:
        if(blind?,
          do: sanitize_blind_context(bench_case.context),
          else: Map.get(bench_case.context || %{}, :allowed, %{})
        ),
      method: sanitize_method(method),
      metadata: metadata
    })
  end

  defp public_benchmark?(bench_case) do
    bench_case.public_benchmark == true or Sugary.PublicBenchmarks.public_suite?(bench_case.suite)
  end

  defp input_metadata(bench_case, method, blind?) do
    base =
      if blind? do
        blind_metadata(bench_case)
      else
        %{tags: bench_case.tags || [], split: bench_case.split}
      end

    case workspace_metadata(bench_case, method) do
      nil -> base
      workspace -> Map.put(base, :workspace, workspace)
    end
  end

  defp workspace_metadata(bench_case, method) do
    if Map.get(method, :include_workspace) == true do
      workspace =
        bench_case.repo
        |> case do
          %{workspace: value} -> value
          %{"workspace" => value} -> value
          _other -> nil
        end

      case workspace do
        %{head: head, base: base} -> valid_workspace(head, base)
        %{"head" => head, "base" => base} -> valid_workspace(head, base)
        _other -> nil
      end
    end
  end

  defp valid_workspace(head, base) do
    head = Path.expand(to_string(head))
    base = Path.expand(to_string(base))

    if File.dir?(head) and File.dir?(base) do
      blind_workspace(head, base)
    end
  end

  defp blind_workspace(head, base) do
    root =
      Path.join([
        ".sugary/research/blind-workspaces",
        :crypto.hash(:sha256, head <> "\n" <> base) |> Base.encode16(case: :lower)
      ])

    blind_head = Path.join(root, "head")
    blind_base = Path.join(root, "base")

    ensure_symlink!(head, blind_head)
    ensure_symlink!(base, blind_base)

    %{head: Path.expand(blind_head), base: Path.expand(blind_base)}
  end

  defp ensure_symlink!(target, link) do
    File.mkdir_p!(Path.dirname(link))

    cond do
      File.lstat(link) == {:ok, %{type: :symlink}} ->
        :ok

      File.exists?(link) ->
        File.rm_rf!(link)
        File.ln_s!(target, link)

      true ->
        File.ln_s!(target, link)
    end
  end

  defp blind_metadata(bench_case) do
    metadata = %{holdout: bench_case.split == "holdout"}

    if public_benchmark?(bench_case) do
      Map.put(metadata, :public_benchmark, true)
    else
      metadata
    end
  end

  defp sanitize_blind_pr(pr) when is_map(pr) do
    pr
    |> Map.drop([:original_id, "original_id", :case_id, "case_id", :id, "id"])
  end

  defp sanitize_blind_pr(pr), do: pr

  defp sanitize_blind_context(context) do
    context
    |> allowed_context()
    |> Map.drop([:benchmark, "benchmark", :suite, "suite", :split, "split"])
  end

  defp allowed_context(context) when is_map(context),
    do: Map.get(context, :allowed) || Map.get(context, "allowed") || %{}

  defp allowed_context(_context), do: %{}

  defp load_split!(suite, nil) do
    load_all()
    |> Enum.filter(&(&1.suite == suite))
  end

  defp load_split!(suite, split) do
    cases = load_split!(suite, nil)
    manifest = suite_manifest!(suite)

    selected =
      manifest
      |> get_in([:split, String.to_atom(split), :cases])

    cond do
      is_list(selected) ->
        selected_set = MapSet.new(selected)
        Enum.filter(cases, &MapSet.member?(selected_set, &1.id))

      split in ["train", "dev", "holdout"] ->
        Enum.filter(cases, &(&1.split == split))

      true ->
        []
    end
  end

  defp blind_case_id(id), do: "holdout-case-#{:erlang.phash2(id, 100_000)}"

  defp sanitize_method(method) do
    Map.drop(method, [
      :uses_oracle,
      "uses_oracle",
      :replay_mode,
      "replay_mode",
      :env,
      "env"
    ])
  end

  defp atomize(%{} = map),
    do: Map.new(map, fn {key, value} -> {atom_key(key), atomize(value)} end)

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value

  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)
end

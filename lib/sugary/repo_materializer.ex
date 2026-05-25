defmodule Sugary.RepoMaterializer do
  @root ".sugary/research/repo-materializations"
  @repo_cache ".sugary/research/repo-cache"
  @workspace_root ".sugary/research/workspaces"
  @version "repo-materializer-v0"

  def run!(opts) do
    suite = Keyword.get(opts, :suite, "martian-offline")
    limit = Keyword.get(opts, :limit, 30)
    offset = Keyword.get(opts, :offset, 0)
    split = Keyword.get(opts, :split)
    mode = Keyword.get(opts, :mode, "plan")
    id = Keyword.get(opts, :id, "repo-materialization-v0")

    unless mode in ["plan", "metadata", "fetch"] do
      raise ArgumentError, "repo materialization mode must be plan, metadata, or fetch"
    end

    cases = load_cases!(suite, limit: limit, offset: offset, split: split)
    out_dir = make_run_dir(id)
    File.mkdir_p!(out_dir)

    config = %{
      version: @version,
      suite: suite,
      split: split,
      limit: limit,
      offset: offset,
      mode: mode,
      repo_cache: @repo_cache,
      workspace_root: @workspace_root
    }

    records = Enum.map(cases, &materialize_case(&1, mode))
    summary = summarize(records)

    Sugary.Json.write!(Path.join(out_dir, "config.json"), config)
    Sugary.Json.write!(Path.join(out_dir, "summary.json"), summary)
    write_jsonl!(Path.join(out_dir, "repo-context.jsonl"), records)

    records
    |> Enum.each(fn record ->
      Sugary.Json.write!(Path.join([out_dir, "cases", "#{safe_id(record.case_id)}.json"]), record)
    end)

    File.write!(
      Path.join(out_dir, "repo-materialization-report.md"),
      render_report(config, summary, records)
    )

    out_dir
  end

  def parse_github_url(url) when is_binary(url) do
    uri = URI.parse(url)
    path = uri.path || ""

    cond do
      uri.host not in ["github.com", "www.github.com"] ->
        {:error, :not_github}

      match = Regex.run(~r|^/([^/]+)/([^/]+)/pull/(\d+)|, path) ->
        [_all, owner, repo, number] = match

        {:ok,
         %{
           type: "pull_request",
           owner: owner,
           repo: repo,
           repo_full_name: "#{owner}/#{repo}",
           number: String.to_integer(number),
           url: canonical_url(owner, repo, "pull", number),
           clone_url: clone_url(owner, repo)
         }}

      match = Regex.run(~r|^/([^/]+)/([^/]+)/commit/([a-fA-F0-9]{7,40})|, path) ->
        [_all, owner, repo, sha] = match

        {:ok,
         %{
           type: "commit",
           owner: owner,
           repo: repo,
           repo_full_name: "#{owner}/#{repo}",
           head_sha: String.downcase(sha),
           url: canonical_url(owner, repo, "commit", sha),
           clone_url: clone_url(owner, repo)
         }}

      true ->
        {:error, :unsupported_github_url}
    end
  end

  def parse_github_url(_url), do: {:error, :missing_url}

  defp materialize_case(bench_case, mode) do
    urls = candidate_urls(bench_case)
    parsed = Enum.find_value(urls, &parseable_url/1)
    changed_files = changed_files(bench_case)

    base = %{
      case_id: bench_case.id,
      suite: bench_case.suite,
      mode: mode,
      source_urls: urls,
      changed_files: changed_files,
      changed_files_count: length(changed_files),
      workspace: workspace_paths(bench_case.id),
      status: "unavailable",
      reason: nil,
      target: nil,
      refs: %{},
      diff_parity: "unavailable",
      tool_availability: %{
        list_changed_files: changed_files != [],
        read_changed_file: false,
        read_base_file: false,
        rg_head: false,
        rg_base: false
      }
    }

    case parsed do
      nil ->
        %{base | status: "unsupported", reason: "No supported GitHub PR or commit URL was found."}

      target ->
        record =
          base
          |> Map.put(:target, target)
          |> Map.put(:status, "planned")
          |> Map.put(:reason, nil)

        case mode do
          "plan" -> record
          "metadata" -> resolve_metadata(record)
          "fetch" -> record |> resolve_metadata() |> fetch_workspace()
        end
    end
  end

  defp parseable_url(url) do
    case parse_github_url(url) do
      {:ok, target} -> target
      {:error, _reason} -> nil
    end
  end

  defp resolve_metadata(%{target: %{type: "pull_request"} = target} = record) do
    case github_json("/repos/#{target.owner}/#{target.repo}/pulls/#{target.number}") do
      {:ok, body} ->
        refs = %{
          base_sha: get_in(body, ["base", "sha"]),
          base_ref: get_in(body, ["base", "ref"]),
          head_sha: get_in(body, ["head", "sha"]),
          head_ref: get_in(body, ["head", "ref"]),
          head_repo_full_name: get_in(body, ["head", "repo", "full_name"]),
          state: body["state"],
          merged: body["merged"]
        }

        record
        |> Map.put(
          :status,
          if(refs.base_sha && refs.head_sha, do: "metadata_resolved", else: "metadata_incomplete")
        )
        |> Map.put(:refs, refs)

      {:error, reason} ->
        %{record | status: "metadata_failed", reason: reason}
    end
  end

  defp resolve_metadata(%{target: %{type: "commit"} = target} = record) do
    case github_json("/repos/#{target.owner}/#{target.repo}/commits/#{target.head_sha}") do
      {:ok, body} ->
        parent = body |> Map.get("parents", []) |> List.first() || %{}

        refs = %{
          base_sha: parent["sha"],
          head_sha: body["sha"] || target.head_sha,
          parent_count: length(Map.get(body, "parents", []))
        }

        record
        |> Map.put(
          :status,
          if(refs.base_sha && refs.head_sha, do: "metadata_resolved", else: "metadata_incomplete")
        )
        |> Map.put(:refs, refs)

      {:error, reason} ->
        %{record | status: "metadata_failed", reason: reason}
    end
  end

  defp fetch_workspace(%{status: status} = record) when status not in ["metadata_resolved"] do
    record
  end

  defp fetch_workspace(record) do
    target = record.target
    refs = record.refs
    repo_dir = repo_cache_path(target)
    workspace = record.workspace

    with :ok <- ensure_bare_repo(repo_dir, target.clone_url),
         :ok <- fetch_ref(repo_dir, refs.base_sha),
         :ok <- fetch_head_ref(repo_dir, target, refs.head_sha),
         :ok <- checkout_tree(repo_dir, refs.base_sha, workspace.base),
         :ok <- checkout_tree(repo_dir, refs.head_sha, workspace.head) do
      parity = diff_parity(repo_dir, refs.base_sha, refs.head_sha, record.changed_files)

      record
      |> Map.put(:status, "workspace_ready")
      |> Map.put(:diff_parity, parity)
      |> Map.put(:repo_cache_path, repo_dir)
      |> Map.put(:tool_availability, %{
        list_changed_files: record.changed_files != [],
        read_changed_file: true,
        read_base_file: true,
        rg_head: true,
        rg_base: true
      })
    else
      {:error, reason} ->
        %{record | status: "fetch_failed", reason: reason, repo_cache_path: repo_dir}
    end
  end

  defp ensure_bare_repo(repo_dir, clone_url) do
    cond do
      File.dir?(Path.join(repo_dir, "objects")) ->
        :ok

      true ->
        File.mkdir_p!(Path.dirname(repo_dir))

        with :ok <- git(["init", "--bare", repo_dir], "git init bare failed"),
             :ok <-
               git(
                 ["--git-dir", repo_dir, "remote", "add", "origin", clone_url],
                 "git remote add failed"
               ),
             :ok <-
               git(
                 ["--git-dir", repo_dir, "config", "remote.origin.promisor", "true"],
                 "git config promisor failed"
               ),
             :ok <-
               git(
                 [
                   "--git-dir",
                   repo_dir,
                   "config",
                   "remote.origin.partialclonefilter",
                   "blob:none"
                 ],
                 "git config partial clone failed"
               ) do
          :ok
        end
    end
  end

  defp fetch_head_ref(repo_dir, %{type: "pull_request", number: number}, sha) do
    case git(
           [
             "--git-dir",
             repo_dir,
             "fetch",
             "--filter=blob:none",
             "origin",
             "+refs/pull/#{number}/head:refs/sugary/pull/#{number}/head"
           ],
           "git fetch PR head failed"
         ) do
      :ok -> :ok
      {:error, _reason} -> fetch_ref(repo_dir, sha)
    end
  end

  defp fetch_head_ref(repo_dir, _target, sha), do: fetch_ref(repo_dir, sha)

  defp fetch_ref(repo_dir, sha) when is_binary(sha) and sha != "" do
    case System.cmd("git", ["--git-dir", repo_dir, "fetch", "--filter=blob:none", "origin", sha],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      {out, status} ->
        {:error, "git fetch #{sha} failed with #{status}: #{String.slice(out, 0, 500)}"}
    end
  end

  defp fetch_ref(_repo_dir, _sha), do: {:error, "missing commit sha"}

  defp git(args, error_prefix) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, "#{error_prefix} with #{status}: #{String.slice(out, 0, 500)}"}
    end
  end

  defp checkout_tree(repo_dir, sha, path) do
    File.rm_rf!(path)
    File.mkdir_p!(path)

    case System.cmd("git", ["--git-dir", repo_dir, "--work-tree", path, "checkout", "-f", sha],
           stderr_to_stdout: true
         ) do
      {_out, 0} ->
        :ok

      {out, status} ->
        {:error, "git checkout #{sha} failed with #{status}: #{String.slice(out, 0, 500)}"}
    end
  end

  defp diff_parity(repo_dir, base_sha, head_sha, benchmark_changed_files) do
    case System.cmd("git", ["--git-dir", repo_dir, "diff", "--name-only", base_sha, head_sha],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        git_files = out |> String.split("\n", trim: true) |> MapSet.new()
        benchmark_files = benchmark_changed_files |> MapSet.new()

        cond do
          MapSet.equal?(git_files, benchmark_files) ->
            "exact"

          MapSet.subset?(benchmark_files, git_files) or MapSet.subset?(git_files, benchmark_files) ->
            "partial"

          true ->
            "mismatch"
        end

      {_out, _status} ->
        "unavailable"
    end
  end

  defp github_json(path) do
    headers = [
      "-H",
      "Accept: application/vnd.github+json",
      "-H",
      "User-Agent: sugary-repo-materializer",
      "-H",
      "X-GitHub-Api-Version: 2022-11-28"
    ]

    auth =
      case System.get_env("GITHUB_TOKEN") do
        token when is_binary(token) and token != "" -> ["-H", "Authorization: Bearer #{token}"]
        _ -> []
      end

    url = "https://api.github.com#{path}"

    case System.cmd("curl", ["-fsSL", "--max-time", "30"] ++ headers ++ auth ++ [url],
           stderr_to_stdout: true
         ) do
      {body, 0} ->
        {:ok, Sugary.Json.decode!(body)}

      {body, status} ->
        {:error, "GitHub API request failed with #{status}: #{String.slice(body, 0, 500)}"}
    end
  end

  defp candidate_urls(bench_case) do
    metadata = bench_case.source_metadata || %{}
    pr = bench_case.pr || %{}
    benchmark_metadata = field(metadata, :benchmark_metadata, %{})

    [
      field(benchmark_metadata, :target_url),
      field(benchmark_metadata, :original_url),
      field(benchmark_metadata, :source_url),
      field(pr, :original_id),
      field(metadata, :original_case_id),
      field(metadata, :case_source_url)
    ]
    |> Enum.filter(&(is_binary(&1) and String.trim(&1) != ""))
    |> Enum.uniq()
  end

  defp changed_files(bench_case) do
    context = bench_case.context || %{}
    allowed = field(context, :allowed, context)
    allowed |> field(:changed_files, []) |> List.wrap() |> Enum.map(&to_string/1)
  end

  defp summarize(records) do
    %{
      version: @version,
      cases: length(records),
      planned: Enum.count(records, &(&1.status == "planned")),
      metadata_resolved: Enum.count(records, &(&1.status == "metadata_resolved")),
      workspace_ready: Enum.count(records, &(&1.status == "workspace_ready")),
      unsupported: Enum.count(records, &(&1.status == "unsupported")),
      failed: Enum.count(records, &(&1.status in ["metadata_failed", "fetch_failed"])),
      exact_diff_parity: Enum.count(records, &(&1.diff_parity == "exact")),
      partial_diff_parity: Enum.count(records, &(&1.diff_parity == "partial")),
      tool_ready_cases: Enum.count(records, & &1.tool_availability.rg_head),
      repos:
        records
        |> Enum.map(&get_in(&1, [:target, :repo_full_name]))
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp render_report(config, summary, records) do
    rows =
      records
      |> Enum.map(fn record ->
        target = record.target || %{}

        "| `#{record.case_id}` | #{Map.get(target, :repo_full_name, "n/a")} | #{Map.get(target, :type, "n/a")} | #{record.status} | #{record.diff_parity} | #{record.changed_files_count} | #{record.reason || ""} |"
      end)
      |> Enum.join("\n")

    """
    # Repo Materialization v0

    This run prepares real repository context for backtesting. It does not run reviewers or claim benchmark performance.

    ## Setup

    - Suite: `#{config.suite}`
    - Mode: `#{config.mode}`
    - Offset: #{config.offset}
    - Limit: #{config.limit}
    - Repo cache: `#{config.repo_cache}`
    - Workspace root: `#{config.workspace_root}`

    ## Summary

    - Cases: #{summary.cases}
    - Planned: #{summary.planned}
    - Metadata resolved: #{summary.metadata_resolved}
    - Workspace ready: #{summary.workspace_ready}
    - Unsupported: #{summary.unsupported}
    - Failed: #{summary.failed}
    - Exact diff parity: #{summary.exact_diff_parity}
    - Partial diff parity: #{summary.partial_diff_parity}
    - Tool-ready cases: #{summary.tool_ready_cases}
    - Repos: #{Enum.map_join(summary.repos, ", ", &"`#{&1}`")}

    ## Cases

    | Case | Repo | Type | Status | Diff parity | Changed files | Reason |
    | --- | --- | --- | --- | --- | ---: | --- |
    #{if rows == "", do: "| none | n/a | n/a | unavailable | unavailable | 0 | no cases |", else: rows}

    ## Interpretation

    `plan` mode only verifies that benchmark records point at supported GitHub PRs or commits. `metadata` mode resolves exact base/head SHAs through the GitHub API. `fetch` mode attempts to create local read-only base/head workspaces and then checks diff parity.
    """
  end

  defp load_cases!(suite, opts) when suite in ["martian-offline", "cr-bench"],
    do: Sugary.PublicBenchmarks.load_cases!(suite, opts)

  defp load_cases!(suite, opts), do: Sugary.Fixtures.load_suite!(suite, opts)

  defp workspace_paths(case_id) do
    root = Path.join(@workspace_root, safe_id(case_id))
    %{root: root, base: Path.join(root, "base"), head: Path.join(root, "head")}
  end

  defp repo_cache_path(target),
    do: Path.join([@repo_cache, "github.com", target.owner, "#{target.repo}.git"])

  defp clone_url(owner, repo), do: "https://github.com/#{owner}/#{repo}.git"

  defp canonical_url(owner, repo, "pull", number),
    do: "https://github.com/#{owner}/#{repo}/pull/#{number}"

  defp canonical_url(owner, repo, "commit", sha),
    do: "https://github.com/#{owner}/#{repo}/commit/#{sha}"

  defp make_run_dir(id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(@root, "#{timestamp}-#{id}")
  end

  defp write_jsonl!(path, records) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Enum.map_join(records, "", &(Sugary.Json.encode!(&1) <> "\n")))
  end

  defp safe_id(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 180)
  end

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(%_module{} = struct, key, default),
    do: struct |> Map.from_struct() |> field(key, default)

  defp field(%{} = map, key, default), do: map[key] || map[to_string(key)] || default
  defp field(_value, _key, default), do: default
end

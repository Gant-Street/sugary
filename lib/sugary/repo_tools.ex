defmodule Sugary.RepoTools do
  @moduledoc """
  Local repository tools for review experiments.

  These functions are deliberately small and deterministic. They expose evidence
  with citations, not agent autonomy. Callers decide whether the evidence is
  strong enough to publish a claim.
  """

  @max_citations 5
  @max_text 240

  def evidence_for_claim(bench_case, claim, capability) do
    started = System.monotonic_time(:millisecond)

    evidence =
      case capability do
        "read_changed_file" ->
          read_changed_file(bench_case, claim_path(claim))

        "read_changed_files" ->
          read_changed_file(bench_case, claim_path(claim))

        "repo_grep" ->
          grep_head(bench_case, query_for_claim(claim))

        "repo_rg" ->
          grep_head(bench_case, query_for_claim(claim))

        "git_history" ->
          git_history(bench_case, claim_path(claim))

        "git_grep_history" ->
          git_grep_history(bench_case, query_for_claim(claim), claim_path(claim))

        unknown ->
          unknown_tool(unknown)
      end

    Map.put(evidence, :duration_ms, System.monotonic_time(:millisecond) - started)
  end

  def read_changed_file(bench_case, path) do
    changed = changed_files(bench_case)
    normalized = normalize_path(path)
    workspace = workspace(bench_case)

    cond do
      changed == [] ->
        unavailable("read_changed_file", "No changed-file list was available.")

      normalized in ["", "unknown"] ->
        counterargument("read_changed_file", "Claim path is unknown.", [], 0.0, 0.55)

      not Enum.any?(changed, &same_or_suffix_path?(&1, normalized)) ->
        counterargument(
          "read_changed_file",
          "Claim path is outside the changed-file set.",
          [%{path: normalized, changed_files: changed}],
          0.0,
          1.1
        )

      workspace == nil ->
        support(
          "read_changed_file",
          "Claim path is in the changed-file set, but no head workspace is available.",
          [%{path: normalized}],
          0.35,
          0.0
        )

      true ->
        head_path = path_in_workspace(workspace.head, changed, normalized)

        if head_path && File.regular?(head_path) do
          support(
            "read_changed_file",
            "Read the changed file from the head workspace.",
            [file_citation(workspace.head, head_path)],
            0.75,
            0.0
          )
        else
          counterargument(
            "read_changed_file",
            "Changed-file path was not readable in the head workspace.",
            [%{path: normalized, workspace: workspace.head}],
            0.0,
            0.35
          )
        end
    end
  end

  def grep_head(bench_case, query) do
    workspace = workspace(bench_case)
    query = normalize_query(query)

    cond do
      is_nil(System.find_executable("rg")) ->
        unavailable("repo_grep", "`rg` is not installed.")

      query == "" ->
        unavailable("repo_grep", "No stable query token was available.")

      workspace == nil ->
        unavailable("repo_grep", "No local head workspace was available.")

      true ->
        case run_rg(workspace.head, query) do
          {:ok, citations} when citations != [] ->
            support(
              "repo_grep",
              "`rg` found claim tokens in the head workspace.",
              citations,
              0.45,
              0.0,
              %{query: query}
            )

          {:ok, []} ->
            counterargument(
              "repo_grep",
              "`rg` did not find claim tokens in the head workspace.",
              [],
              0.0,
              0.15,
              %{query: query}
            )

          {:error, reason} ->
            unavailable("repo_grep", reason, %{query: query})
        end
    end
  end

  def git_history(bench_case, path) do
    path = normalize_path(path)

    with {:ok, repo_dir, ref} <- git_context(bench_case) do
      args =
        [
          "--git-dir",
          repo_dir,
          "log",
          "--max-count=5",
          "--format=%H%x09%h%x09%s",
          ref
        ] ++ pathspec(path)

      case System.cmd("git", args, stderr_to_stdout: true) do
        {stdout, 0} ->
          citations = parse_git_log(stdout, path)

          if citations == [] do
            counterargument(
              "git_history",
              "No git history entries were found for the claim path/ref.",
              [],
              0.0,
              0.1,
              %{path: path, ref: ref}
            )
          else
            support(
              "git_history",
              "Git history is available for the claim path/ref.",
              citations,
              0.25,
              0.0,
              %{path: path, ref: ref}
            )
          end

        {stdout, status} ->
          unavailable(
            "git_history",
            "git log failed with #{status}: #{String.slice(stdout, 0, 300)}",
            %{path: path, ref: ref}
          )
      end
    else
      {:error, reason} -> unavailable("git_history", reason, %{path: path})
    end
  end

  def git_grep_history(bench_case, query, path \\ nil) do
    query = normalize_query(query)
    path = normalize_path(path)

    cond do
      query == "" ->
        unavailable("git_grep_history", "No stable query token was available.")

      true ->
        with {:ok, repo_dir, ref} <- git_context(bench_case) do
          args =
            [
              "--git-dir",
              repo_dir,
              "log",
              "--max-count=5",
              "--format=%H%x09%h%x09%s",
              "-S",
              query,
              ref
            ] ++ pathspec(path)

          case System.cmd("git", args, stderr_to_stdout: true) do
            {stdout, 0} ->
              citations = parse_git_log(stdout, path)

              if citations == [] do
                counterargument(
                  "git_grep_history",
                  "No commits changing the query token were found in git history.",
                  [],
                  0.0,
                  0.05,
                  %{query: query, path: path, ref: ref}
                )
              else
                support(
                  "git_grep_history",
                  "Git history contains commits changing the query token.",
                  citations,
                  0.35,
                  0.0,
                  %{query: query, path: path, ref: ref}
                )
              end

            {stdout, status} ->
              unavailable(
                "git_grep_history",
                "git log -S failed with #{status}: #{String.slice(stdout, 0, 300)}",
                %{query: query, path: path, ref: ref}
              )
          end
        else
          {:error, reason} -> unavailable("git_grep_history", reason, %{query: query, path: path})
        end
    end
  end

  def workspace(bench_case) do
    repo = field(bench_case, :repo, %{})
    workspace = field(repo, :workspace)

    cond do
      map_workspace_ready?(workspace) ->
        %{
          root: Path.expand(field(workspace, :root)),
          base: Path.expand(field(workspace, :base)),
          head: Path.expand(field(workspace, :head))
        }

      true ->
        paths = Sugary.RepoMaterializer.workspace_paths(field(bench_case, :id))
        base = Path.expand(paths.base)
        head = Path.expand(paths.head)

        if File.dir?(base) and File.dir?(head) do
          %{root: Path.expand(paths.root), base: base, head: head}
        else
          nil
        end
    end
  end

  def repo_cache_path(bench_case) do
    bench_case
    |> candidate_urls()
    |> Enum.find_value(fn url ->
      case Sugary.RepoMaterializer.parse_github_url(url) do
        {:ok, target} ->
          path =
            Path.join([
              ".sugary/research/repo-cache/github.com",
              target.owner,
              "#{target.repo}.git"
            ])

          if File.dir?(Path.join(path, "objects")), do: path

        {:error, _reason} ->
          nil
      end
    end)
  end

  def changed_files(bench_case) do
    context = field(bench_case, :context, %{})
    allowed = field(context, :allowed, context)

    allowed
    |> field(:changed_files, [])
    |> List.wrap()
    |> Enum.map(&normalize_path/1)
    |> Enum.reject(&(&1 == ""))
  end

  def query_for_claim(claim) do
    path_terms =
      claim
      |> claim_path()
      |> Path.basename()
      |> Path.rootname()
      |> split_terms()

    text_terms =
      [
        field(claim, :dedupe_key),
        field(claim, :claim),
        field(claim, :category),
        field(claim, :failure_path, []) |> List.wrap() |> Enum.join(" "),
        field(claim, :evidence, [])
        |> List.wrap()
        |> Enum.map(&field(&1, :summary, ""))
        |> Enum.join(" ")
      ]
      |> Enum.join(" ")
      |> split_terms()

    (path_terms ++ text_terms)
    |> Enum.reject(&stopword?/1)
    |> Enum.find(&(String.length(&1) >= 5))
    |> to_string()
  end

  def claim_path(claim), do: normalize_path(field(claim, :path, "unknown"))

  defp git_context(bench_case) do
    case repo_cache_path(bench_case) do
      nil ->
        {:error, "No local bare git cache was available."}

      repo_dir ->
        case history_ref(bench_case, repo_dir) do
          {:ok, ref} -> {:ok, repo_dir, ref}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp history_ref(bench_case, repo_dir) do
    targets =
      bench_case
      |> candidate_urls()
      |> Enum.flat_map(fn url ->
        case Sugary.RepoMaterializer.parse_github_url(url) do
          {:ok, %{type: "commit", head_sha: sha}} ->
            [sha]

          {:ok, %{type: "pull_request", number: number}} ->
            ["refs/sugary/pull/#{number}/head", "refs/pull/#{number}/head"]

          _ ->
            []
        end
      end)
      |> Enum.uniq()

    Enum.find_value(targets, fn ref ->
      case System.cmd("git", ["--git-dir", repo_dir, "rev-parse", "--verify", ref],
             stderr_to_stdout: true
           ) do
        {_stdout, 0} -> {:ok, ref}
        {_stdout, _status} -> nil
      end
    end) || {:error, "No benchmark head ref was available in the local bare git cache."}
  end

  defp candidate_urls(bench_case) do
    metadata = field(bench_case, :source_metadata, %{})
    pr = field(bench_case, :pr, %{})
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

  defp path_in_workspace(root, changed_files, path) do
    ([path] ++ changed_files)
    |> Enum.uniq()
    |> Enum.map(&Path.join(root, &1))
    |> Enum.find(&File.regular?/1)
  end

  defp file_citation(root, absolute_path) do
    relative = Path.relative_to(absolute_path, root)

    text =
      absolute_path
      |> File.stream!([], :line)
      |> Enum.take(12)
      |> Enum.join("")
      |> String.slice(0, @max_text)

    %{path: relative, line: 1, text: text}
  end

  defp run_rg(root, query) do
    case System.cmd(
           "rg",
           [
             "-n",
             "--fixed-strings",
             "--max-count",
             Integer.to_string(@max_citations),
             "--glob",
             "!.git",
             "--",
             query,
             root
           ],
           stderr_to_stdout: true
         ) do
      {stdout, 0} -> {:ok, parse_rg(stdout, root)}
      {_stdout, 1} -> {:ok, []}
      {stdout, status} -> {:error, "`rg` failed with #{status}: #{String.slice(stdout, 0, 300)}"}
    end
  end

  defp parse_rg(stdout, root) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.take(@max_citations)
    |> Enum.flat_map(fn row ->
      case Regex.run(~r/^(.+?):(\d+):(.*)$/, row) do
        [_all, path, line, text] ->
          [
            %{
              path: Path.relative_to(path, root),
              line: parse_int(line),
              text: String.slice(String.trim(text), 0, @max_text)
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp parse_git_log(stdout, path) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.take(@max_citations)
    |> Enum.flat_map(fn row ->
      case String.split(row, "\t", parts: 3) do
        [commit, short, subject] ->
          [%{commit: commit, short_commit: short, subject: subject, path: path}]

        _ ->
          []
      end
    end)
  end

  defp pathspec(path) when path in ["", "unknown"], do: []
  defp pathspec(path), do: ["--", path]

  defp unknown_tool(name),
    do: unavailable(name, "Unknown repository tool capability.")

  defp unavailable(tool, summary, extra \\ %{}),
    do:
      Map.merge(
        %{
          tool: tool,
          status: "unavailable",
          summary: summary,
          citations: [],
          bonus: 0.0,
          penalty: 0.0
        },
        extra
      )

  defp support(tool, summary, citations, bonus, penalty, extra \\ %{}),
    do:
      Map.merge(
        %{
          tool: tool,
          status: "support",
          summary: summary,
          citations: citations,
          bonus: bonus,
          penalty: penalty
        },
        extra
      )

  defp counterargument(tool, summary, citations, bonus, penalty, extra \\ %{}),
    do:
      Map.merge(
        %{
          tool: tool,
          status: "counterargument",
          summary: summary,
          citations: citations,
          bonus: bonus,
          penalty: penalty
        },
        extra
      )

  defp same_or_suffix_path?(left, right) do
    left = normalize_path(left)
    right = normalize_path(right)

    left == right or String.ends_with?(left, "/" <> right) or
      String.ends_with?(right, "/" <> left)
  end

  defp normalize_query(query) do
    query
    |> to_string()
    |> String.trim()
    |> String.replace(~r/\s+/, " ")
  end

  defp normalize_path(path), do: path |> to_string() |> String.trim()

  defp split_terms(text) do
    text
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_\/.-]+/, " ")
    |> String.split()
    |> Enum.flat_map(&String.split(&1, ~r/[\/.-]+/))
    |> Enum.reject(&(&1 == ""))
  end

  defp stopword?(term),
    do: term in ~w(
        should because without generated introduced current failure static proof reviewer
        public changed claim missing issue method route object commit file source
      )

  defp map_workspace_ready?(workspace) do
    is_map(workspace) and File.dir?(field(workspace, :base, "")) and
      File.dir?(field(workspace, :head, ""))
  end

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(%_module{} = struct, key, default),
    do: struct |> Map.from_struct() |> field(key, default)

  defp field(%{} = map, key, default), do: map[key] || map[to_string(key)] || default
  defp field(_value, _key, default), do: default
end

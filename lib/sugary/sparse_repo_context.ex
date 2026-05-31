defmodule Sugary.SparseRepoContext do
  @moduledoc false

  @root ".sugary/research/sparse-repo-context"
  @repo_cache ".sugary/research/repo-cache"
  @version "sparse-repo-context-v0"
  @max_changed_files 35
  @max_related_files 12
  @max_file_bytes 180_000
  @max_identifier_greps 8
  @max_grep_hits_per_identifier 12

  def run!(opts \\ %{}) do
    opts = stringify(opts)
    suite = Map.get(opts, "suite", "aacr-bench")
    limit = opts |> Map.get("limit", "50") |> int()
    offset = opts |> Map.get("offset", "0") |> int()
    id = Map.get(opts, "id", "#{suite}-sparse-context-v0")

    cases = Sugary.PublicBenchmarks.load_cases!(suite, limit: limit, offset: offset)
    out_dir = make_out_dir(id)
    File.mkdir_p!(out_dir)

    config = %{
      version: @version,
      suite: suite,
      limit: limit,
      offset: offset,
      repo_cache: @repo_cache,
      workspace_root: ".sugary/research/workspaces",
      max_changed_files: @max_changed_files,
      max_related_files: @max_related_files,
      max_file_bytes: @max_file_bytes
    }

    records = Enum.map(cases, &prepare_case/1)
    summary = summarize(records)

    Sugary.Json.write!(Path.join(out_dir, "config.json"), config)
    Sugary.Json.write!(Path.join(out_dir, "summary.json"), summary)
    write_jsonl!(Path.join(out_dir, "sparse-context.jsonl"), records)

    Enum.each(records, fn record ->
      Sugary.Json.write!(Path.join([out_dir, "cases", "#{safe_id(record.case_id)}.json"]), record)
    end)

    File.write!(
      Path.join(out_dir, "sparse-context-report.md"),
      render_report(config, summary, records)
    )

    out_dir
  end

  defp prepare_case(bench_case) do
    metadata = bench_case.source_metadata || %{}
    benchmark_metadata = field(metadata, :benchmark_metadata, %{})
    url = field(metadata, :case_source_url) || field(metadata, :original_case_id)
    target = parse_github_url(url)
    base_sha = field(benchmark_metadata, :source_commit)
    head_sha = field(benchmark_metadata, :target_commit)

    changed_files =
      bench_case |> changed_files() |> prioritize_changed_files() |> Enum.take(@max_changed_files)

    workspace = Sugary.RepoMaterializer.workspace_paths(bench_case.id)

    base = %{
      case_id: bench_case.id,
      suite: bench_case.suite,
      source_url: url,
      repo: field(metadata, :repo, "unknown"),
      base_sha: base_sha,
      head_sha: head_sha,
      changed_files_count: length(changed_files),
      changed_files: changed_files,
      workspace: workspace,
      status: "unavailable",
      reason: nil,
      target: target,
      diff_parity: "unavailable",
      changed_files_written: 0,
      related_files_written: 0,
      grep_context_files: 0,
      leakage: leakage_summary(),
      truncated_files: [],
      missing_head_files: [],
      missing_base_files: [],
      tool_availability: %{
        list_changed_files: changed_files != [],
        read_changed_file: false,
        read_base_file: false,
        rg_head: false,
        rg_base: false,
        sparse_workspace: false
      }
    }

    cond do
      is_nil(target) ->
        %{base | status: "unsupported", reason: "No supported GitHub PR URL was found."}

      not git_sha?(base_sha) or not git_sha?(head_sha) ->
        %{base | status: "metadata_incomplete", reason: "AACR source/target commits missing."}

      changed_files == [] ->
        %{base | status: "metadata_incomplete", reason: "No changed files were available."}

      true ->
        build_sparse_workspace(base, bench_case)
    end
  end

  defp build_sparse_workspace(record, bench_case) do
    if fetch_mode() == "raw_http" do
      build_raw_workspace(record, bench_case)
    else
      build_git_workspace(record, bench_case)
    end
  end

  defp build_git_workspace(record, bench_case) do
    repo_dir = repo_cache_path(record.target)

    with :ok <- ensure_bare_repo(repo_dir, clone_url(record.target.owner, record.target.repo)),
         :ok <- fetch_ref(repo_dir, record.base_sha),
         :ok <- fetch_ref(repo_dir, record.head_sha) do
      File.rm_rf!(record.workspace.root)
      File.mkdir_p!(record.workspace.base)
      File.mkdir_p!(record.workspace.head)

      changed_result =
        write_changed_files!(
          repo_dir,
          record.base_sha,
          record.head_sha,
          record.workspace,
          record.changed_files
        )

      related =
        related_files(
          repo_dir,
          record.head_sha,
          record.changed_files,
          changed_result.head_contents
        )

      related_result =
        write_related_files!(
          repo_dir,
          record.base_sha,
          record.head_sha,
          record.workspace,
          related
        )

      grep_result =
        write_grep_context!(
          repo_dir,
          record.head_sha,
          record.workspace,
          changed_result.head_contents
        )

      parity = diff_parity(repo_dir, record.base_sha, record.head_sha, record.changed_files)

      record =
        record
        |> Map.put(:status, "sparse_workspace_ready")
        |> Map.put(:repo_cache_path, repo_dir)
        |> Map.put(:diff_parity, parity)
        |> Map.put(:changed_files_written, changed_result.written)
        |> Map.put(:related_files_written, related_result.written)
        |> Map.put(:grep_context_files, grep_result.written)
        |> Map.put(:leakage, leakage_summary())
        |> Map.put(:truncated_files, changed_result.truncated ++ related_result.truncated)
        |> Map.put(:missing_head_files, changed_result.missing_head)
        |> Map.put(:missing_base_files, changed_result.missing_base)
        |> Map.put(:related_files, related)
        |> Map.put(:tool_availability, %{
          list_changed_files: true,
          read_changed_file: changed_result.written > 0,
          read_base_file: changed_result.base_written > 0,
          rg_head: grep_result.written > 0,
          rg_base: false,
          sparse_workspace: true
        })

      write_context_manifest!(record.workspace, record, bench_case)
      record
    else
      {:error, reason} ->
        record
        |> Map.put(:status, "sparse_fetch_failed")
        |> Map.put(:reason, reason)
        |> Map.put(:repo_cache_path, repo_dir)
    end
  end

  defp build_raw_workspace(record, bench_case) do
    File.rm_rf!(record.workspace.root)
    File.mkdir_p!(record.workspace.base)
    File.mkdir_p!(record.workspace.head)

    changed_result =
      write_changed_files_raw!(
        record.target,
        record.base_sha,
        record.head_sha,
        record.workspace,
        record.changed_files
      )

    related =
      raw_related_files(record.changed_files, changed_result.head_contents)
      |> Enum.take(@max_related_files)

    related_result =
      write_related_files_raw!(
        record.target,
        record.base_sha,
        record.head_sha,
        record.workspace,
        related
      )

    grep_result = write_grep_context!(nil, nil, record.workspace, changed_result.head_contents)

    record =
      record
      |> Map.put(:status, "sparse_workspace_ready")
      |> Map.put(:fetch_mode, "raw_http")
      |> Map.put(:diff_parity, "raw_http_unchecked")
      |> Map.put(:changed_files_written, changed_result.written)
      |> Map.put(:related_files_written, related_result.written)
      |> Map.put(:grep_context_files, grep_result.written)
      |> Map.put(:leakage, leakage_summary())
      |> Map.put(:truncated_files, changed_result.truncated ++ related_result.truncated)
      |> Map.put(:missing_head_files, changed_result.missing_head)
      |> Map.put(:missing_base_files, changed_result.missing_base)
      |> Map.put(:related_files, related)
      |> Map.put(:tool_availability, %{
        list_changed_files: true,
        read_changed_file: changed_result.written > 0,
        read_base_file: changed_result.base_written > 0,
        rg_head: grep_result.written > 0,
        rg_base: false,
        sparse_workspace: true
      })

    write_context_manifest!(record.workspace, record, bench_case)
    record
  end

  defp write_changed_files!(repo_dir, base_sha, head_sha, workspace, changed_files) do
    Enum.reduce(
      changed_files,
      %{
        written: 0,
        base_written: 0,
        head_contents: %{},
        truncated: [],
        missing_head: [],
        missing_base: []
      },
      fn file, acc ->
        file = safe_relative_path(file)

        {acc, head_content} =
          case read_blob(repo_dir, head_sha, file) do
            {:ok, content, truncated?} ->
              write_workspace_file!(workspace.head, file, content)

              acc =
                acc
                |> Map.update!(:written, &(&1 + 1))
                |> maybe_track_truncated(file, truncated?)

              {acc, content}

            {:error, _reason} ->
              {Map.update!(acc, :missing_head, &[file | &1]), nil}
          end

        acc =
          case read_blob(repo_dir, base_sha, file) do
            {:ok, content, truncated?} ->
              write_workspace_file!(workspace.base, file, content)

              acc
              |> Map.update!(:base_written, &(&1 + 1))
              |> maybe_track_truncated(file, truncated?)

            {:error, _reason} ->
              Map.update!(acc, :missing_base, &[file | &1])
          end

        if is_binary(head_content) do
          Map.update!(acc, :head_contents, &Map.put(&1, file, head_content))
        else
          acc
        end
      end
    )
    |> Map.update!(:missing_head, &Enum.reverse/1)
    |> Map.update!(:missing_base, &Enum.reverse/1)
    |> Map.update!(:truncated, &Enum.uniq/1)
  end

  defp write_related_files!(repo_dir, base_sha, head_sha, workspace, related_files) do
    Enum.reduce(related_files, %{written: 0, truncated: []}, fn file, acc ->
      with file <- safe_relative_path(file),
           {:ok, content, truncated?} <- read_blob(repo_dir, head_sha, file) do
        write_workspace_file!(workspace.head, file, content)

        case read_blob(repo_dir, base_sha, file) do
          {:ok, base_content, _base_truncated?} ->
            write_workspace_file!(workspace.base, file, base_content)

          {:error, _reason} ->
            :ok
        end

        acc
        |> Map.update!(:written, &(&1 + 1))
        |> maybe_track_truncated(file, truncated?)
      else
        _other -> acc
      end
    end)
    |> Map.update!(:truncated, &Enum.uniq/1)
  end

  defp write_changed_files_raw!(target, base_sha, head_sha, workspace, changed_files) do
    Enum.reduce(
      changed_files,
      %{
        written: 0,
        base_written: 0,
        head_contents: %{},
        truncated: [],
        missing_head: [],
        missing_base: []
      },
      fn file, acc ->
        file = safe_relative_path(file)

        {acc, head_content} =
          case read_raw_blob(target, head_sha, file) do
            {:ok, content, truncated?} ->
              write_workspace_file!(workspace.head, file, content)

              acc =
                acc
                |> Map.update!(:written, &(&1 + 1))
                |> maybe_track_truncated(file, truncated?)

              {acc, content}

            {:error, _reason} ->
              {Map.update!(acc, :missing_head, &[file | &1]), nil}
          end

        acc =
          case read_raw_blob(target, base_sha, file) do
            {:ok, content, truncated?} ->
              write_workspace_file!(workspace.base, file, content)

              acc
              |> Map.update!(:base_written, &(&1 + 1))
              |> maybe_track_truncated(file, truncated?)

            {:error, _reason} ->
              Map.update!(acc, :missing_base, &[file | &1])
          end

        if is_binary(head_content) do
          Map.update!(acc, :head_contents, &Map.put(&1, file, head_content))
        else
          acc
        end
      end
    )
    |> Map.update!(:missing_head, &Enum.reverse/1)
    |> Map.update!(:missing_base, &Enum.reverse/1)
    |> Map.update!(:truncated, &Enum.uniq/1)
  end

  defp write_related_files_raw!(target, base_sha, head_sha, workspace, related_files) do
    Enum.reduce(related_files, %{written: 0, truncated: []}, fn file, acc ->
      with file <- safe_relative_path(file),
           {:ok, content, truncated?} <- read_raw_blob(target, head_sha, file) do
        write_workspace_file!(workspace.head, file, content)

        case read_raw_blob(target, base_sha, file) do
          {:ok, base_content, _base_truncated?} ->
            write_workspace_file!(workspace.base, file, base_content)

          {:error, _reason} ->
            :ok
        end

        acc
        |> Map.update!(:written, &(&1 + 1))
        |> maybe_track_truncated(file, truncated?)
      else
        _other -> acc
      end
    end)
    |> Map.update!(:truncated, &Enum.uniq/1)
  end

  defp write_grep_context!(repo_dir, head_sha, workspace, head_contents) do
    unless System.get_env("SUGARY_SPARSE_ENABLE_FULL_GREP") == "true" do
      return_identifier_context!(workspace, head_contents)
    else
      write_full_grep_context!(repo_dir, head_sha, workspace, head_contents)
    end
  end

  defp write_full_grep_context!(repo_dir, head_sha, workspace, head_contents) do
    identifiers =
      head_contents
      |> Enum.flat_map(fn {_file, content} -> identifiers(content) end)
      |> Enum.frequencies()
      |> Enum.sort_by(fn {_identifier, count} -> -count end)
      |> Enum.map(&elem(&1, 0))
      |> Enum.take(@max_identifier_greps)

    lines =
      identifiers
      |> Enum.flat_map(&grep_identifier(repo_dir, head_sha, &1))
      |> Enum.uniq()
      |> Enum.take(200)

    if lines == [] do
      %{written: 0}
    else
      context = """
      # Sparse Grep Context

      These matches were collected from the PR head commit using benchmark-agnostic identifiers found in changed files.

      #{Enum.join(lines, "\n")}
      """

      File.write!(Path.join(workspace.head, "SUGARY_GREP_CONTEXT.md"), context)
      %{written: 1}
    end
  end

  defp return_identifier_context!(workspace, head_contents) do
    identifiers =
      head_contents
      |> Enum.flat_map(fn {file, content} ->
        content
        |> identifiers()
        |> Enum.take(20)
        |> Enum.map(&"#{file}: #{&1}")
      end)
      |> Enum.uniq()
      |> Enum.take(200)

    if identifiers == [] do
      %{written: 0}
    else
      context = """
      # Sparse Identifier Context

      Repo-wide grep is disabled by default because partial-clone blob fetches can dominate the benchmark loop on large repos.
      These identifiers were extracted from changed files and can guide local search inside the sparse workspace.

      #{Enum.join(identifiers, "\n")}
      """

      File.write!(Path.join(workspace.head, "SUGARY_GREP_CONTEXT.md"), context)
      %{written: 1}
    end
  end

  defp related_files(repo_dir, head_sha, changed_files, head_contents) do
    tree_files = list_tree(repo_dir, head_sha)
    changed_set = MapSet.new(changed_files)
    import_targets = import_targets(head_contents, tree_files)

    basename_related =
      changed_files
      |> Enum.flat_map(fn file ->
        basename = file |> Path.basename() |> String.replace(~r/\.[^.]+$/, "")

        Enum.filter(tree_files, fn candidate ->
          candidate not in changed_set and
            (String.contains?(candidate, "/test") or String.contains?(candidate, "/spec") or
               String.contains?(candidate, "test_") or String.contains?(candidate, "_test")) and
            String.contains?(String.downcase(Path.basename(candidate)), String.downcase(basename))
        end)
      end)

    config_related =
      tree_files
      |> Enum.filter(fn file ->
        basename = Path.basename(file)

        file not in changed_set and
          basename in [
            "package.json",
            "tsconfig.json",
            "pyproject.toml",
            "Cargo.toml",
            "CMakeLists.txt",
            "go.mod",
            "mix.exs"
          ]
      end)

    (import_targets ++ basename_related ++ config_related)
    |> Enum.uniq()
    |> Enum.take(@max_related_files)
  end

  defp raw_related_files(changed_files, head_contents) do
    changed_set = MapSet.new(changed_files)

    import_related =
      head_contents
      |> Enum.flat_map(fn {file, content} ->
        raw_import_candidates(Path.dirname(file), content)
      end)
      |> Enum.reject(&MapSet.member?(changed_set, &1))

    root_config =
      [
        "package.json",
        "tsconfig.json",
        "pyproject.toml",
        "Cargo.toml",
        "CMakeLists.txt",
        "go.mod",
        "mix.exs"
      ]

    test_neighbors =
      changed_files
      |> Enum.flat_map(fn file ->
        basename = file |> Path.basename() |> String.replace(~r/\.[^.]+$/, "")

        [
          "test/#{basename}_test.ts",
          "test/#{basename}.test.ts",
          "tests/#{basename}_test.py",
          "tests/#{basename}.test.ts",
          "__tests__/#{basename}.test.ts"
        ]
      end)

    (import_related ++ test_neighbors ++ root_config)
    |> Enum.uniq()
  end

  defp raw_import_candidates(base_dir, content) do
    Regex.scan(~r/(?:from|import|require)\s*(?:\(?\s*)?["']([^"']+)["']/, content)
    |> Enum.map(fn [_match, import_path] -> import_path end)
    |> Enum.filter(&String.starts_with?(&1, "."))
    |> Enum.flat_map(fn import_path ->
      base =
        [base_dir, import_path]
        |> Path.join()
        |> Path.expand("/")
        |> String.trim_leading("/")

      [
        base,
        base <> ".ts",
        base <> ".tsx",
        base <> ".js",
        base <> ".jsx",
        base <> ".py",
        base <> ".cpp",
        base <> ".h",
        Path.join(base, "index.ts"),
        Path.join(base, "index.tsx"),
        Path.join(base, "index.js")
      ]
    end)
  end

  defp import_targets(head_contents, tree_files) do
    tree = MapSet.new(tree_files)

    head_contents
    |> Enum.flat_map(fn {file, content} ->
      base_dir = Path.dirname(file)

      Regex.scan(~r/(?:from|import|require)\s*(?:\(?\s*)?["']([^"']+)["']/, content)
      |> Enum.map(fn [_match, import_path] -> import_path end)
      |> Enum.filter(&String.starts_with?(&1, "."))
      |> Enum.flat_map(&resolve_import(base_dir, &1, tree))
    end)
  end

  defp resolve_import(base_dir, import_path, tree) do
    base =
      [base_dir, import_path]
      |> Path.join()
      |> Path.expand("/")
      |> String.trim_leading("/")

    candidates =
      [
        base,
        base <> ".ts",
        base <> ".tsx",
        base <> ".js",
        base <> ".jsx",
        base <> ".py",
        base <> ".cpp",
        base <> ".h",
        Path.join(base, "index.ts"),
        Path.join(base, "index.tsx"),
        Path.join(base, "index.js")
      ]

    Enum.filter(candidates, &MapSet.member?(tree, &1))
  end

  defp write_context_manifest!(workspace, record, bench_case) do
    context = """
    # Sugary Sparse Review Context

    This workspace is a sparse, benchmark-agnostic reconstruction for code review.
    It contains changed files from the PR head/base commits plus cheap related context.
    It does not contain benchmark reference comments, expected claims, known non-issues, or scorer labels.

    - Repo: #{record.repo}
    - Base SHA: #{record.base_sha}
    - Head SHA: #{record.head_sha}
    - Diff parity: #{record.diff_parity}
    - Changed files declared by benchmark: #{record.changed_files_count}
    - Changed files written: #{record.changed_files_written}
    - Related files written: #{record.related_files_written}
    - Grep context files: #{record.grep_context_files}

    ## Changed Files

    #{Enum.map_join(record.changed_files, "\n", &"- #{&1}")}

    ## Related Files

    #{Enum.map_join(Map.get(record, :related_files, []), "\n", &"- #{&1}")}
    """

    File.write!(Path.join(workspace.head, "SUGARY_REVIEW_CONTEXT.md"), context)
    File.write!(Path.join(workspace.base, "SUGARY_REVIEW_CONTEXT.md"), context)

    metadata =
      bench_case.source_metadata
      |> Map.take([:repo, :adapter_version])
      |> Map.merge(%{
        sparse_context_version: @version,
        scorer_labels_included: false,
        oracle_included: false,
        benchmark_case_id_included: false,
        source_url_included: false
      })

    Sugary.Json.write!(Path.join(workspace.head, "sugary_sparse_context.json"), metadata)
  end

  defp leakage_summary do
    %{
      oracle_included: false,
      scorer_labels_included: false,
      expected_claims_included: false,
      known_non_issues_included: false,
      benchmark_case_id_included: false,
      source_url_included: false
    }
  end

  defp read_blob(repo_dir, sha, file) do
    case System.cmd("git", ["--git-dir", repo_dir, "show", "#{sha}:#{file}"],
           stderr_to_stdout: true
         ) do
      {content, 0} ->
        cond do
          String.contains?(content, <<0>>) ->
            {:error, "binary file"}

          byte_size(content) > @max_file_bytes ->
            {:ok, binary_part(content, 0, @max_file_bytes), true}

          true ->
            {:ok, content, false}
        end

      {_out, _status} ->
        {:error, "blob unavailable"}
    end
  end

  defp read_raw_blob(target, sha, file) do
    url =
      "https://raw.githubusercontent.com/#{target.owner}/#{target.repo}/#{sha}/#{encode_path(file)}"

    case System.cmd("curl", ["-fsSL", "--max-time", "20", url], stderr_to_stdout: true) do
      {content, 0} ->
        cond do
          String.contains?(content, <<0>>) ->
            {:error, "binary file"}

          byte_size(content) > @max_file_bytes ->
            {:ok, binary_part(content, 0, @max_file_bytes), true}

          true ->
            {:ok, content, false}
        end

      {out, status} ->
        {:error, "raw fetch failed with #{status}: #{String.slice(out, 0, 160)}"}
    end
  end

  defp write_workspace_file!(root, file, content) do
    path = Path.join(root, safe_relative_path(file))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, content)
  end

  defp grep_identifier(repo_dir, head_sha, identifier) do
    case System.cmd(
           "git",
           [
             "--git-dir",
             repo_dir,
             "grep",
             "-n",
             "--max-count",
             Integer.to_string(@max_grep_hits_per_identifier),
             "-e",
             identifier,
             head_sha
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} ->
        out
        |> String.split("\n", trim: true)
        |> Enum.map(&String.slice(&1, 0, 500))

      {_out, _status} ->
        []
    end
  end

  defp identifiers(content) do
    content
    |> String.split("\n")
    |> Enum.filter(
      &(String.starts_with?(String.trim_leading(&1), [
          "import ",
          "from ",
          "class ",
          "def ",
          "function ",
          "const ",
          "let ",
          "var "
        ]) or String.contains?(&1, "("))
    )
    |> Enum.flat_map(fn line ->
      Regex.scan(~r/[A-Za-z_][A-Za-z0-9_]{3,}/, line)
      |> Enum.map(&List.first/1)
    end)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&stopword?/1)
    |> Enum.uniq()
  end

  defp stopword?(word) do
    String.downcase(word) in [
      "const",
      "function",
      "return",
      "import",
      "from",
      "class",
      "true",
      "false",
      "null",
      "undefined",
      "include",
      "using",
      "namespace",
      "public",
      "private"
    ]
  end

  defp list_tree(repo_dir, head_sha) do
    case System.cmd("git", ["--git-dir", repo_dir, "ls-tree", "-r", "--name-only", head_sha],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.split(out, "\n", trim: true)
      {_out, _status} -> []
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

  defp fetch_ref(repo_dir, sha) when is_binary(sha) and sha != "" do
    if object_exists?(repo_dir, sha) do
      :ok
    else
      case System.cmd(
             "git",
             ["--git-dir", repo_dir, "fetch", "--filter=blob:none", "origin", sha],
             stderr_to_stdout: true
           ) do
        {_out, 0} ->
          :ok

        {out, status} ->
          {:error, "git fetch #{sha} failed with #{status}: #{String.slice(out, 0, 500)}"}
      end
    end
  end

  defp fetch_ref(_repo_dir, _sha), do: {:error, "missing commit sha"}

  defp object_exists?(repo_dir, sha) do
    case System.cmd("git", ["--git-dir", repo_dir, "cat-file", "-e", "#{sha}^{commit}"],
           stderr_to_stdout: true
         ) do
      {_out, 0} -> true
      {_out, _status} -> false
    end
  end

  defp git(args, error_prefix) do
    case System.cmd("git", args, stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, "#{error_prefix} with #{status}: #{String.slice(out, 0, 500)}"}
    end
  end

  defp parse_github_url(url) do
    case Sugary.RepoMaterializer.parse_github_url(url) do
      {:ok, target} -> target
      {:error, _reason} -> nil
    end
  end

  defp repo_cache_path(target),
    do: Path.join([@repo_cache, "github.com", target.owner, "#{target.repo}.git"])

  defp clone_url(owner, repo) do
    case System.get_env("SUGARY_GITHUB_CLONE_URL_TEMPLATE") do
      template when is_binary(template) and template != "" ->
        template
        |> String.replace("{owner}", owner)
        |> String.replace("{repo}", repo)
        |> String.replace("{owner_repo}", "#{owner}/#{repo}")

      _ ->
        "https://github.com/#{owner}/#{repo}.git"
    end
  end

  defp fetch_mode do
    cond do
      mode = System.get_env("SUGARY_SPARSE_FETCH_MODE") ->
        mode

      System.get_env("SUGARY_GITHUB_CLONE_URL_TEMPLATE") not in [nil, ""] ->
        "git"

      true ->
        "raw_http"
    end
  end

  defp changed_files(bench_case) do
    context = bench_case.context || %{}
    allowed = field(context, :allowed, context)
    allowed |> field(:changed_files, []) |> List.wrap() |> Enum.map(&to_string/1)
  end

  defp prioritize_changed_files(files) do
    files
    |> Enum.uniq()
    |> Enum.sort_by(fn file ->
      normalized = String.downcase(file)

      {
        if(String.contains?(normalized, ["vendor/", "generated/", "dist/", "build/"]),
          do: 1,
          else: 0
        ),
        if(
          String.contains?(normalized, ["locale", "i18n"]) and
            String.ends_with?(normalized, ".json"),
          do: 1,
          else: 0
        ),
        if(source_like?(normalized), do: 0, else: 1),
        if(test_like?(normalized), do: 0, else: 1),
        String.length(normalized),
        normalized
      }
    end)
  end

  defp source_like?(path) do
    Enum.any?(
      ~w(.ex .exs .ts .tsx .js .jsx .py .cpp .cc .c .h .hpp .rs .go .java .kt .rb .php .sql .sh .cmake .toml .yaml .yml .json),
      &String.ends_with?(path, &1)
    )
  end

  defp test_like?(path) do
    String.contains?(path, ["/test", "/tests", "/spec", "_test", ".test.", ".spec."])
  end

  defp summarize(records) do
    %{
      version: @version,
      cases: length(records),
      sparse_workspace_ready: Enum.count(records, &(&1.status == "sparse_workspace_ready")),
      failed: Enum.count(records, &(&1.status in ["sparse_fetch_failed", "metadata_incomplete"])),
      unsupported: Enum.count(records, &(&1.status == "unsupported")),
      exact_diff_parity: Enum.count(records, &(&1.diff_parity == "exact")),
      partial_diff_parity: Enum.count(records, &(&1.diff_parity == "partial")),
      mismatch_diff_parity: Enum.count(records, &(&1.diff_parity == "mismatch")),
      changed_files_written: Enum.sum(Enum.map(records, & &1.changed_files_written)),
      related_files_written: Enum.sum(Enum.map(records, & &1.related_files_written)),
      grep_context_files: Enum.sum(Enum.map(records, & &1.grep_context_files)),
      repos:
        records
        |> Enum.map(& &1.repo)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()
    }
  end

  defp render_report(config, summary, records) do
    rows =
      records
      |> Enum.map(fn record ->
        "| `#{record.case_id}` | #{record.repo} | #{record.status} | #{record.diff_parity} | #{record.changed_files_count} | #{record.changed_files_written} | #{record.related_files_written} | #{record.grep_context_files} | #{record.reason || ""} |"
      end)
      |> Enum.join("\n")

    """
    # Sparse Repo Context v0

    This run creates sparse base/head workspaces for public benchmark review. It does not run reviewers, does not read oracle comments into workspaces, and does not claim benchmark performance.

    ## Setup

    - Suite: `#{config.suite}`
    - Offset: #{config.offset}
    - Limit: #{config.limit}
    - Repo cache: `#{config.repo_cache}`
    - Workspace root: `#{config.workspace_root}`

    ## Summary

    - Cases: #{summary.cases}
    - Sparse workspace ready: #{summary.sparse_workspace_ready}
    - Failed: #{summary.failed}
    - Unsupported: #{summary.unsupported}
    - Exact diff parity: #{summary.exact_diff_parity}
    - Partial diff parity: #{summary.partial_diff_parity}
    - Mismatch diff parity: #{summary.mismatch_diff_parity}
    - Changed files written: #{summary.changed_files_written}
    - Related files written: #{summary.related_files_written}
    - Grep context files: #{summary.grep_context_files}
    - Repos: #{Enum.map_join(summary.repos, ", ", &"`#{&1}`")}

    ## Cases

    | Case | Repo | Status | Diff parity | Changed files | Changed written | Related written | Grep context | Reason |
    | --- | --- | --- | --- | ---: | ---: | ---: | ---: | --- |
    #{if rows == "", do: "| none | n/a | unavailable | unavailable | 0 | 0 | 0 | 0 | no cases |", else: rows}
    """
  end

  defp write_jsonl!(path, records) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Enum.map_join(records, "", &(Sugary.Json.encode!(&1) <> "\n")))
  end

  defp maybe_track_truncated(acc, _file, false), do: acc
  defp maybe_track_truncated(acc, file, true), do: Map.update!(acc, :truncated, &[file | &1])

  defp safe_relative_path(path) do
    path
    |> to_string()
    |> String.trim()
    |> String.replace("\\", "/")
    |> String.split("/", trim: true)
    |> Enum.reject(&(&1 in ["..", "."]))
    |> Path.join()
  end

  defp safe_id(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9._-]+/, "-")
    |> String.trim("-")
    |> String.slice(0, 180)
  end

  defp git_sha?(value), do: is_binary(value) and String.match?(value, ~r/^[a-fA-F0-9]{7,40}$/)

  defp encode_path(path) do
    path
    |> safe_relative_path()
    |> String.split("/", trim: true)
    |> Enum.map(&URI.encode/1)
    |> Enum.join("/")
  end

  defp make_out_dir(id) do
    timestamp = DateTime.utc_now() |> Calendar.strftime("%Y%m%dT%H%M%SZ")
    Path.join(@root, "#{timestamp}-#{id}")
  end

  defp stringify(opts) when is_map(opts),
    do: Map.new(opts, fn {key, value} -> {to_string(key), value} end)

  defp stringify(opts) when is_list(opts), do: opts |> Enum.into(%{}) |> stringify()

  defp int(value) when is_integer(value), do: value
  defp int(value) when is_float(value), do: trunc(value)

  defp int(value) do
    value
    |> to_string()
    |> Integer.parse()
    |> case do
      {number, _rest} -> number
      :error -> raise ArgumentError, "invalid integer #{inspect(value)}"
    end
  end

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(%_module{} = struct, key, default),
    do: struct |> Map.from_struct() |> field(key, default)

  defp field(%{} = map, key, default), do: map[key] || map[to_string(key)] || default
  defp field(_value, _key, default), do: default
end

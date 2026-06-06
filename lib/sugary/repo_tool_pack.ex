defmodule Sugary.RepoToolPack do
  @moduledoc """
  Builds a bounded, read-only repository evidence packet for live reviewer tests.

  This is candidate-generation context, not proof by itself. The packet is safe to
  pass through the command-reviewer boundary because it is derived from the PR
  diff and materialized repository state, never from benchmark oracle labels.
  """

  @version "repo-tool-pack-v0"
  @max_identifiers 12
  @max_changed_files 12
  @max_file_lines 80
  @max_file_chars 8_000
  @max_grep_lines_per_identifier 5
  @max_history_files 8
  @max_history_entries_per_file 3
  @max_history_identifiers 4
  @max_history_grep_entries_per_identifier 2
  @max_line_chars 240
  @command_timeout_ms 2_500

  def build(bench_case, _method \\ %{}) do
    changed_files = Sugary.RepoTools.changed_files(bench_case)
    workspace = Sugary.RepoTools.workspace(bench_case)
    git = Sugary.RepoTools.git_metadata(bench_case)
    identifiers = identifiers(bench_case.diff || "")

    changed_file_reads = changed_file_reads(workspace, changed_files)
    repo_grep = repo_grep(workspace, identifiers)
    git_history = git_history(git, changed_files)
    git_grep_history = git_grep_history(git, identifiers)

    %{
      version: @version,
      policy: %{
        max_identifiers: @max_identifiers,
        max_changed_files: @max_changed_files,
        max_file_lines: @max_file_lines,
        max_grep_lines_per_identifier: @max_grep_lines_per_identifier
      },
      stats: %{
        workspace_available: not is_nil(workspace),
        git_available: not is_nil(git),
        changed_files: length(changed_files),
        identifiers: length(identifiers),
        changed_file_reads: length(changed_file_reads),
        repo_grep_matches: Enum.reduce(repo_grep, 0, &(length(&1.matches) + &2)),
        git_history_entries: Enum.reduce(git_history, 0, &(length(&1.entries) + &2)),
        git_grep_history_entries: Enum.reduce(git_grep_history, 0, &(length(&1.entries) + &2))
      },
      identifiers: identifiers,
      changed_file_reads: changed_file_reads,
      repo_grep: repo_grep,
      git_history: git_history,
      git_grep_history: git_grep_history
    }
  end

  defp changed_file_reads(nil, _changed_files), do: []

  defp changed_file_reads(workspace, changed_files) do
    changed_files
    |> Enum.take(@max_changed_files)
    |> Enum.flat_map(fn path ->
      absolute = Path.join(workspace.head, path)

      if File.regular?(absolute) do
        [
          %{
            path: path,
            source: "head",
            snippet: file_snippet(absolute),
            truncated: file_truncated?(absolute)
          }
        ]
      else
        []
      end
    end)
  end

  defp repo_grep(nil, _identifiers), do: []

  defp repo_grep(workspace, identifiers) do
    if System.find_executable("rg") do
      identifiers
      |> Enum.flat_map(fn identifier ->
        case run_cmd(
               "rg",
               [
                 "-n",
                 "--fixed-strings",
                 "--max-count",
                 Integer.to_string(@max_grep_lines_per_identifier),
                 "--glob",
                 "!.git",
                 "--glob",
                 "!vendor/**",
                 "--",
                 identifier,
                 workspace.head
               ]
             ) do
          {:ok, stdout} ->
            [
              %{
                query: identifier,
                matches:
                  stdout |> parse_rg(workspace.head) |> Enum.take(@max_grep_lines_per_identifier)
              }
            ]

          {:error, _reason} ->
            []
        end
      end)
      |> Enum.reject(&(&1.matches == []))
    else
      []
    end
  end

  defp git_history(nil, _changed_files), do: []

  defp git_history(git, changed_files) do
    changed_files
    |> Enum.take(@max_history_files)
    |> Enum.flat_map(fn path ->
      args = [
        "--git-dir",
        git.git_dir,
        "log",
        "--max-count=#{@max_history_entries_per_file}",
        "--format=%H%x09%h%x09%s",
        git.head_ref,
        "--",
        path
      ]

      case run_cmd("git", args) do
        {:ok, stdout} ->
          entries = parse_git_log(stdout)

          if entries == [] do
            []
          else
            [%{path: path, entries: entries}]
          end

        {:error, _reason} ->
          []
      end
    end)
  end

  defp git_grep_history(nil, _identifiers), do: []

  defp git_grep_history(git, identifiers) do
    identifiers
    |> Enum.take(@max_history_identifiers)
    |> Enum.flat_map(fn identifier ->
      args = [
        "--git-dir",
        git.git_dir,
        "log",
        "--max-count=#{@max_history_grep_entries_per_identifier}",
        "--format=%H%x09%h%x09%s",
        "-S",
        identifier,
        git.head_ref
      ]

      case run_cmd("git", args) do
        {:ok, stdout} ->
          entries = parse_git_log(stdout)

          if entries == [] do
            []
          else
            [%{query: identifier, entries: entries}]
          end

        {:error, _reason} ->
          []
      end
    end)
  end

  defp run_cmd(command, args) do
    task =
      Task.async(fn ->
        System.cmd(command, args, stderr_to_stdout: true)
      end)

    case Task.yield(task, @command_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {stdout, 0}} -> {:ok, stdout}
      {:ok, {_stdout, _status}} -> {:error, :non_zero}
      nil -> {:error, :timeout}
    end
  end

  defp identifiers(diff) do
    diff
    |> String.split("\n")
    |> Enum.filter(&(String.starts_with?(&1, "+") and not String.starts_with?(&1, "+++")))
    |> Enum.flat_map(&Regex.scan(~r/[A-Za-z_][A-Za-z0-9_!?]{3,}/, &1))
    |> Enum.map(&hd/1)
    |> Enum.map(&String.trim_trailing(&1, "!?"))
    |> Enum.reject(&(String.downcase(&1) in stopwords()))
    |> Enum.frequencies()
    |> Enum.sort_by(fn {identifier, count} -> {-count, String.downcase(identifier)} end)
    |> Enum.map(&elem(&1, 0))
    |> Enum.take(@max_identifiers)
  end

  defp file_snippet(path) do
    path
    |> File.stream!([], :line)
    |> Enum.take(@max_file_lines)
    |> Enum.join("")
    |> String.slice(0, @max_file_chars)
  end

  defp file_truncated?(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size > @max_file_chars
      _ -> false
    end
  end

  defp parse_rg(stdout, root) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn row ->
      case Regex.run(~r/^(.+?):(\d+):(.*)$/, row) do
        [_all, path, line, text] ->
          [
            %{
              path: Path.relative_to(path, root),
              line: parse_int(line),
              text: text |> String.trim() |> String.slice(0, @max_line_chars)
            }
          ]

        _ ->
          []
      end
    end)
  end

  defp parse_git_log(stdout) do
    stdout
    |> String.split("\n", trim: true)
    |> Enum.flat_map(fn row ->
      case String.split(row, "\t", parts: 3) do
        [commit, short, subject] ->
          [%{commit: commit, short_commit: short, subject: subject}]

        _ ->
          []
      end
    end)
  end

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp stopwords do
    ~w(
      import export default return const let var class function true false null undefined from
      this public private protected static final async await if else case when then with without
      require module include using begin rescue ensure while until unless super self
    )
  end
end

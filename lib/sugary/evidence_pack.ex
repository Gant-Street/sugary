defmodule Sugary.EvidencePack do
  @moduledoc false

  @version "evidence-pack-v0"
  @max_files 12
  @max_hunks_per_file 3
  @max_section_bytes 5_000
  @max_total_bytes 55_000

  def build(bench_case, _method \\ %{}) do
    workspace = workspace(bench_case)
    changed_files = changed_files(bench_case)
    hunks_by_file = parse_diff_hunks(bench_case.diff || "")

    sections =
      []
      |> add_diff_hunks(hunks_by_file, changed_files)
      |> add_workspace_snippets(workspace, changed_files, hunks_by_file)
      |> add_related_snippets(workspace, changed_files)
      |> Enum.reverse()
      |> budget_sections()

    %{
      version: @version,
      objective: "benchmark_agnostic_review_evidence",
      oracle_included: false,
      scorer_labels_included: false,
      case_identifier_included: false,
      sections: sections,
      stats: %{
        changed_files_seen: length(changed_files),
        sections: length(sections),
        workspace_available: not is_nil(workspace),
        bytes: sections |> Enum.map(&byte_size(&1.content)) |> Enum.sum()
      }
    }
  end

  def classify_claim_type(claim) do
    category = field(claim, :category, "") |> normalize()
    text = [field(claim, :description), field(claim, :claim), field(claim, :specialist)] |> join()

    cond do
      String.contains?(category, "security") or String.contains?(text, "auth") ->
        "security"

      String.contains?(category, "performance") or String.contains?(text, "performance") ->
        "performance"

      String.contains?(category, "maintainability") or String.contains?(text, "readability") ->
        "maintainability"

      String.contains?(text, "test") ->
        "test_gap"

      String.contains?(text, ["api", "schema", "contract", "migration", "translation", "i18n"]) ->
        "contract"

      String.contains?(text, ["race", "async", "await", "timeout", "retry"]) ->
        "runtime"

      String.contains?(category, "defect") or String.contains?(category, "bug") ->
        "defect"

      true ->
        "general_review"
    end
  end

  defp add_diff_hunks(sections, hunks_by_file, changed_files) do
    changed_files
    |> Enum.take(@max_files)
    |> Enum.reduce(sections, fn file, acc ->
      hunks =
        hunks_by_file
        |> Map.get(file, [])
        |> Enum.take(@max_hunks_per_file)

      Enum.reduce(hunks, acc, fn hunk, inner ->
        [
          section(
            "diff:#{file}:#{hunk.new_start}",
            "changed_hunk",
            file,
            "Changed hunk around new line #{hunk.new_start}.",
            hunk.text
          )
          | inner
        ]
      end)
    end)
  end

  defp add_workspace_snippets(sections, nil, _changed_files, _hunks_by_file), do: sections

  defp add_workspace_snippets(sections, workspace, changed_files, hunks_by_file) do
    changed_files
    |> Enum.take(@max_files)
    |> Enum.reduce(sections, fn file, acc ->
      hunk = hunks_by_file |> Map.get(file, []) |> List.first(%{old_start: 1, new_start: 1})

      acc
      |> add_file_snippet(workspace.head, file, hunk.new_start || 1, "head_snippet")
      |> add_file_snippet(workspace.base, file, hunk.old_start || 1, "base_snippet")
    end)
  end

  defp add_related_snippets(sections, nil, _changed_files), do: sections

  defp add_related_snippets(sections, workspace, changed_files) do
    changed = MapSet.new(changed_files)

    workspace.head
    |> Path.join("**/*")
    |> Path.wildcard()
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, workspace.head))
    |> Enum.reject(&MapSet.member?(changed, &1))
    |> Enum.reject(&String.starts_with?(&1, "SUGARY_"))
    |> Enum.reject(&(&1 == "sugary_sparse_context.json"))
    |> Enum.filter(&related_context_file?/1)
    |> Enum.take(8)
    |> Enum.reduce(sections, fn file, acc ->
      add_file_snippet(acc, workspace.head, file, 1, "related_context")
    end)
  end

  defp add_file_snippet(sections, root, file, line, type) do
    path = Path.join(root, safe_relative_path(file))

    if File.regular?(path) do
      content = File.read!(path)

      if text?(content) do
        [
          section(
            "#{type}:#{file}:#{line}",
            type,
            file,
            "#{type} for #{file} around line #{line}.",
            line_window(content, line, 35)
          )
          | sections
        ]
      else
        sections
      end
    else
      sections
    end
  end

  defp parse_diff_hunks(diff) do
    diff
    |> String.split(~r/^diff --git /m, trim: true)
    |> Enum.reduce(%{}, fn chunk, acc ->
      file =
        case Regex.run(~r/a\/(.+?) b\/(.+?)(?:\n|$)/, "diff --git " <> chunk) do
          [_line, _old, new] -> new
          _other -> nil
        end

      if file do
        hunks =
          Regex.scan(
            ~r/^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@.*(?:\n(?:(?!^@@ |^diff --git ).*\n?)*)/m,
            chunk
          )
          |> Enum.map(fn [text, old_start, new_start] ->
            %{
              old_start: int(old_start),
              new_start: int(new_start),
              text: truncate(text, @max_section_bytes)
            }
          end)

        Map.put(acc, file, hunks)
      else
        acc
      end
    end)
  end

  defp changed_files(bench_case) do
    context = bench_case.context || %{}
    allowed = Map.get(context, :allowed) || Map.get(context, "allowed") || context

    allowed
    |> field(:changed_files, [])
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  defp workspace(bench_case) do
    case bench_case.repo do
      %{workspace: %{head: head, base: base}} -> %{head: head, base: base}
      %{"workspace" => %{"head" => head, "base" => base}} -> %{head: head, base: base}
      _other -> nil
    end
  end

  defp budget_sections(sections) do
    {kept, _bytes} =
      Enum.reduce_while(sections, {[], 0}, fn section, {acc, bytes} ->
        section = %{section | content: truncate(section.content, @max_section_bytes)}
        next_bytes = bytes + byte_size(section.content)

        if next_bytes > @max_total_bytes do
          {:halt, {acc, bytes}}
        else
          {:cont, {[section | acc], next_bytes}}
        end
      end)

    kept
    |> Enum.reverse()
    |> Enum.with_index(1)
    |> Enum.map(fn {section, index} -> Map.put(section, :ordinal, index) end)
  end

  defp section(id, type, path, summary, content) do
    %{
      id: id,
      type: type,
      path: path,
      summary: summary,
      content: truncate(content, @max_section_bytes)
    }
  end

  defp line_window(content, center, radius) do
    lines = String.split(content, "\n")
    center = max(int(center), 1)
    first = max(center - radius, 1)
    last = min(center + radius, length(lines))

    lines
    |> Enum.slice((first - 1)..(last - 1)//1)
    |> Enum.with_index(first)
    |> Enum.map_join("\n", fn {line, number} -> "#{number}: #{line}" end)
  end

  defp related_context_file?(path) do
    normalized = String.downcase(path)

    String.contains?(normalized, ["/test", "/tests", "/spec", "_test", ".test.", ".spec."]) or
      Path.basename(normalized) in [
        "package.json",
        "tsconfig.json",
        "pyproject.toml",
        "cargo.toml",
        "cmakelists.txt",
        "go.mod",
        "mix.exs"
      ]
  end

  defp text?(content), do: not String.contains?(content, <<0>>)

  defp truncate(content, max_bytes) do
    content = to_string(content)

    if byte_size(content) > max_bytes do
      binary_part(content, 0, max_bytes) <> "\n...[truncated]"
    else
      content
    end
  end

  defp safe_relative_path(path) do
    path
    |> to_string()
    |> String.replace("\\", "/")
    |> String.trim_leading("/")
    |> Path.split()
    |> Enum.reject(&(&1 in ["", ".", ".."]))
    |> Path.join()
  end

  defp join(values), do: values |> Enum.map(&to_string/1) |> Enum.join(" ") |> normalize()
  defp normalize(value), do: value |> to_string() |> String.downcase() |> String.trim()
  defp int(value) when is_integer(value), do: value
  defp int(value), do: value |> to_string() |> Integer.parse() |> elem(0)

  defp field(map, key, default \\ nil)
  defp field(nil, _key, default), do: default

  defp field(%{} = map, key, default),
    do: Map.get(map, key, Map.get(map, to_string(key), default))

  defp field(_other, _key, default), do: default
end

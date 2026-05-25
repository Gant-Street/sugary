defmodule Sugary.ExternalReviewers do
  def check_pack!(pack_path) do
    pack = Sugary.ReviewerPacks.load!(pack_path)

    pack.reviewers
    |> Enum.map(&availability_for_reviewer/1)
  end

  def render_check(rows) do
    body =
      rows
      |> Enum.map(fn row ->
        "#{pad(row.id, 26)} #{pad(row.status, 11)} #{pad(row.cost_model, 18)} #{pad(row.requires_network, 9)} #{pad(row.safe_to_run, 11)} #{row.reason}"
      end)
      |> Enum.join("\n")

    "Reviewer                  Status      Cost Model        Network  Safe        Reason\n" <>
      body
  end

  def availability_for_reviewer(reviewer) do
    reviewer = string_keyed(reviewer)
    id = reviewer["id"] || "unknown-reviewer"
    enabled = Map.get(reviewer, "enabled", true)

    required_executable = reviewer["required_executable"]
    missing_env = missing_env(reviewer["requires_secrets"] || reviewer["required_env"] || [])
    executable_found? = executable_found?(required_executable)

    cond do
      enabled == false ->
        row(reviewer, "skipped", "disabled", false)

      required_executable not in [nil, ""] and not executable_found? ->
        row(reviewer, "skipped", "missing #{required_executable}", false)

      missing_env != [] ->
        row(reviewer, "skipped", "missing #{Enum.join(missing_env, ", ")}", false)

      true ->
        reason =
          if required_executable in [nil, ""],
            do: "no executable requirement",
            else: "#{required_executable} found"

        row(reviewer, "available", reason, true)
    end
    |> Map.put(:id, id)
  end

  def quality_warnings(claims, input, method) do
    claims
    |> Enum.flat_map(fn claim ->
      claim = atomize(claim)

      []
      |> maybe_warning(blank?(Map.get(claim, :path)), "missing file path")
      |> maybe_warning(is_nil(Map.get(claim, :start_line)), "missing line")
      |> maybe_warning(non_actionable?(Map.get(claim, :claim)), "non-actionable summary")
      |> maybe_warning(no_evidence?(claim), "no evidence text")
      |> maybe_warning(
        outside_changed_files?(claim, input, method),
        "claim outside changed files"
      )
      |> maybe_warning(
        generated_or_vendor?(Map.get(claim, :path)),
        "claim on generated/vendor file"
      )
      |> maybe_warning(not introduced_argument?(claim), "no PR-introducedness argument")
      |> Enum.map(
        &%{claim_id: Map.get(claim, :id) || Map.get(claim, :dedupe_key) || "unknown", warning: &1}
      )
    end)
    |> Kernel.++(duplicate_warnings(claims))
  end

  defp row(reviewer, status, reason, safe?) do
    %{
      id: reviewer["id"],
      status: status,
      reason: reason,
      enabled: Map.get(reviewer, "enabled", true),
      required_executable: reviewer["required_executable"],
      cost_model: reviewer["cost_model"] || "unknown",
      requires_network: Map.get(reviewer, "requires_network", false),
      requires_secrets: reviewer["requires_secrets"] || [],
      safe_to_run: safe?
    }
  end

  defp executable_found?(nil), do: true
  defp executable_found?(""), do: true
  defp executable_found?(executable), do: System.find_executable(to_string(executable)) != nil

  defp missing_env(names) do
    names
    |> List.wrap()
    |> Enum.map(&to_string/1)
    |> Enum.filter(&(System.get_env(&1) in [nil, ""]))
  end

  defp string_keyed(map), do: Enum.into(map, %{}, fn {key, value} -> {to_string(key), value} end)

  defp maybe_warning(warnings, true, warning), do: [warning | warnings]
  defp maybe_warning(warnings, _false, _warning), do: warnings

  defp blank?(value), do: value in [nil, ""]

  defp non_actionable?(summary) do
    summary = summary |> to_string() |> String.trim()
    summary == "" or String.length(summary) < 12
  end

  defp no_evidence?(claim) do
    claim.evidence
    |> List.wrap()
    |> Enum.all?(fn evidence ->
      evidence = atomize(evidence)
      blank?(Map.get(evidence, :summary))
    end)
  end

  defp outside_changed_files?(claim, input, method) do
    if Map.get(method, :allow_outside_changed_files, false) do
      false
    else
      changed = changed_files(input)
      changed != [] and Map.get(claim, :path) not in changed
    end
  end

  defp changed_files(input) do
    context = input.context || %{}
    context[:changed_files] || context["changed_files"] || []
  end

  defp generated_or_vendor?(path) do
    path = path |> to_string() |> String.downcase()

    String.contains?(path, "/vendor/") or String.contains?(path, "generated") or
      String.contains?(path, "/deps/")
  end

  defp introduced_argument?(claim) do
    Map.get(claim, :introduced_by_pr) == true or Map.get(claim, :failure_path) not in [nil, []]
  end

  defp duplicate_warnings(claims) do
    claims
    |> Enum.map(&atomize/1)
    |> Enum.group_by(&(Map.get(&1, :dedupe_key) || Map.get(&1, :id)))
    |> Enum.filter(fn {_key, values} -> length(values) > 1 end)
    |> Enum.flat_map(fn {key, [_first | duplicates]} ->
      Enum.map(duplicates, fn duplicate ->
        %{claim_id: Map.get(duplicate, :id) || key, warning: "duplicate finding"}
      end)
    end)
  end

  defp atomize(%{} = map),
    do: Map.new(map, fn {key, value} -> {atom_key(key), atomize(value)} end)

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value
  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)

  defp pad(value, size) do
    value = to_string(value)
    value <> String.duplicate(" ", max(size - String.length(value), 1))
  end
end

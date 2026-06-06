defmodule Sugary.AgentBus do
  @moduledoc """
  Append-only agent coordination bus.

  The local backend is the source of truth. When requested and available, h5i is
  treated as an optional mirror for REVIEW_REQUEST messages.
  """

  @default_backend "auto"
  @protocol_version "agent-bus-v0"
  @h5i_timeout_ms 5_000

  def new!(opts \\ []) do
    opts = normalize_opts(opts)
    id = opt(opts, "id", "agent-bus-#{timestamp()}")
    requested = opt(opts, "requested_backend", opt(opts, "backend", @default_backend))
    root = Path.expand(opt(opts, "root", Path.join(".sugary/research/agent-bus", id)))
    h5i_path = System.find_executable("h5i")

    effective =
      cond do
        requested in ["h5i", "auto"] and is_binary(h5i_path) -> "h5i"
        true -> "local-jsonl"
      end

    File.mkdir_p!(root)

    bus = %{
      id: id,
      protocol_version: @protocol_version,
      requested_backend: requested,
      effective_backend: effective,
      h5i_available: is_binary(h5i_path),
      h5i_path: h5i_path,
      root: root,
      messages_path: Path.join(root, "messages.jsonl"),
      h5i_events_path: Path.join(root, "h5i-events.jsonl")
    }

    Sugary.Json.write!(Path.join(root, "bus-metadata.json"), metadata(bus))
    bus
  end

  def append!(bus, attrs) when is_map(attrs) do
    attrs = stringify_keys(attrs)

    message =
      %{
        "id" => Map.get(attrs, "id") || message_id(Map.get(attrs, "type", "message")),
        "timestamp" => DateTime.utc_now() |> Calendar.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "run_id" => bus.id,
        "protocol_version" => bus.protocol_version,
        "backend" => bus.effective_backend
      }
      |> Map.merge(attrs)

    append_jsonl!(bus.messages_path, message)
    maybe_mirror_h5i!(bus, message)
    message
  end

  def read!(bus) when is_map(bus), do: read!(bus.messages_path)

  def read!(path) when is_binary(path) do
    path
    |> read_jsonl()
  end

  def summary(bus) do
    messages = read!(bus)
    h5i_events = read_jsonl(bus.h5i_events_path)

    %{
      id: bus.id,
      protocol_version: bus.protocol_version,
      requested_backend: bus.requested_backend,
      effective_backend: bus.effective_backend,
      h5i_available: bus.h5i_available,
      h5i_path: bus.h5i_path,
      messages_path: bus.messages_path,
      h5i_events_path: bus.h5i_events_path,
      message_count: length(messages),
      message_counts_by_type: count_by(messages, "type"),
      h5i_event_count: length(h5i_events),
      h5i_event_counts_by_status: count_by(h5i_events, "status")
    }
  end

  defp maybe_mirror_h5i!(
         %{effective_backend: "h5i"} = bus,
         %{"type" => "REVIEW_REQUEST"} = message
       ) do
    result = run_h5i_review(bus, message)
    append_jsonl!(bus.h5i_events_path, Map.merge(result, %{"message_id" => message["id"]}))
  end

  defp maybe_mirror_h5i!(_bus, _message), do: :ok

  defp run_h5i_review(bus, message) do
    payload = Map.get(message, "payload", %{})
    focus = payload |> Map.get("focus_paths", []) |> List.wrap() |> List.first()
    focus = if focus in [nil, ""], do: ".", else: focus
    branch = Map.get(message, "branch") || "HEAD"
    risk = Map.get(message, "risk") || Map.get(payload, "risk") || "review"
    recipient = Map.get(message, "to") || "codex"

    summary =
      Map.get(message, "summary") || Map.get(payload, "summary") || "Sugary review request"

    from = Map.get(message, "from") || "sugary-orchestrator"

    args = [
      "msg",
      "review",
      "--from",
      from,
      "--branch",
      branch,
      "--focus",
      focus,
      "--risk",
      risk,
      recipient,
      summary
    ]

    task = Task.async(fn -> System.cmd(bus.h5i_path, args, stderr_to_stdout: true) end)

    case Task.yield(task, @h5i_timeout_ms) || Task.shutdown(task, :brutal_kill) do
      {:ok, {stdout, 0}} ->
        %{"status" => "mirrored", "args" => args, "stdout" => stdout}

      {:ok, {stdout, exit_status}} ->
        %{
          "status" => "mirror_failed",
          "args" => args,
          "exit_status" => exit_status,
          "stdout" => stdout
        }

      nil ->
        %{"status" => "mirror_timeout", "args" => args, "timeout_ms" => @h5i_timeout_ms}
    end
  rescue
    error ->
      %{
        "status" => "mirror_error",
        "error" => Exception.message(error)
      }
  end

  defp metadata(bus) do
    Map.take(bus, [
      :id,
      :protocol_version,
      :requested_backend,
      :effective_backend,
      :h5i_available,
      :h5i_path,
      :root,
      :messages_path,
      :h5i_events_path
    ])
  end

  defp append_jsonl!(path, data) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, Sugary.Json.encode!(data) <> "\n", [:append])
  end

  defp read_jsonl(path) do
    if File.exists?(path) do
      path
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Sugary.Json.decode!/1)
    else
      []
    end
  end

  defp count_by(records, key) do
    records
    |> Enum.map(&(Map.get(&1, key) || "unknown"))
    |> Enum.frequencies()
  end

  defp normalize_opts(opts) when is_list(opts) do
    Map.new(opts, fn {key, value} -> {to_string(key), value} end)
  end

  defp normalize_opts(opts) when is_map(opts) do
    Map.new(opts, fn {key, value} -> {to_string(key), value} end)
  end

  defp opt(opts, key, default), do: Map.get(opts, key, default)

  defp stringify_keys(%{} = map) do
    Map.new(map, fn {key, value} -> {to_string(key), stringify_keys(value)} end)
  end

  defp stringify_keys(list) when is_list(list), do: Enum.map(list, &stringify_keys/1)
  defp stringify_keys(value), do: value

  defp message_id(type) do
    suffix = System.unique_integer([:positive, :monotonic])
    "#{String.downcase(to_string(type))}-#{suffix}"
  end

  defp timestamp do
    DateTime.utc_now()
    |> Calendar.strftime("%Y%m%dT%H%M%SZ")
  end
end

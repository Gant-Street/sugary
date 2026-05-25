defmodule Sugary.CommandReviewer do
  alias Sugary.Protocol.ReviewerResult

  @default_timeout_ms 5_000
  @default_limit 65_536
  @cache_root ".sugary/research/replay-cache"
  @protocol_version "reviewer-result-v0"

  def run(method, input) do
    availability = Sugary.ExternalReviewers.availability_for_reviewer(method)

    if availability.safe_to_run do
      run_available(method, input)
    else
      skip_result(method, availability.reason)
    end
  end

  def replay_cache_key(method, input) do
    input_json = Sugary.Json.encode!(input)

    material = %{
      protocol_version: @protocol_version,
      reviewer_id: method.id,
      reviewer_manifest_hash: stable_hash(redacted_method(method)),
      command_hash: stable_hash(%{command: method.command, args: Map.get(method, :args, [])}),
      input_hash: sha256(input_json),
      env_allowlist_hash: env_shape_hash(method),
      tool_version: Map.get(method, :tool_version, "unknown")
    }

    stable_hash(material)
  end

  defp run_available(method, input) do
    replay_mode = Map.get(method, :replay_mode, "live") || "live"
    cache_key = replay_cache_key(method, input)

    case replay_mode do
      "cache-first" ->
        case read_cache(method, cache_key, replay_mode) do
          {:ok, result} -> result
          :miss -> run_live(method, input, cache_key, replay_mode, true)
        end

      "replay-only" ->
        case read_cache(method, cache_key, replay_mode) do
          {:ok, result} -> result
          :miss -> skip_result(method, "replay cache miss", cache_key, replay_mode)
        end

      "refresh" ->
        run_live(method, input, cache_key, replay_mode, true)

      _live ->
        run_live(method, input, cache_key, replay_mode, true)
    end
  end

  defp run_live(method, input, cache_key, replay_mode, write_cache?) do
    started = System.monotonic_time(:millisecond)
    input_json = Sugary.Json.encode!(input)
    env = build_env(method)
    secrets = Map.values(env)

    request = %{
      command: method.command,
      args: Map.get(method, :args, []),
      cwd: Map.get(method, :cwd, "."),
      env: env,
      input: input_json,
      timeout_ms: Map.get(method, :timeout_ms, @default_timeout_ms),
      stdout_limit: Map.get(method, :stdout_limit, @default_limit),
      stderr_limit: Map.get(method, :stderr_limit, @default_limit)
    }

    runner_result = run_process_runner(request)
    duration_ms = System.monotonic_time(:millisecond) - started

    artifact =
      method
      |> build_artifact(runner_result, duration_ms, secrets)
      |> Map.merge(%{
        execution_mode: "live",
        replay_mode: replay_mode,
        cache_key: cache_key,
        cache_hit: false,
        cache_path: cache_path(cache_key),
        network_required: Map.get(method, :requires_network, false),
        secrets_required: Map.get(method, :requires_secrets, []),
        cost_model: Map.get(method, :cost_model, "unknown"),
        tool_version: Map.get(method, :tool_version, "unknown")
      })

    result =
      case parse_success(method, input, runner_result, artifact) do
        {:ok, result} -> result
        {:error, reason} -> failure_result(method, reason, artifact)
      end

    if write_cache?, do: write_cache!(cache_key, result)
    result
  end

  defp read_cache(_method, cache_key, replay_mode) do
    path = cache_path(cache_key)

    if File.exists?(path) do
      result =
        path
        |> Sugary.Json.read!()
        |> atomize()
        |> ReviewerResult.new()
        |> annotate_cached_result(cache_key, replay_mode, path)

      {:ok, result}
    else
      :miss
    end
  end

  defp run_process_runner(request) do
    runner = Path.expand("scripts/command_process_runner.py")

    request_path =
      Path.join(
        System.tmp_dir!(),
        "sugary-command-request-#{System.unique_integer([:positive])}.json"
      )

    try do
      File.write!(request_path, Sugary.Json.encode!(request))

      case System.cmd("python3", [runner, request_path], stderr_to_stdout: false) do
        {stdout, 0} ->
          Sugary.Json.decode!(stdout)

        {stdout, status} ->
          %{
            "stdout" => stdout,
            "stderr" => "command process runner failed",
            "exit_status" => status,
            "timed_out" => false,
            "duration_ms" => 0,
            "stdout_truncated" => false,
            "stderr_truncated" => false,
            "error" => "adapter_runner_failed"
          }
      end
    rescue
      error ->
        %{
          "stdout" => "",
          "stderr" => Exception.message(error),
          "exit_status" => 1,
          "timed_out" => false,
          "duration_ms" => 0,
          "stdout_truncated" => false,
          "stderr_truncated" => false,
          "error" => "adapter_runner_exception"
        }
    after
      File.rm(request_path)
    end
  end

  defp parse_success(_method, _input, %{"timed_out" => true}, _artifact), do: {:error, "timeout"}

  defp parse_success(_method, _input, %{"error" => error}, _artifact)
       when is_binary(error) and error != "",
       do: {:error, error}

  defp parse_success(_method, _input, %{"exit_status" => status}, _artifact) when status != 0,
    do: {:error, "non_zero_exit"}

  defp parse_success(method, input, %{"stdout" => stdout}, artifact) do
    with {:ok, decoded} <- decode_stdout(stdout),
         {:ok, result} <- validate_result(method, decoded) do
      quality_warnings = Sugary.ExternalReviewers.quality_warnings(result.claims, input, method)

      {:ok,
       %{
         result
         | artifacts: [Map.put(artifact, :quality_warnings, quality_warnings)],
           cost: Map.get(method, :estimated_cost_usd, result.cost || 0.0)
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp decode_stdout(stdout) do
    {:ok, Sugary.Json.decode!(stdout)}
  rescue
    _error -> {:error, "invalid_json"}
  end

  defp validate_result(method, decoded) do
    attrs = atomize(decoded)
    result = ReviewerResult.new(attrs)

    Enum.each(result.claims, fn claim ->
      Sugary.Protocol.ReviewClaim.new(atomize(claim))
    end)

    {:ok,
     %{
       result
       | reviewer_id: method.id,
         method_id: method.id,
         class: Map.get(method, :class, "research")
     }}
  rescue
    _error -> {:error, "schema_invalid_json"}
  end

  defp failure_result(method, reason, artifact) do
    ReviewerResult.new(%{
      reviewer_id: method.id,
      method_id: method.id,
      class: Map.get(method, :class, "research"),
      claims: [],
      cost: Map.get(method, :estimated_cost_usd, 0.0),
      latency_ms: artifact.duration_ms,
      artifacts: [Map.put(artifact, :failure_reason, reason)],
      errors: [%{reason: reason}]
    })
  end

  defp skip_result(method, reason, cache_key \\ nil, replay_mode \\ nil) do
    ReviewerResult.new(%{
      reviewer_id: method.id,
      method_id: method.id,
      class: Map.get(method, :class, "research"),
      claims: [],
      cost: 0.0,
      latency_ms: 0,
      artifacts: [
        %{
          adapter: "command",
          command: Map.get(method, :command),
          args: Map.get(method, :args, []),
          execution_mode: "skip",
          replay_mode: replay_mode || Map.get(method, :replay_mode, "live"),
          cache_key: cache_key,
          cache_hit: false,
          estimated_cost_usd: Map.get(method, :estimated_cost_usd, 0.0),
          cost_model: Map.get(method, :cost_model, "unknown"),
          network_required: Map.get(method, :requires_network, false),
          secrets_required: Map.get(method, :requires_secrets, []),
          failure_reason: reason
        }
      ],
      errors: [%{reason: "skipped", detail: reason}]
    })
  end

  defp build_artifact(method, runner_result, duration_ms, secrets) do
    stdout = Map.get(runner_result, "stdout", "")
    stderr = Map.get(runner_result, "stderr", "")

    %{
      adapter: "command",
      command: method.command,
      args: Map.get(method, :args, []),
      cwd: Map.get(method, :cwd, "."),
      network: Map.get(method, :network, "inherit"),
      metadata: Map.get(method, :metadata, %{}),
      artifact_fields: Map.get(method, :artifact_fields, []),
      raw_stdout: Sugary.Redactor.redact(stdout, secrets),
      raw_stderr: Sugary.Redactor.redact(stderr, secrets),
      exit_status: Map.get(runner_result, "exit_status"),
      timed_out: Map.get(runner_result, "timed_out", false),
      duration_ms: Map.get(runner_result, "duration_ms", duration_ms),
      stdout_truncated: Map.get(runner_result, "stdout_truncated", false),
      stderr_truncated: Map.get(runner_result, "stderr_truncated", false),
      estimated_cost_usd: Map.get(method, :estimated_cost_usd, 0.0),
      failure_reason: Map.get(runner_result, "error")
    }
  end

  defp write_cache!(cache_key, result) do
    path = cache_path(cache_key)
    path |> Path.dirname() |> File.mkdir_p!()
    Sugary.Json.write!(path, result)
  end

  defp annotate_cached_result(result, cache_key, replay_mode, path) do
    artifact =
      result.artifacts
      |> List.wrap()
      |> List.first(%{})
      |> Map.merge(%{
        execution_mode: "replay",
        replay_mode: replay_mode,
        cache_key: cache_key,
        cache_hit: true,
        cache_path: path
      })

    %{result | artifacts: [artifact], errors: result.errors || []}
  end

  defp cache_path(cache_key), do: Path.join(@cache_root, "#{cache_key}.json")

  defp redacted_method(method) do
    method
    |> Map.drop([:env, :replay_mode])
    |> Map.update(:env_allowlist, [], &List.wrap/1)
    |> Map.update(:requires_secrets, [], &List.wrap/1)
  end

  defp env_shape_hash(method) do
    explicit_names =
      method
      |> Map.get(:env, [])
      |> List.wrap()
      |> Enum.flat_map(&env_entry_names/1)

    %{
      env_names: Enum.sort(explicit_names),
      allowlist:
        method
        |> Map.get(:env_allowlist, [])
        |> List.wrap()
        |> Enum.map(&to_string/1)
        |> Enum.sort(),
      required:
        method
        |> Map.get(:requires_secrets, [])
        |> List.wrap()
        |> Enum.map(&to_string/1)
        |> Enum.sort()
    }
    |> stable_hash()
  end

  defp env_entry_names(%{} = map), do: Enum.map(map, fn {key, _value} -> to_string(key) end)

  defp env_entry_names(entry) do
    entry
    |> to_string()
    |> String.split("=", parts: 2)
    |> List.first()
    |> List.wrap()
  end

  defp stable_hash(value), do: value |> Sugary.Json.encode!() |> sha256()

  defp sha256(binary) do
    :crypto.hash(:sha256, binary)
    |> Base.encode16(case: :lower)
  end

  defp build_env(method) do
    explicit =
      method
      |> Map.get(:env, [])
      |> List.wrap()
      |> Enum.flat_map(&parse_env_entry/1)
      |> Map.new()

    allowlisted =
      method
      |> Map.get(:env_allowlist, [])
      |> List.wrap()
      |> Enum.reduce(%{}, fn name, acc ->
        case System.get_env(to_string(name)) do
          nil -> acc
          value -> Map.put(acc, to_string(name), value)
        end
      end)

    Map.merge(allowlisted, explicit)
  end

  defp parse_env_entry(%{} = map),
    do: Enum.map(map, fn {key, value} -> {to_string(key), to_string(value)} end)

  defp parse_env_entry(entry) do
    case String.split(to_string(entry), "=", parts: 2) do
      [key, value] -> [{key, value}]
      _ -> []
    end
  end

  defp atomize(%{} = map),
    do: Map.new(map, fn {key, value} -> {atom_key(key), atomize(value)} end)

  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(value), do: value

  defp atom_key(key) when is_atom(key), do: key
  defp atom_key(key) when is_binary(key), do: String.to_atom(key)
end

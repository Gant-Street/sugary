defmodule Sugary.Json do
  def encode!(data) do
    data
    |> jsonable()
    |> :json.encode()
    |> IO.iodata_to_binary()
  end

  def decode!(binary) when is_binary(binary) do
    binary
    |> :json.decode()
    |> null_to_nil()
  end

  def write!(path, data) do
    path |> Path.dirname() |> File.mkdir_p!()
    File.write!(path, encode!(data) <> "\n")
  end

  def read!(path), do: path |> File.read!() |> decode!()

  defp jsonable(%module{} = struct) when is_atom(module) do
    struct
    |> Map.from_struct()
    |> jsonable()
  end

  defp jsonable(%{} = map) do
    Map.new(map, fn {key, value} -> {key_to_binary(key), jsonable(value)} end)
  end

  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(value) when is_boolean(value), do: value
  defp jsonable(nil), do: :null
  defp jsonable(:null), do: :null
  defp jsonable(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable(value), do: value

  defp null_to_nil(:null), do: nil
  defp null_to_nil(%{} = map), do: Map.new(map, fn {key, value} -> {key, null_to_nil(value)} end)
  defp null_to_nil(list) when is_list(list), do: Enum.map(list, &null_to_nil/1)
  defp null_to_nil(value), do: value

  defp key_to_binary(key) when is_atom(key), do: Atom.to_string(key)
  defp key_to_binary(key), do: to_string(key)
end

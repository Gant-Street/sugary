defmodule Sugary.Redactor do
  @secret_name ~r/(?:_KEY|_TOKEN|_SECRET|PASSWORD|GITHUB_TOKEN|OPENAI_API_KEY|ANTHROPIC_API_KEY|GOOGLE_API_KEY)$/i

  def redact(text, values \\ []) when is_binary(text) do
    secret_values(values)
    |> Enum.reduce(text, fn secret, acc ->
      if secret == "" do
        acc
      else
        String.replace(acc, secret, "[REDACTED]")
      end
    end)
  end

  def secret_values(configured_values \\ []) do
    env_secrets =
      System.get_env()
      |> Enum.filter(fn {name, value} ->
        Regex.match?(@secret_name, name) and value not in [nil, ""]
      end)
      |> Enum.map(fn {_name, value} -> value end)

    (List.wrap(configured_values) ++ env_secrets)
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&to_string/1)
    |> Enum.uniq()
  end

  def secret_env_name?(name), do: Regex.match?(@secret_name, to_string(name))
end

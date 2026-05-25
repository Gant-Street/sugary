defmodule Sugary.BenchmarkAdapter do
  @callback fetch(keyword()) :: {:ok, String.t()} | {:error, String.t()}
  @callback list_cases(keyword()) :: {:ok, [map()]} | {:error, String.t()}
end

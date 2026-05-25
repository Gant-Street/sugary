defmodule Sugary.MixProject do
  use Mix.Project

  def project do
    [
      app: :sugary,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: [main_module: Sugary.CLI],
      deps: []
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end
end

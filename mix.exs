defmodule Sari.MixProject do
  use Mix.Project

  def project do
    [
      app: :sari,
      version: "0.1.0",
      elixir: "~> 1.19",
      start_permanent: Mix.env() == :prod,
      escript: escript(),
      aliases: aliases()
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :public_key, :ssl]
    ]
  end

  defp aliases do
    [
      validate: ["format --check-formatted", "test"]
    ]
  end

  defp escript do
    [
      main_module: Sari.CLI,
      name: "sari"
    ]
  end
end

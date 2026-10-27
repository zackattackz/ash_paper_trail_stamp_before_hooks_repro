defmodule Repro.MixProject do
  use Mix.Project

  def project do
    [
      app: :repro,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger], mod: {Repro.Application, []}]
  end

  defp aliases do
    [test: ["ash.setup --quiet", "test"]]
  end

  defp deps do
    [
      {:ash, "== 3.37.2"},
      {:ash_postgres, "== 2.15.2"},
      {:ash_paper_trail, "== 0.8.1"},
      {:ash_json_api, "== 1.8.0"}
    ]
  end
end

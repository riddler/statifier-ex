defmodule Statifier.MixProject do
  use Mix.Project

  @version "2.0.0-dev"
  @source_url "https://github.com/riddler/statifier-ex"

  def project do
    [
      app: :statifier,
      version: @version,
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      name: "Statifier",
      description: "A W3C SCXML-conformant statecharts engine for Elixir",
      source_url: @source_url,
      package: package(),
      test_coverage: [tool: ExCoveralls],
      # The regression ratchet ships as mix tasks, so Mix itself has to be in
      # the PLT or every Mix.shell/0 call reads as an unknown function.
      dialyzer: [plt_add_apps: [:mix, :ex_unit]],
      preferred_cli_env: [
        coveralls: :test,
        "coveralls.detail": :test,
        "coveralls.html": :test
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Hex package metadata. Nothing is published before 2.0.0 (ADR-0061); this
  # exists so that publishing is a decision rather than a project.
  defp package do
    [
      name: "statifier",
      licenses: ["MIT"],
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md),
      links: %{
        "GitHub" => @source_url,
        "Changelog" => "#{@source_url}/blob/main/CHANGELOG.md"
      }
    ]
  end

  defp deps do
    [
      {:predicator, "~> 9.0"},
      {:saxy, "~> 1.6"},
      {:telemetry, "~> 1.3"},

      # Dev / test
      {:ex_quality, "~> 0.13", only: :dev, runtime: false},
      # 1.8.0-dev, tracked as a git dep, for exactly one check:
      # Credo.Check.Readability.SpecParameterNames, which is absent from 1.7.x.
      # mix.lock pins the SHA, so builds stay reproducible.
      {:credo, github: "rrrene/credo", branch: "master", only: [:dev, :test], runtime: false},
      {:dialyxir, "~> 1.4", only: [:dev, :test], runtime: false},
      {:excoveralls, "~> 0.18", only: :test},
      {:sobelow, "~> 0.14", only: :dev, runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      {:benchee, "~> 1.3", only: :dev},
      {:doctor, "~> 0.23", only: :dev, runtime: false}
    ]
  end
end

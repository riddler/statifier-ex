defmodule Statifier.MixProject do
  use Mix.Project

  @version "2.1.0"
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
      docs: docs(),
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

  # Hexdocs configuration. These paths are read off the publisher's disk at
  # `mix docs` time and need no entry in package()'s files: list - the docs
  # tarball hexdocs hosts is built separately from the package tarball
  # `mix deps.get` fetches. The ADR set rides along because the user-facing
  # guides cite individual records by relative link.
  defp docs do
    [
      name: "Statifier",
      source_ref: "v#{@version}",
      canonical: "https://hexdocs.pm/statifier",
      source_url: @source_url,
      main: "readme",
      extras:
        [
          "README.md",
          "CHANGELOG.md",
          "docs/architecture.md",
          "docs/datamodel.md",
          "docs/extending.md",
          "docs/persistence.md",
          "docs/durable-timers.md",
          "docs/observability.md",
          "docs/opentelemetry.md",
          "docs/testing-charts.md",
          "docs/chart-patterns.md",
          "docs/family-reference.md",
          {"docs/adr/README.md", [title: "Architecture Decision Records", filename: "adr-index"]}
        ] ++ Enum.sort(Path.wildcard("docs/adr/0*.md")),
      groups_for_extras: [
        Guides: ~r{docs/(?!adr)},
        "Architecture Decision Records": ~r{docs/adr}
      ]
    ]
  end

  # Hex package metadata, in place since ADR-0061 so that publishing is a
  # decision rather than a project; 2.0.0 is that decision (ADR-0066).
  defp package do
    [
      name: "statifier",
      licenses: ["MIT"],
      files: ~w(lib/statifier lib/statifier.ex mix.exs README.md LICENSE CHANGELOG.md),
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
      {:ex_quality, "~> 0.14", only: :dev, runtime: false},
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

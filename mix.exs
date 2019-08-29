defmodule Exstate.MixProject do
  use Mix.Project

  def project do
    [
      app: :exstate,
      version: "0.0.1",
      elixir: "~> 1.8",
      start_permanent: Mix.env() == :prod,
      docs: [extras: ["README.md"]],
      dialyzer: [plt_add_deps: :transitive],
      description: description(),
      package: package(),
      deps: deps()
    ]
  end


  def description, do: "Statecharts for Elixir"

  def package do
    [
      name: :exstate,
      maintainers: ["JohnnyT"],
      licenses: ["MIT"],
      docs: [extras: ["README.md"]],
      links: %{"GitHub" => "https://github.com/riddler/exstate"}
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:ex_doc, ">= 0.0.0", only: :dev},

      {:sweet_xml, ">= 0.0.0"}
    ]
  end
end

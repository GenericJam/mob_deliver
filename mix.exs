defmodule MobDeliver.MixProject do
  use Mix.Project

  @version "0.1.0-dev"
  @source_url "https://github.com/GenericJam/mob_deliver"

  def project do
    [
      app: :mob_deliver,
      version: @version,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      description: description(),
      package: package(),
      source_url: @source_url,
      docs: docs(),
      name: "MobDeliver"
    ]
  end

  def application do
    [
      extra_applications: [:logger],
      mod: {MobDeliver.Application, []}
    ]
  end

  defp description do
    "Content-addressed BEAM delivery for Mob apps — proactive OTA updates + " <>
      "JIT screen delivery (\"your mobile app can be a website\"). Scope + " <>
      "wire format v1 in decisions/2026-09-19-scope-and-wire-format.md."
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Mob" => "https://hexdocs.pm/mob"
      },
      files: ~w(lib priv .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "CHANGELOG.md"
      ]
    ]
  end

  defp deps do
    [
      # The host framework. Client uses Mob.Screen callbacks, Code.load_binary,
      # Mob.data_dir/0, and (when activated) mob_wake for background triggers.
      {:mob, "~> 0.9", only: [:dev, :test], runtime: false},
      # Plugin manifest validator lives here. Dev/test only — the host app
      # supplies mob_dev at build time.
      {:mob_dev, "~> 0.6", only: [:dev, :test], runtime: false},
      # Code quality — same bar as mob + siblings.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      # Docs.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end
end

defmodule MobDeliver.MixProject do
  use Mix.Project

  @version "0.2.0"
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
      files: ~w(lib priv guides decisions .formatter.exs mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: [
        "README.md",
        "guides/operator_manual.md",
        "guides/store_review.md",
        "decisions/2026-09-19-scope-and-wire-format.md",
        "CHANGELOG.md",
        "LICENSE"
      ]
    ]
  end

  defp deps do
    [
      # The host framework (Mob.data_dir/1, Mob.Device, Mob.Screen, router
      # hooks). Every mob app already depends on and starts :mob, so it's
      # compile-time here. 0.9.6 ships the app config to the device and
      # starts plugin OTP applications (and their deps) before on_start.
      # MOB_PATH=../mob tests against an unreleased mob checkout.
      mob_dep(),
      # Plugin manifest validator lives here. Dev/test only — the host app
      # supplies mob_dev at build time.
      {:mob_dev, "~> 0.7.3", only: [:dev, :test], runtime: false},
      # HTTP for the manifest/beam fetches. Runtime dep; ranges cover the
      # Req versions sibling apps already ship on-device.
      {:req, "~> 0.5 or ~> 0.6 or ~> 0.7"},
      # Req.Test stubs need Plug (dev too: mob_dev's bandit requires it there).
      {:plug, "~> 1.18", only: [:dev, :test]},
      # Code quality — Credo + ex_slop (AI-pattern checks) + jump_credo_checks,
      # mirroring mob core's pre-commit gate.
      {:credo, "~> 1.7", only: [:dev, :test], runtime: false},
      {:ex_slop, "~> 0.4", only: [:dev, :test], runtime: false},
      {:jump_credo_checks, "~> 0.1.0", only: [:dev, :test], runtime: false},
      # Docs.
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp mob_dep do
    case System.get_env("MOB_PATH") do
      nil -> {:mob, "~> 0.9.6", runtime: false}
      path -> {:mob, path: path, runtime: false, override: true}
    end
  end
end

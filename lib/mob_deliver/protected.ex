defmodule MobDeliver.Protected do
  @moduledoc false
  # Modules a delivered manifest may never replace: the code that decides
  # what delivered code is trusted. That's mob_deliver itself, mob (its
  # boot path, router hooks, plugin loading), `mob_app_config` (the app's
  # build-time config, which carries the trusted key — MOB-357), and the
  # runtime the signature check runs on (Elixir, :crypto, :public_key).
  # Replacing any of them could swap the trust root or the verifier from
  # inside a delivered update; the trust root must stay what the reviewed
  # native build shipped.

  alias MobDeliver.Manifest

  @apps [:mob_deliver, :mob, :elixir, :crypto, :public_key]
  @keys [":mob_app_config", ":mob_nif"]
  @prefixes ["MobDeliver.", "Mob."]
  @cache {__MODULE__, :keys}

  @doc "Whether the module with manifest key `key` is protected."
  @spec key?(String.t()) :: boolean()
  def key?(key) do
    key in @keys or key in ["MobDeliver", "Mob"] or String.starts_with?(key, @prefixes) or
      MapSet.member?(app_keys(), key)
  end

  @doc "The protected keys a manifest delivers (sorted)."
  @spec in_manifest(Manifest.t()) :: [String.t()]
  def in_manifest(%Manifest{modules: modules}),
    do: modules |> Map.keys() |> Enum.filter(&key?/1) |> Enum.sort()

  # The modules of the protected applications; fixed for the VM's
  # lifetime, so computed once. Loading an application's spec only reads
  # its .app file (it's a no-op if already loaded).
  defp app_keys do
    case :persistent_term.get(@cache, nil) do
      nil ->
        keys =
          for app <- @apps,
              _ = Application.load(app),
              module <- Application.spec(app, :modules) || [],
              into: MapSet.new(),
              do: Manifest.module_key(module)

        :persistent_term.put(@cache, keys)
        keys

      keys ->
        keys
    end
  end
end

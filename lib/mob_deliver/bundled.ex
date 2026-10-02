defmodule MobDeliver.Bundled do
  @moduledoc false
  # The app binary's own (bundled) modules, as files on the code path —
  # what a delivered manifest overrides. Delivered blobs live in the store,
  # which isn't on the code path, so a lookup here always finds the bundled
  # file even while a delivered version of the module is loaded.
  #
  # Fingerprints are `:beam_lib.md5/1` of the file: the MD5 of the
  # significant chunks only (code, atoms, exports, …), so stripping debug
  # info or signing doesn't change it, while any code change does.

  @type index :: %{String.t() => Path.t()}

  @doc "Every `.beam` file on the code path, by file name (first on the path wins, like the code server)."
  @spec index() :: index()
  def index do
    :code.get_path()
    |> Enum.reverse()
    |> Enum.reduce(%{}, fn dir, acc ->
      case File.ls(dir) do
        {:ok, names} ->
          for name <- names, String.ends_with?(name, ".beam"), into: acc do
            {name, Path.join(List.to_string(dir), name)}
          end

        {:error, _} ->
          acc
      end
    end)
  end

  @doc """
  `key => md5 (lowercase hex)` for each manifest key that has a bundled
  `.beam`. Keys without one are left out. No atoms are created.
  """
  @spec md5s(index(), [String.t()]) :: %{String.t() => String.t()}
  def md5s(index, keys) do
    for key <- keys,
        path = Map.get(index, beam_name(key)),
        path != nil,
        {:ok, md5} <- [file_md5(path)],
        into: %{},
        do: {key, md5}
  end

  @doc "The fingerprint of `.beam` bytes (e.g. a delivered blob), or `:error`."
  @spec md5(binary()) :: {:ok, String.t()} | :error
  def md5(binary) when is_binary(binary) do
    case :beam_lib.md5(binary) do
      {:ok, {_module, md5}} -> {:ok, Base.encode16(md5, case: :lower)}
      {:error, :beam_lib, _} -> :error
    end
  end

  defp file_md5(path) do
    case File.read(path) do
      {:ok, binary} -> md5(binary)
      {:error, _} -> :error
    end
  end

  # The file a module key's code is loaded from: "MyApp.Home" →
  # "Elixir.MyApp.Home.beam", ":my_mod" → "my_mod.beam".
  defp beam_name(":" <> name), do: name <> ".beam"
  defp beam_name(name), do: "Elixir." <> name <> ".beam"
end

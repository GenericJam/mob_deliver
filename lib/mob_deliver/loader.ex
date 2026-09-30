defmodule MobDeliver.Loader do
  @moduledoc false
  # Loads verified .beam bytes into the running VM. Callers get bytes only
  # from MobDeliver.Store.read_blob/2, which re-hashes them; this module adds
  # the identity check (the beam must define the module the manifest names)
  # and never kills processes to make room.

  @type error ::
          {:module_mismatch, module() | nil}
          | :old_code_in_use
          | {:load_failed, term()}

  @doc "Loads `binary` as `module`. `source` is what `:code.which/1` will report."
  @spec load(module(), binary(), Path.t()) :: :ok | {:error, error()}
  def load(module, binary, source) do
    with :ok <- check_identity(module, binary),
         :ok <- make_room(module) do
      case :code.load_binary(module, String.to_charlist(source), binary) do
        {:module, ^module} -> :ok
        {:error, reason} -> {:error, {:load_failed, reason}}
      end
    end
  end

  @doc "Modules `binary` makes remote calls into (from its imports chunk)."
  @spec imported_modules(binary()) :: [module()]
  def imported_modules(binary) do
    case :beam_lib.chunks(binary, [:imports]) do
      {:ok, {_module, [imports: imports]}} -> imports |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
      {:error, :beam_lib, _} -> []
    end
  end

  defp check_identity(module, binary) do
    case :beam_lib.info(binary) do
      info when is_list(info) ->
        case Keyword.get(info, :module) do
          ^module -> :ok
          other -> {:error, {:module_mismatch, other}}
        end

      {:error, :beam_lib, _} ->
        {:error, {:module_mismatch, nil}}
    end
  end

  # Loading makes the current version "old"; a second old version isn't
  # allowed. Purge it only if nothing still runs it — killing processes to
  # install an update is never acceptable.
  defp make_room(module) do
    if :erlang.check_old_code(module) and not :code.soft_purge(module),
      do: {:error, :old_code_in_use},
      else: :ok
  end
end

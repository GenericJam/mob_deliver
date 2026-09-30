defmodule MobDeliver.Store do
  @moduledoc """
  On-device content-addressed store: the primitive under both the update
  poll and JIT `resolve/1`.

  Layout under the store root:

      blobs/<sha256>   .beam bytes, named by their SHA-256
      state            the active and previous signed manifest bodies

  Files are written with `MobDeliver.Disk.atomic_write/2` (tmp → fsync →
  rename → fsync dir), so a path holds its old or its complete new bytes
  after any crash, and an acknowledged write survives power loss. Blobs
  are re-hashed on every read; a mismatch reports `:corrupt` and the next
  `put_blob/3` replaces the file.

  `state` carries the signed manifest bodies themselves: replacing it is
  the single atomic step that switches slots, and nothing in it is used
  without re-verification. At boot the active body is re-verified
  (signature, app, channel); if it fails, the previous body is tried, and
  otherwise the store runs the app's bundled code.

  This process holds the slots it has published; compare-and-set for
  `activate/4` and `rollback/3` is against that, so what callers see via
  `active_id/1` is always the token that works — even if persisting a
  reconciliation failed (it's retried with the next write). Lookups read a
  protected ETS table and never go through the process.
  """

  use GenServer

  require Logger

  alias MobDeliver.{Disk, Manifest}

  @type server :: atom()
  @type sha :: Manifest.sha256()
  @typedoc "SHA-256 (lowercase hex) of a signed manifest body."
  @type manifest_id :: String.t()
  @type verify_fun :: (binary() -> {:ok, Manifest.t()} | {:error, term()})

  @empty_slots %{active: nil, previous: nil}

  @doc "Starts a store. Options: `:name` (default `#{inspect(__MODULE__)}`), `:root` (default `MobDeliver.Config.root/0`)."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, {name, Keyword.get(opts, :root)}, name: name)
  end

  # ── blobs (no process hop) ──────────────────────────────────────────────

  @doc "Stores `binary` under `sha` after checking that it hashes to `sha`. Idempotent."
  @spec put_blob(server(), sha(), binary()) ::
          :ok | {:error, :sha_mismatch | :invalid_sha | term()}
  def put_blob(server, sha, binary) do
    cond do
      not valid_sha?(sha) -> {:error, :invalid_sha}
      sha256(binary) != sha -> {:error, :sha_mismatch}
      true -> Disk.atomic_write(blob_path(server, sha), binary)
    end
  end

  @doc "Reads the blob for `sha`, re-verifying its hash."
  @spec read_blob(server(), sha()) ::
          {:ok, binary()} | {:error, :missing | :corrupt | :invalid_sha | File.posix()}
  def read_blob(server, sha) do
    with true <- valid_sha?(sha) || {:error, :invalid_sha},
         {:ok, bin} <- Disk.read(blob_path(server, sha)) do
      # A mismatched file is left in place: unlinking it could delete a
      # concurrent put_blob's atomic replacement.
      if sha256(bin) == sha, do: {:ok, bin}, else: {:error, :corrupt}
    end
  end

  @spec has_blob?(server(), sha()) :: boolean()
  def has_blob?(server, sha), do: match?({:ok, _}, read_blob(server, sha))

  @doc "Where the blob for `sha` lives (reported by `:code.which/1` once loaded)."
  @spec blob_path(server(), sha()) :: Path.t()
  def blob_path(server, sha), do: Path.join([root(server), "blobs", sha])

  # ── active manifest ─────────────────────────────────────────────────────

  @doc "The SHA of `module_key` in the active manifest."
  @spec lookup(server(), String.t()) :: {:ok, sha()} | :error
  def lookup(server, module_key) do
    case active(server) do
      {_id, %Manifest{modules: modules}} -> Map.fetch(modules, module_key)
      nil -> :error
    end
  end

  @doc "The active manifest and its id, or `nil` when running on bundled code only."
  @spec active(server()) :: {manifest_id(), Manifest.t()} | nil
  def active(server) do
    case :ets.lookup(server, :active) do
      [{:active, id, manifest}] -> {id, manifest}
      [] -> nil
    end
  end

  @doc "The active manifest id — the compare-and-set token for `activate/4` and `rollback/3`."
  @spec active_id(server()) :: manifest_id() | nil
  def active_id(server) do
    case active(server) do
      {id, _} -> id
      nil -> nil
    end
  end

  @doc """
  Loads the persisted slots and publishes the active manifest.

  An active body that fails `verify` is replaced by the previous one if
  that verifies, else by bundled code (`nil`). Never raises on bad or
  missing files.
  """
  @spec boot(server(), verify_fun()) :: {:ok, Manifest.t() | nil}
  def boot(server, verify), do: GenServer.call(server, {:boot, verify})

  @doc """
  Makes `body` (already verified into `manifest`) the active manifest; the
  current one becomes previous. If the active manifest is no longer
  `expected_active` (another install or rollback happened), returns
  `{:error, :conflict}` and changes nothing.
  """
  @spec activate(server(), binary(), Manifest.t(), manifest_id() | nil) ::
          :ok | {:error, :conflict | term()}
  def activate(server, body, %Manifest{} = manifest, expected_active),
    do: GenServer.call(server, {:activate, body, manifest, expected_active})

  @doc """
  Drops the active manifest `expected_active` and reinstates the previous
  one (re-verified with `verify`), or bundled code if there is none or it
  no longer verifies. `{:error, :conflict}` if something else is active.
  """
  @spec rollback(server(), manifest_id(), verify_fun()) ::
          {:ok, Manifest.t() | nil} | {:error, :conflict | term()}
  def rollback(server, expected_active, verify),
    do: GenServer.call(server, {:rollback, expected_active, verify})

  @doc "The id a signed manifest body is known by."
  @spec manifest_id(binary()) :: manifest_id()
  def manifest_id(body), do: sha256(body)

  @spec root(server()) :: Path.t()
  def root(server), do: :ets.lookup_element(server, :root, 2)

  # ── server ──────────────────────────────────────────────────────────────

  @impl true
  def init({name, root}) do
    table = :ets.new(name, [:named_table, :protected, read_concurrency: true])
    # Path only; directories are created (non-raising) on first write.
    :ets.insert(table, {:root, root || MobDeliver.Config.root()})
    {:ok, %{table: table, slots: @empty_slots}}
  end

  @impl true
  def handle_call({:boot, verify}, _from, %{table: table} = s) do
    persisted = read_slots(table)
    {published, slots} = reconcile(persisted, verify)
    if slots != persisted, do: persist(table, slots)
    {:reply, {:ok, publish(table, published)}, %{s | slots: slots}}
  end

  def handle_call({:activate, body, manifest, expected}, _from, %{table: table, slots: slots} = s) do
    id = manifest_id(body)

    cond do
      body_id(slots.active) != expected ->
        {:reply, {:error, :conflict}, s}

      id == expected ->
        {:reply, :ok, s}

      true ->
        new_slots = %{active: body, previous: slots.active}

        case persist(table, new_slots) do
          :ok ->
            publish(table, {id, manifest})
            {:reply, :ok, %{s | slots: new_slots}}

          {:error, _} = error ->
            {:reply, error, s}
        end
    end
  end

  def handle_call({:rollback, expected, verify}, _from, %{table: table, slots: slots} = s) do
    if body_id(slots.active) == expected and expected != nil do
      {published, new_slots} =
        case slots.previous && check(slots.previous, verify) do
          {:ok, published} -> {published, %{active: slots.previous, previous: nil}}
          _ -> {nil, @empty_slots}
        end

      case persist(table, new_slots) do
        :ok -> {:reply, {:ok, publish(table, published)}, %{s | slots: new_slots}}
        {:error, _} = error -> {:reply, error, s}
      end
    else
      {:reply, {:error, :conflict}, s}
    end
  end

  # Insert-or-delete in one step, so readers never see a gap mid-boot.
  defp publish(table, {id, manifest}) do
    :ets.insert(table, {:active, id, manifest})
    manifest
  end

  defp publish(table, nil) do
    :ets.delete(table, :active)
    nil
  end

  defp reconcile(%{active: nil} = slots, _verify), do: {nil, slots}

  defp reconcile(%{active: active, previous: previous} = slots, verify) do
    case check(active, verify) do
      {:ok, published} ->
        {published, slots}

      {:error, reason} ->
        Logger.warning("mob_deliver: active manifest rejected at boot (#{inspect(reason)})")

        case previous && check(previous, verify) do
          {:ok, published} ->
            Logger.warning("mob_deliver: falling back to the previous manifest")
            {published, %{active: previous, previous: nil}}

          _ ->
            Logger.warning("mob_deliver: no usable manifest; running bundled code")
            {nil, @empty_slots}
        end
    end
  end

  defp check(body, verify) do
    case verify.(body) do
      {:ok, manifest} -> {:ok, {manifest_id(body), manifest}}
      {:error, _} = error -> error
    end
  end

  # ── disk ────────────────────────────────────────────────────────────────

  defp read_slots(table) do
    case Disk.read_term(state_path(table)) do
      {:ok, %{active: active, previous: previous}}
      when (is_binary(active) or is_nil(active)) and (is_binary(previous) or is_nil(previous)) ->
        %{active: active, previous: previous}

      {:error, :missing} ->
        @empty_slots

      other ->
        # The state file is untrusted input: anything but two optional bodies is rejected.
        Logger.warning(
          "mob_deliver: store state unreadable (#{inspect(other)}); treating as empty"
        )

        @empty_slots
    end
  end

  defp persist(table, slots) do
    with {:error, reason} = error <-
           Disk.atomic_write(state_path(table), :erlang.term_to_binary(slots)) do
      Logger.warning("mob_deliver: could not persist store state (#{inspect(reason)})")
      error
    end
  end

  defp body_id(nil), do: nil
  defp body_id(body), do: manifest_id(body)

  defp state_path(server), do: Path.join(root(server), "state")

  defp valid_sha?(sha),
    do:
      is_binary(sha) and byte_size(sha) == 64 and
        match?({:ok, _}, Base.decode16(sha, case: :lower))

  defp sha256(data), do: Base.encode16(:crypto.hash(:sha256, data), case: :lower)
end

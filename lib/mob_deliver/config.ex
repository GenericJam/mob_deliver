defmodule MobDeliver.Config do
  @moduledoc false
  # One place that reads `config :mob_deliver, ...`, all of it at runtime.
  # On a device the config is the app's own `config/*.exs`, evaluated when
  # the native build was made and shipped inside it (mob's `mob_app_config`
  # module, loaded before any plugin starts); delivered code can't replace
  # that module (MobDeliver.Protected). Reading at runtime means changing
  # the config never needs a dependency recompile (MOB-357).

  @spec trusted_publish_key() :: String.t() | nil
  def trusted_publish_key, do: get(:trusted_publish_key)

  @doc """
  Root directory of the on-device store: `<data dir>/mob_deliver` unless
  configured. Resolves the path like `Mob.data_dir/0` but without its
  `mkdir_p!`, so a filesystem problem surfaces as `{:error, _}` from store
  writes instead of crashing application start.
  """
  @spec root() :: Path.t()
  def root do
    get(:root) ||
      Path.join(
        System.get_env("MOB_DATA_DIR") || System.get_env("HOME") || File.cwd!(),
        "mob_deliver"
      )
  end

  @doc "Update-check interval in ms (default one hour); `false` disables timed checks."
  @spec poll_interval() :: pos_integer() | false
  def poll_interval do
    case get(:poll_interval) do
      nil -> :timer.hours(1)
      value -> value
    end
  end

  @doc """
  Minimum ms between manifest fetches triggered by JIT misses (default
  30s); within it, misses reuse the last result.
  """
  @spec refresh_interval() :: non_neg_integer()
  def refresh_interval, do: get(:refresh_interval) || 30_000

  # This binary's store version, for the update gate: `config :mob_deliver,
  # :app_version` if set, else `Mob.Device.app_version/0` (mob with the
  # native accessor), else `nil`, which leaves the gate open.
  @spec app_version() :: String.t() | nil
  def app_version, do: get(:app_version) || native_app_version()

  @native_version {__MODULE__, :native_app_version}

  # The running binary's version never changes within a VM, so it's read
  # once. Off-device mob's NIF isn't loaded: nil.
  defp native_app_version do
    case :persistent_term.get(@native_version, :unread) do
      :unread ->
        version = read_native_app_version()
        :persistent_term.put(@native_version, version)
        version

      version ->
        version
    end
  end

  defp read_native_app_version do
    case Mob.Device.app_version() do
      version when is_binary(version) and version != "" -> version
      _ -> nil
    end
  catch
    _, _ -> nil
  end

  @spec app() :: String.t() | nil
  def app, do: get(:app)

  @spec channel() :: String.t() | nil
  def channel do
    case get(:channel) do
      nil -> nil
      channel -> to_string(channel)
    end
  end

  @doc "Options for `MobDeliver.Client` calls."
  @spec client_opts() :: keyword()
  def client_opts do
    [
      endpoint: get(:endpoint),
      app: app(),
      channel: channel(),
      trusted_publish_key: trusted_publish_key(),
      req_options: get(:req_options) || []
    ]
  end

  @doc """
  The settings update checks can't run without, if unset. On a device
  `config :mob_deliver` only exists if the build shipped the app config
  (mob >= 0.9.6 with its mob_dev); `trusted_publish_key` is compiled in.
  """
  @spec missing() :: [atom()]
  def missing do
    required = [
      trusted_publish_key: trusted_publish_key(),
      endpoint: get(:endpoint),
      app: app(),
      channel: channel()
    ]

    for {key, nil} <- required, do: key
  end

  @spec get(atom()) :: term()
  def get(key), do: Application.get_env(:mob_deliver, key)
end

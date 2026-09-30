defmodule MobDeliver.Config do
  @moduledoc false
  # One place that reads `config :mob_deliver, ...`. Everything except the
  # trusted key is runtime config; the key is baked in at compile time so the
  # trust root ships inside the reviewed binary.

  @trusted_publish_key Application.compile_env(:mob_deliver, :trusted_publish_key)

  @spec trusted_publish_key() :: String.t() | nil
  def trusted_publish_key, do: @trusted_publish_key

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

  @doc """
  How long after boot the app counts as stable if it doesn't call
  `MobDeliver.mark_stable/0` first (default 5s).
  """
  @spec stable_after() :: non_neg_integer()
  def stable_after, do: get(:stable_after) || 5_000

  @doc "Update-check interval in ms (default one hour); `false` disables timed checks."
  @spec poll_interval() :: pos_integer() | false
  def poll_interval do
    case get(:poll_interval) do
      nil -> :timer.hours(1)
      value -> value
    end
  end

  # This binary's store version, for the update gate: `config :mob_deliver,
  # :app_version` if set, else `Mob.Device.app_version/0` (mob with the
  # native accessor), else `nil`, which leaves the gate open.
  @spec app_version() :: String.t() | nil
  def app_version, do: get(:app_version) || native_app_version()

  @device Mob.Device

  # Called dynamically: the accessor is newer than the mob this compiles
  # against, and off-device its NIF isn't loaded.
  defp native_app_version do
    if Code.ensure_loaded?(@device) and function_exported?(@device, :app_version, 0) do
      case apply(@device, :app_version, []) do
        version when is_binary(version) and version != "" -> version
        _ -> nil
      end
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

  @spec get(atom()) :: term()
  def get(key), do: Application.get_env(:mob_deliver, key)
end

defmodule MobDeliver.Config do
  @moduledoc false
  # One place that reads `config :mob_deliver, ...`, all of it at runtime,
  # so changing the config never needs a dependency recompile (MOB-357).
  #
  # The settings that decide what is trusted — `trusted_publish_key`,
  # `app`, `channel`, and `app_version` (the update gate) — are read from
  # the build itself whenever it has its config module: mob_dev evaluates
  # the app's `config/*.exs` at build time into `mob_app_config`, a module
  # inside the signed native build, which delivered code can't replace
  # (MobDeliver.Protected). Not from the application environment: anything
  # running in the app can call `Application.put_env/3`. Without that module
  # (host tests, dev, an app built by an older mob_dev) they come from the
  # environment. Everything else comes from the environment: `endpoint` and
  # `req_options` only decide where and how manifests are fetched (each is
  # still verified against the build's key, so changing them can only make
  # checks fail), the intervals only how often, `root` is read once when the
  # store starts, and `store_url`/`update_screen`/`on_push` are presentation
  # that code running in the session controls anyway.

  @build_config :mob_app_config

  @spec trusted_publish_key() :: String.t() | nil
  def trusted_publish_key, do: trusted(:trusted_publish_key)

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
  # :app_version` if set (from the build, like the key), else
  # `Mob.Device.app_version/0` (mob with the native accessor), else `nil`,
  # which leaves the gate open.
  @spec app_version() :: String.t() | nil
  def app_version, do: trusted(:app_version) || native_app_version()

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
  def app, do: trusted(:app)

  @spec channel() :: String.t() | nil
  def channel do
    case trusted(:channel) do
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
  (mob >= 0.9.6 with its mob_dev).
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

  # From the build's own config when there is one (see the module comment):
  # authoritative even when it doesn't set the key.
  defp trusted(key) do
    case build_config() do
      {:ok, config} -> Keyword.get(config, key)
      :none -> get(key)
    end
  end

  defp build_config do
    case :code.ensure_loaded(@build_config) do
      {:module, _} ->
        case List.keyfind(apply(@build_config, :config, []), :mob_deliver, 0) do
          {:mob_deliver, config} when is_list(config) -> {:ok, config}
          _ -> {:ok, []}
        end

      {:error, _} ->
        :none
    end
  catch
    # A config module that can't be read trusts nothing.
    _, _ -> {:ok, []}
  end
end

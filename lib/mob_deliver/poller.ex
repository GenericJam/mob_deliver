defmodule MobDeliver.Poller do
  @moduledoc """
  When update checks run: once at boot, then every `:poll_interval` ms
  (default one hour; `false` disables), and on a silent push through
  `mob_wake` (`:on_push`, default `true`).

  Checks run in an unlinked, monitored process, one at a time
  (`MobDeliver.check/0` is single-flight too), so a crashing check can't
  take the schedule down. A check deferred because an install is still on
  probation is retried shortly after the stability window. If this process
  restarts after boot started it, it resumes polling on its own.
  """

  use GenServer

  require Logger

  @push_id :mob_deliver_check
  @started {__MODULE__, :started}

  @doc "Options: `:name`, `:check` (0-arity, default `&MobDeliver.check/0`), `:interval`, `:retry_after`."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts),
    do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @doc "Starts polling: an immediate check, then the interval. Called from the plugin's on_start."
  @spec start(GenServer.server()) :: :ok
  def start(server \\ __MODULE__), do: GenServer.cast(server, :start)

  @doc """
  Registers the silent-push handler with `mob_wake` when it's present and
  `config :mob_deliver, :on_push` isn't `false`. A push whose data carries
  `"mob_wake_id": "mob_deliver_check"` then runs a check.
  """
  @spec register_push() :: :ok
  def register_push do
    wake = Mob.Wake

    if MobDeliver.Config.get(:on_push) != false and Code.ensure_loaded?(wake) do
      # Called dynamically: mob_wake is optional, not a dependency.
      apply(wake, :register, [@push_id, :push, {MobDeliver, :on_wake_push, []}])
    end

    :ok
  end

  @impl true
  def init(opts) do
    name = Keyword.get(opts, :name, __MODULE__)

    # The app-wide poller remembers (per VM) that boot started it, so a
    # supervisor restart doesn't silently end update checks.
    if name == __MODULE__ and :persistent_term.get(@started, false),
      do: GenServer.cast(self(), :start)

    {:ok,
     %{
       name: name,
       check: Keyword.get(opts, :check, &MobDeliver.check/0),
       interval: Keyword.get_lazy(opts, :interval, &MobDeliver.Config.poll_interval/0),
       retry_after:
         Keyword.get_lazy(opts, :retry_after, fn -> MobDeliver.Config.stable_after() + 1_000 end),
       running: nil,
       started: false
     }}
  end

  @impl true
  def handle_cast(:start, %{started: true} = s), do: {:noreply, s}

  def handle_cast(:start, s) do
    if s.name == __MODULE__, do: :persistent_term.put(@started, true)
    if s.interval, do: :timer.send_interval(s.interval, :check)
    {:noreply, run(%{s | started: true})}
  end

  @impl true
  def handle_info(:check, s), do: {:noreply, run(s)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: ref} = s) do
    case reason do
      {:check_result, {:ok, :deferred}} ->
        Process.send_after(self(), :check, s.retry_after)

      {:check_result, {:ok, _}} ->
        :ok

      {:check_result, {:error, why}} ->
        Logger.info("mob_deliver: update check failed (#{inspect(why)})")

      crash ->
        Logger.warning("mob_deliver: update check crashed (#{inspect(crash)})")
    end

    {:noreply, %{s | running: nil}}
  end

  def handle_info(_stale, s), do: {:noreply, s}

  # A tick while a check is still running is dropped, not queued. The
  # result travels in the exit reason, so it can't race the :DOWN.
  defp run(%{running: nil, check: check} = s) do
    {_pid, ref} = spawn_monitor(fn -> exit({:check_result, check.()}) end)
    %{s | running: ref}
  end

  defp run(s), do: s
end

defmodule MobDeliver.Poller do
  @moduledoc """
  When update checks run: once at boot, then every `:poll_interval` ms
  (default one hour; `false` disables) **while the app is in the
  foreground**, and on a silent push through `mob_wake` (`:on_push`,
  default `true`).

  Timed checks pause while the app is in the background: Android blocks a
  backgrounded app's network, so a check there only fails after a timeout.
  On return to the foreground a check runs at once if one came due in the
  meantime, otherwise when it's due. The plugin's `on_background` /
  `on_resume` lifecycle hooks (mob's app lifecycle events) drive this.

  A check deferred because an install is still unproven is retried after
  `:retry_after` ms (default 5s), doubling on every further deferral up to
  the poll interval (one hour when timed checks are off). Any other result
  resets that and waits for the next interval.

  Checks run in an unlinked, monitored process, one at a time
  (`MobDeliver.check/0` is single-flight too), so a crashing check can't
  take the schedule down. If this process restarts after boot started it,
  it resumes polling on its own.
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

  @doc "The app went to the background: no timed checks until `foreground/1`."
  @spec background(GenServer.server()) :: :ok
  def background(server \\ __MODULE__), do: GenServer.cast(server, :background)

  @doc "The app is in the foreground again: check now if a check came due meanwhile."
  @spec foreground(GenServer.server()) :: :ok
  def foreground(server \\ __MODULE__), do: GenServer.cast(server, :foreground)

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
       retry_after: Keyword.get(opts, :retry_after, 5_000),
       running: nil,
       started: false,
       foreground: true,
       # Monotonic ms when the next check is due (nil: none scheduled), and
       # `{token, timer_ref}` of the timer for it (only armed in the
       # foreground; cancelled whenever it's paused or replaced).
       due: nil,
       timer: nil,
       deferrals: 0
     }}
  end

  @impl true
  def handle_cast(:start, %{started: true} = s), do: {:noreply, s}

  def handle_cast(:start, s) do
    if s.name == __MODULE__, do: :persistent_term.put(@started, true)
    {:noreply, run(%{s | started: true})}
  end

  def handle_cast(:background, s), do: {:noreply, %{cancel(s) | foreground: false}}

  def handle_cast(:foreground, %{foreground: true} = s), do: {:noreply, s}

  def handle_cast(:foreground, s) do
    s = %{s | foreground: true}

    cond do
      s.due == nil -> {:noreply, s}
      s.due <= now() -> {:noreply, run(s)}
      true -> {:noreply, arm(s)}
    end
  end

  @impl true
  def handle_info({:check, token}, %{timer: {token, _ref}} = s), do: {:noreply, run(s)}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{running: ref} = s) do
    s = %{s | running: nil}

    case reason do
      {:check_result, {:ok, :deferred}} ->
        # An install is still unproven; it won't be proven any faster by asking often.
        delay = min(s.retry_after * Integer.pow(2, s.deferrals), s.interval || :timer.hours(1))
        {:noreply, schedule(%{s | deferrals: s.deferrals + 1}, delay)}

      {:check_result, {:ok, _}} ->
        {:noreply, schedule(%{s | deferrals: 0}, s.interval)}

      {:check_result, {:error, why}} ->
        Logger.warning("mob_deliver: update check failed (#{inspect(why)})")
        {:noreply, schedule(%{s | deferrals: 0}, s.interval)}

      crash ->
        Logger.warning("mob_deliver: update check crashed (#{inspect(crash)})")
        {:noreply, schedule(%{s | deferrals: 0}, s.interval)}
    end
  end

  # Stale timers (superseded or cancelled by backgrounding) and anything else.
  def handle_info(_stale, s), do: {:noreply, s}

  # The result travels in the exit reason, so it can't race the :DOWN.
  defp run(%{running: nil, check: check} = s) do
    {_pid, ref} = spawn_monitor(fn -> exit({:check_result, check.()}) end)
    %{cancel(s) | running: ref, due: nil}
  end

  defp run(s), do: s

  defp schedule(s, false), do: %{cancel(s) | due: nil}
  defp schedule(s, delay), do: arm(%{s | due: now() + delay})

  # Timers only run in the foreground; foreground/1 re-arms them.
  defp arm(%{foreground: false} = s), do: cancel(s)

  defp arm(s) do
    s = cancel(s)
    token = make_ref()
    ref = Process.send_after(self(), {:check, token}, max(s.due - now(), 0))
    %{s | timer: {token, ref}}
  end

  defp cancel(%{timer: {_token, ref}} = s) do
    Process.cancel_timer(ref, async: true, info: false)
    %{s | timer: nil}
  end

  defp cancel(s), do: s

  defp now, do: System.monotonic_time(:millisecond)
end

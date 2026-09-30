defmodule MobDeliver.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      MobDeliver.SingleFlight,
      MobDeliver.Store,
      MobDeliver.Watchdog,
      MobDeliver.Gate,
      MobDeliver.Refresh,
      MobDeliver.Poller
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MobDeliver.Supervisor)
  end
end

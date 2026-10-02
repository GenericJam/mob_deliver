defmodule MobDeliver.Status do
  @moduledoc false
  # What `MobDeliver.state/0` reports that no other process keeps: the last
  # update check's result and when it finished. A public ETS table owned by
  # this process, so recording never goes through a process and reading
  # works from anywhere.

  use GenServer

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(_opts), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc "Records a check's result. Never raises (a no-op while mob_deliver isn't running)."
  @spec put_check(term()) :: :ok
  def put_check(result) do
    :ets.insert(@table, {:last_check, %{result: result, at: DateTime.utc_now()}})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "The last check's `%{result:, at:}`, or `nil`."
  @spec last_check() :: %{result: term(), at: DateTime.t()} | nil
  def last_check do
    case :ets.lookup(@table, :last_check) do
      [{:last_check, check}] -> check
      [] -> nil
    end
  rescue
    ArgumentError -> nil
  end

  @impl true
  def init(:ok) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    {:ok, nil}
  end
end

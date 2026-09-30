defmodule MobDeliver.Fetcher do
  @moduledoc false
  # Getting a verified blob into the store, shared by JIT resolve and the
  # update poll: one download per SHA however many callers want it.

  alias MobDeliver.{Client, SingleFlight, Store}

  @type opts :: [store: Store.server(), single_flight: GenServer.server(), client_opts: keyword()]

  @doc "The verified bytes for `sha`, from the store or fetched into it."
  @spec ensure_blob(Store.sha(), opts()) :: {:ok, binary()} | {:error, term()}
  def ensure_blob(sha, opts) do
    with {:error, reason} when reason in [:missing, :corrupt] <-
           Store.read_blob(opts[:store], sha) do
      SingleFlight.run(opts[:single_flight], {:blob, sha}, fn -> fetch(sha, opts) end)
    end
  end

  # Re-checked inside the flight: another caller may have stored it between
  # our read and acquiring the key.
  defp fetch(sha, opts) do
    with {:error, reason} when reason in [:missing, :corrupt] <-
           Store.read_blob(opts[:store], sha),
         {:ok, binary} <- Client.fetch_beam(sha, opts[:client_opts]),
         :ok <- Store.put_blob(opts[:store], sha, binary) do
      {:ok, binary}
    end
  end
end

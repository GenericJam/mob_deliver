defmodule MobDeliver.Disk do
  @moduledoc false
  # Crash- and power-loss-safe file primitives shared by the store and the
  # watchdog. Never raise.

  require Logger

  @doc """
  Replaces `path` with `data`: tmp → fsync → rename → fsync(dir), creating
  (and syncing) missing directories. Readers see the old file or the whole
  new one. Errors before the rename leave `path` untouched; once the rename
  has happened the write is committed and returns `:ok` even if the final
  directory sync fails (logged), so callers never mistake a visible write
  for a failed one.
  """
  @spec atomic_write(Path.t(), iodata()) :: :ok | {:error, File.posix() | term()}
  def atomic_write(path, data) do
    dir = Path.dirname(path)
    tmp = "#{path}.tmp-#{System.unique_integer([:positive])}"

    with :ok <- mkdir_durable(dir),
         {:ok, fd} <- :file.open(tmp, [:write, :raw, :binary]),
         :ok <- write_sync_close(fd, data),
         :ok <- :file.rename(tmp, path) do
      with {:error, reason} <- fsync_dir(dir) do
        Logger.warning(
          "mob_deliver: #{path} written but directory sync failed (#{inspect(reason)})"
        )
      end

      :ok
    else
      {:error, _} = error ->
        File.rm(tmp)
        error
    end
  end

  @doc "`File.read/1` with `:enoent` reported as `:missing`."
  @spec read(Path.t()) :: {:ok, binary()} | {:error, :missing | File.posix()}
  def read(path) do
    case File.read(path) do
      {:ok, _} = ok -> ok
      {:error, :enoent} -> {:error, :missing}
      {:error, _} = error -> error
    end
  end

  @doc "Decodes an untrusted term file with `binary_to_term(..., [:safe])`; never raises."
  @spec read_term(Path.t()) :: {:ok, term()} | {:error, :missing | :undecodable | File.posix()}
  def read_term(path) do
    with {:ok, bin} <- read(path) do
      {:ok, :erlang.binary_to_term(bin, [:safe])}
    end
  rescue
    ArgumentError -> {:error, :undecodable}
  end

  # Creates each missing directory and syncs its parent, so a new directory
  # entry is as durable as the file written into it.
  defp mkdir_durable(dir) do
    cond do
      File.dir?(dir) ->
        :ok

      Path.dirname(dir) == dir ->
        {:error, :enoent}

      true ->
        parent = Path.dirname(dir)

        with :ok <- mkdir_durable(parent),
             :ok <- mkdir(dir) do
          fsync_dir(parent)
        end
    end
  end

  defp mkdir(dir) do
    case File.mkdir(dir) do
      {:error, :eexist} -> :ok
      other -> other
    end
  end

  defp write_sync_close(fd, data) do
    with :ok <- :file.write(fd, data), :ok <- :file.sync(fd) do
      :file.close(fd)
    else
      {:error, _} = error ->
        :file.close(fd)
        error
    end
  end

  defp fsync_dir(dir) do
    case :file.open(dir, [:read, :raw, :directory]) do
      {:ok, fd} ->
        result = :file.sync(fd)
        :file.close(fd)
        tolerate_unsupported(result)

      error ->
        tolerate_unsupported(error)
    end
  end

  # Some filesystems refuse directory fsync; the entry is still written.
  defp tolerate_unsupported({:error, reason}) when reason in [:einval, :enotsup, :eisdir], do: :ok
  defp tolerate_unsupported(result), do: result
end

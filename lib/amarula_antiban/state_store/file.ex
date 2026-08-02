defmodule AmarulaAntiban.StateStore.File do
  @moduledoc """
  Atomic JSON file store.

  Saves write a cryptographically unique temporary file in the destination
  directory and rename it over the target. `PersistenceWriter` enforces one
  serialized writer per session/path inside this application. The rename is an
  atomic visibility boundary; directory fsync and power-loss durability are not
  promised.
  """

  @behaviour AmarulaAntiban.StateStore

  @impl true
  def load(path) when is_binary(path) do
    with {:ok, bytes} <- File.read(path),
         {:ok, snapshot} <- Jason.decode(bytes) do
      {:ok, snapshot}
    else
      {:error, :enoent} -> {:ok, nil}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, error}}
      {:error, reason} -> {:error, reason}
    end
  end

  def load(_path), do: {:error, :invalid_path}

  @impl true
  def save(path, snapshot) when is_binary(path) and is_map(snapshot) do
    :global.trans({__MODULE__, Path.expand(path)}, fn -> do_save(path, snapshot) end)
  end

  def save(_path, _snapshot), do: {:error, :invalid_snapshot}

  defp do_save(path, snapshot) do
    directory = Path.dirname(path)
    temporary = temporary_path(path)

    with {:ok, json} <- Jason.encode(snapshot, pretty: true),
         :ok <- File.mkdir_p(directory),
         :ok <- remove_stale_temporaries(path),
         :ok <- File.write(temporary, json, [:binary, :sync]),
         :ok <- File.rename(temporary, path) do
      :ok
    else
      {:error, reason} = error ->
        _ = File.rm(temporary)

        if is_exception(reason),
          do: {:error, {:invalid_snapshot, reason}},
          else: error
    end
  end

  defp temporary_path(path) do
    suffix = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
    path <> ".tmp." <> suffix
  end

  defp remove_stale_temporaries(path) do
    Enum.each(Path.wildcard(path <> ".tmp.*"), &File.rm/1)
    :ok
  end
end

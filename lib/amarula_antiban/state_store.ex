defmodule AmarulaAntiban.StateStore do
  @moduledoc """
  Persistence boundary for versioned antiban snapshots.

  A store reference is `{adapter, key}`. The built-in file adapter uses a path
  as its key; the ETS adapter uses any term as its key.
  """

  @type snapshot :: map()
  @type key :: term()
  @type ref :: {module(), key()}

  @callback load(key()) :: {:ok, snapshot() | nil} | {:error, term()}
  @callback save(key(), snapshot()) :: :ok | {:error, term()}

  @doc "Loads a snapshot through its configured adapter."
  @spec load(ref() | nil) :: {:ok, snapshot() | nil} | {:error, term()}
  def load(nil), do: {:ok, nil}

  def load({adapter, key}) do
    adapter.load(key)
  rescue
    error -> {:error, {:adapter_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:adapter_exit, kind, reason}}
  end

  @doc "Saves a snapshot through its configured adapter."
  @spec save(ref() | nil, snapshot()) :: :ok | {:error, term()}
  def save(nil, _snapshot), do: :ok

  def save({adapter, key}, snapshot) do
    adapter.save(key, snapshot)
  rescue
    error -> {:error, {:adapter_exception, Exception.message(error)}}
  catch
    kind, reason -> {:error, {:adapter_exit, kind, reason}}
  end

  @doc "Normalizes `nil`, a file path, or an explicit `{adapter, key}` store."
  @spec normalize(nil | String.t() | ref()) :: nil | ref()
  def normalize(nil), do: nil
  def normalize(path) when is_binary(path), do: {AmarulaAntiban.StateStore.File, path}
  def normalize({adapter, _key} = store) when is_atom(adapter), do: store
end

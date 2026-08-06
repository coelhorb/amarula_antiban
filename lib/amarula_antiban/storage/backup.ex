defmodule AmarulaAntiban.Storage.Backup do
  @moduledoc """
  `Amarula.Storage` adapter that wraps any other adapter and keeps the last
  `:retention` copies of `:creds` on disk before each overwrite.

  `Amarula.Storage` is already a pluggable behaviour, so this needs no change
  in Amarula — it's a normal adapter that delegates every call to the inner
  one, backing up `:creds`'s *previous* value to `:backup_dir` immediately
  before `put/5` replaces it. Only `:creds` is backed up: it's the one
  namespace whose loss is catastrophic (Signal sessions/sender keys/LID
  mappings are recoverable by re-establishing them; a lost or corrupted
  credentials file means re-pairing).

  Robustness only — this has nothing to do with anti-ban risk scoring.

      storage = {AmarulaAntiban.Storage.Backup,
                  adapter: {Amarula.Storage.File, root: "./data"},
                  backup_dir: "./data/creds_backups",
                  retention: 5}

      Amarula.new(%{storage: storage, ...})

  To recover from a corrupted `:creds` file, list and read backups directly
  (outside the `Amarula.Storage` behaviour — these are operator tools, not
  part of the pluggable contract):

      opts = [backup_dir: "./data/creds_backups"]
      [latest | _older] = AmarulaAntiban.Storage.Backup.list_backups(opts, profile, :self)
      {:ok, creds} = AmarulaAntiban.Storage.Backup.read_backup(opts, latest)
      # then write `creds` back through the connection's real storage scope
  """

  @behaviour Amarula.Storage

  defstruct [:inner_adapter, :inner_state, :backup_dir, :retention]

  @default_retention 5

  @impl true
  def new(opts) do
    {inner_adapter, inner_opts} = Keyword.fetch!(opts, :adapter)

    %__MODULE__{
      inner_adapter: inner_adapter,
      inner_state: inner_adapter.new(inner_opts),
      backup_dir: Keyword.fetch!(opts, :backup_dir),
      retention: Keyword.get(opts, :retention, @default_retention)
    }
  end

  @impl true
  def get(state, profile, namespace, key),
    do: state.inner_adapter.get(state.inner_state, profile, namespace, key)

  @impl true
  def put(state, profile, :creds = namespace, key, value) do
    backup_before_overwrite(state, profile, key)
    state.inner_adapter.put(state.inner_state, profile, namespace, key, value)
  end

  def put(state, profile, namespace, key, value),
    do: state.inner_adapter.put(state.inner_state, profile, namespace, key, value)

  @impl true
  def delete(state, profile, namespace, key),
    do: state.inner_adapter.delete(state.inner_state, profile, namespace, key)

  @impl true
  def clear(state, profile) do
    if function_exported?(state.inner_adapter, :clear, 2),
      do: state.inner_adapter.clear(state.inner_state, profile),
      else: {:error, :not_supported}
  end

  @impl true
  def list_profiles(state) do
    if function_exported?(state.inner_adapter, :list_profiles, 1),
      do: state.inner_adapter.list_profiles(state.inner_state),
      else: {:error, :not_supported}
  end

  @impl true
  def list_keys(state, profile, namespace) do
    if function_exported?(state.inner_adapter, :list_keys, 3),
      do: state.inner_adapter.list_keys(state.inner_state, profile, namespace),
      else: {:error, :not_supported}
  end

  @doc """
  Lists backup ids for `{profile, key}` (e.g. `:self` for `:creds`), newest
  first. `opts` is the same keyword list passed as this adapter's config.
  """
  @spec list_backups(keyword(), term(), term()) :: [String.t()]
  def list_backups(opts, profile, key) do
    backup_dir = Keyword.fetch!(opts, :backup_dir)
    prefix = backup_prefix(profile, key)

    case File.ls(backup_dir) do
      {:ok, files} -> files |> Enum.filter(&String.starts_with?(&1, prefix)) |> Enum.sort(:desc)
      {:error, _reason} -> []
    end
  end

  @doc "Reads and decodes one backup's stored value, by the id returned from `list_backups/3`."
  @spec read_backup(keyword(), String.t()) :: {:ok, term()} | {:error, term()}
  def read_backup(opts, backup_id) do
    backup_dir = Keyword.fetch!(opts, :backup_dir)
    path = Path.join(backup_dir, backup_id)

    with {:ok, binary} <- File.read(path) do
      {:ok, :erlang.binary_to_term(binary, [:safe])}
    end
  end

  defp backup_before_overwrite(state, profile, key) do
    case state.inner_adapter.get(state.inner_state, profile, :creds, key) do
      {:ok, previous_value} -> write_backup(state, profile, key, previous_value)
      :error -> :ok
    end
  end

  defp write_backup(state, profile, key, value) do
    File.mkdir_p!(state.backup_dir)
    path = Path.join(state.backup_dir, backup_filename(profile, key))
    tmp = path <> ".tmp"
    File.write!(tmp, :erlang.term_to_binary(value))
    File.rename!(tmp, path)
    prune_backups(state, profile, key)
  end

  defp backup_filename(profile, key),
    do: "#{backup_prefix(profile, key)}#{System.system_time(:microsecond)}.backup"

  defp backup_prefix(profile, key), do: "#{safe_segment(profile)}__#{safe_segment(key)}__"

  defp safe_segment(value), do: value |> to_string() |> String.replace(~r/[^A-Za-z0-9_.-]/, "_")

  defp prune_backups(state, profile, key) do
    case File.ls(state.backup_dir) do
      {:ok, files} ->
        prefix = backup_prefix(profile, key)

        files
        |> Enum.filter(&String.starts_with?(&1, prefix))
        |> Enum.sort(:desc)
        |> Enum.drop(state.retention)
        |> Enum.each(&File.rm(Path.join(state.backup_dir, &1)))

      {:error, _reason} ->
        :ok
    end
  end
end

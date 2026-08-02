defmodule AmarulaAntiban.StateStoreTest do
  use ExUnit.Case, async: true

  alias AmarulaAntiban.Core.BanRecovery
  alias AmarulaAntiban.Core.TopologyThrottler
  alias AmarulaAntiban.Snapshot
  alias AmarulaAntiban.State
  alias AmarulaAntiban.StateStore
  alias AmarulaAntiban.StateStore.Ets
  alias AmarulaAntiban.StateStore.File, as: FileStore

  test "File stores a versioned snapshot atomically through real JSON" do
    directory =
      Path.join(System.tmp_dir!(), "antiban_store_#{System.unique_integer([:positive])}")

    path = Path.join(directory, "state.json")
    on_exit(fn -> File.rm_rf(directory) end)

    state = State.new([rand_fun: fn -> 0.5 end], 1_000)
    snapshot = Snapshot.export(state, 1_000)

    assert :ok = FileStore.save(path, snapshot)
    assert {:ok, decoded} = FileStore.load(path)
    assert decoded["schema_version"] == Snapshot.schema_version()
    assert {:ok, %State{}} = Snapshot.restore(decoded, state, 1_000)
    assert Path.wildcard(path <> ".tmp.*") == []
  end

  test "File distinguishes missing and malformed JSON" do
    directory =
      Path.join(System.tmp_dir!(), "antiban_bad_store_#{System.unique_integer([:positive])}")

    path = Path.join(directory, "state.json")
    on_exit(fn -> File.rm_rf(directory) end)

    assert {:ok, nil} = FileStore.load(path)
    File.mkdir_p!(directory)
    File.write!(path, "{not-json")
    assert {:error, {:invalid_json, %Jason.DecodeError{}}} = FileStore.load(path)
  end

  test "File returns tagged errors for invalid snapshots and failed replacement" do
    directory =
      Path.join(System.tmp_dir!(), "antiban_file_errors_#{System.unique_integer([:positive])}")

    path = Path.join(directory, "state.json")
    on_exit(fn -> File.rm_rf(directory) end)

    assert {:error, :invalid_snapshot} = FileStore.save(path, :not_a_map)

    assert {:error, {:invalid_snapshot, %Protocol.UndefinedError{}}} =
             FileStore.save(path, %{"pid" => self()})

    File.mkdir_p!(path)
    assert {:error, _reason} = FileStore.save(path, %{"valid" => true})
    assert Path.wildcard(path <> ".tmp.*") == []
  end

  test "Snapshot rejects an unsupported schema without mutating fresh state" do
    fresh = State.new([rand_fun: fn -> 0.5 end], 1_000)
    snapshot = Snapshot.export(fresh, 1_000) |> Map.put("schema_version", 999)

    assert {:error, {:unsupported_schema_version, 999}} =
             Snapshot.restore(snapshot, fresh, 1_000)
  end

  test "Snapshot restore is total for malformed and partial JSON-safe payloads" do
    fresh = State.new([rand_fun: fn -> 0.5 end], 1_000)

    assert {:error, :invalid_snapshot} = Snapshot.restore([], fresh, 1_000)

    partial = %{
      "schema_version" => 1,
      "state" => %{"$amarula_antiban_type" => "map", "entries" => []}
    }

    assert {:ok, %State{messages_allowed: 0}} = Snapshot.restore(partial, fresh, 1_000)

    invalid = Snapshot.export(fresh, 1_000)
    counter_tag = invalid["state"]

    corrupted =
      update_tagged_counter(counter_tag, "messages_allowed", "boom")
      |> then(&Map.put(invalid, "state", &1))

    assert {:error, :invalid_snapshot} = Snapshot.restore(corrupted, fresh, 1_000)
  end

  test "topology_throttler and ban_recovery survive a real JSON round-trip" do
    fresh = State.new([rand_fun: fn -> 0.5 end], 1_000)

    topology_throttler =
      %{fresh.topology_throttler | config: %{fresh.topology_throttler.config | enabled: true}}
      |> TopologyThrottler.record_sent("known@s.whatsapp.net", 1_000)
      |> TopologyThrottler.record_replied("known@s.whatsapp.net", 1_000)

    {ban_recovery, _effects} = BanRecovery.record_ban_event(fresh.ban_recovery, :timelock, 1_000)

    state = %{fresh | topology_throttler: topology_throttler, ban_recovery: ban_recovery}

    assert {:ok, restored} = Snapshot.restore(Snapshot.export(state, 1_000), fresh, 1_000)

    assert restored.topology_throttler.contacts["known@s.whatsapp.net"] == %{
             first_contact_at: 1_000,
             send_timestamps: [1_000],
             reply_timestamps: [1_000],
             blocked: false
           }

    assert restored.topology_throttler.new_contacts_this_hour == 1
    assert restored.ban_recovery.event_type == :timelock
    assert restored.ban_recovery.pause_until == 1_000 + 86_400_000
    assert restored.ban_recovery.ban_count_30d == 1
  end

  test "File removes realistic stale temporary leftovers before atomic replacement" do
    directory =
      Path.join(System.tmp_dir!(), "antiban_leftover_#{System.unique_integer([:positive])}")

    path = Path.join(directory, "state.json")
    stale = path <> ".tmp.crashed-writer"
    on_exit(fn -> File.rm_rf(directory) end)
    File.mkdir_p!(directory)
    File.write!(stale, "partial")

    state = State.new([rand_fun: fn -> 0.5 end], 1_000)
    assert :ok = FileStore.save(path, Snapshot.export(state, 1_000))
    assert Path.wildcard(path <> ".tmp.*") == []
    assert {:ok, %{"schema_version" => 1}} = FileStore.load(path)
  end

  test "ETS also crosses the Jason boundary and supports clear" do
    key = {:snapshot, System.unique_integer([:positive])}
    state = State.new([rand_fun: fn -> 0.5 end], 1_000)
    snapshot = Snapshot.export(state, 1_000)

    assert :ok = Ets.save(key, snapshot)
    assert {:ok, %{"schema_version" => 1}} = Ets.load(key)
    assert :ok = Ets.clear()
    assert {:ok, nil} = Ets.load(key)

    assert {:error, {:invalid_snapshot, %Protocol.UndefinedError{}}} =
             Ets.save(key, %{"pid" => self()})
  end

  test "StateStore normalizes and dispatches disabled, file, and explicit stores" do
    assert StateStore.normalize(nil) == nil
    assert StateStore.normalize("state.json") == {FileStore, "state.json"}
    assert StateStore.normalize({Ets, :key}) == {Ets, :key}
    assert {:ok, nil} = StateStore.load(nil)
    assert :ok = StateStore.save(nil, %{})

    snapshot = %{"schema_version" => 1, "state" => %{}}
    assert :ok = StateStore.save({Ets, :dispatch}, snapshot)
    assert {:ok, ^snapshot} = StateStore.load({Ets, :dispatch})
  end

  defp update_tagged_counter(%{"entries" => entries} = tagged, counter, replacement) do
    updated =
      Enum.map(entries, fn
        [%{"value" => "counters"} = key, counters] ->
          [key, update_tagged_counter(counters, counter, replacement)]

        [%{"value" => ^counter} = key, _value] ->
          [key, replacement]

        entry ->
          entry
      end)

    %{tagged | "entries" => updated}
  end

  defp update_tagged_counter(value, _counter, _replacement), do: value
end

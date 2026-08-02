defmodule AmarulaAntiban.TelemetryTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Telemetry

  test "catalogue exposes a measurements and metadata contract for every event" do
    contracts = Telemetry.contracts()

    assert Telemetry.events() == Enum.map(contracts, & &1.event)

    assert Enum.all?(contracts, fn contract ->
             match?([:amarula_antiban, _component, _action], contract.event) and
               is_map(contract.measurements) and map_size(contract.measurements) > 0 and
               is_map(contract.metadata)
           end)

    sent = Enum.find(contracts, &(&1.event == [:amarula_antiban, :queue, :sent]))
    assert Map.keys(sent.measurements) == [:attempts]
    assert Map.has_key?(sent.metadata, :queue_id)
    assert Map.has_key?(sent.metadata, :msg_id)

    scheduler =
      Enum.find(contracts, &(&1.event == [:amarula_antiban, :scheduler, :status]))

    assert Map.has_key?(scheduler.measurements, :ms_until_active)
    assert Map.has_key?(scheduler.measurements, :speed_factor)
    assert Map.has_key?(scheduler.metadata, :timezone)
  end

  test "emits documented telemetry" do
    {:ok, _} = Application.ensure_all_started(:telemetry)
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:amarula_antiban, :queue, :sent],
        fn event, measures, metadata, pid -> send(pid, {event, measures, metadata}) end,
        self()
      )

    assert :ok = Telemetry.emit([:amarula_antiban, :queue, :sent], %{count: 1}, %{profile: :test})
    assert_receive {[:amarula_antiban, :queue, :sent], %{count: 1}, %{profile: :test}}
    assert :ok = Telemetry.emit([:amarula_antiban, :queue, :started])
    :ok = :telemetry.detach(id)
  end
end

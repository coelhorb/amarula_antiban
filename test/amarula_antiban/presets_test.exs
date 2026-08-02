defmodule AmarulaAntiban.PresetsTest do
  use ExUnit.Case, async: true

  alias AmarulaAntiban.Presets

  def handle_telemetry(event, measurements, metadata, test_pid) do
    send(test_pid, {event, measurements, metadata})
  end

  test "nil resolves to the exact conservative preset" do
    config = Presets.resolve()

    assert config.max_per_minute == 5
    assert config.max_per_hour == 100
    assert config.max_per_day == 800
    assert config.min_delay_ms == 2_500
    assert config.max_delay_ms == 7_000
    assert config.new_chat_delay_ms == 4_000
    assert config.max_identical_messages == 3
    assert config.identical_message_window_ms == 3_600_000
    assert config.burst_allowance == 3
    assert config.warmup_days == 10
    assert config.day1_limit == 15
    assert config.growth_factor == 1.8
    assert config.inactivity_threshold_hours == 72
    assert config.auto_pause_at == :medium
    assert config.group_multiplier == 0.5
    assert config.group_profiles
    assert config.logging
  end

  test "all remaining preset numbers match upstream" do
    assert %{
             max_per_minute: 10,
             max_per_hour: 300,
             max_per_day: 1_500,
             min_delay_ms: 1_500,
             max_delay_ms: 5_000,
             new_chat_delay_ms: 3_000,
             max_identical_messages: 5,
             burst_allowance: 5,
             warmup_days: 7,
             day1_limit: 20,
             growth_factor: 1.8,
             inactivity_threshold_hours: 72,
             auto_pause_at: :high,
             group_multiplier: 0.7
           } = Map.from_struct(Presets.fetch!(:moderate))

    assert %{
             max_per_minute: 20,
             max_per_hour: 800,
             max_per_day: 4_000,
             min_delay_ms: 800,
             max_delay_ms: 3_000,
             new_chat_delay_ms: 2_000,
             max_identical_messages: 10,
             burst_allowance: 8,
             warmup_days: 4,
             day1_limit: 35,
             growth_factor: 2.0,
             inactivity_threshold_hours: 48,
             auto_pause_at: :high,
             group_multiplier: 0.9
           } = Map.from_struct(Presets.fetch!(:aggressive))

    assert %{
             max_per_minute: 40,
             max_per_hour: 1_500,
             max_per_day: 8_000,
             min_delay_ms: 400,
             max_delay_ms: 1_800,
             new_chat_delay_ms: 1_200,
             max_identical_messages: 20,
             burst_allowance: 15,
             warmup_days: 3,
             day1_limit: 60,
             growth_factor: 2.5,
             inactivity_threshold_hours: 24,
             auto_pause_at: :high,
             group_multiplier: 0.95
           } = Map.from_struct(Presets.fetch!(:high_volume))
  end

  test "keyword, map, and tuple overrides win over the preset" do
    assert Presets.resolve(preset: :moderate, max_per_minute: 15).max_per_minute == 15
    assert Presets.resolve(%{max_per_day: 999}).max_per_minute == 5
    assert Presets.resolve(%{max_per_day: 999}).max_per_day == 999
    assert Presets.resolve({:aggressive, max_delay_ms: 9_999}).max_delay_ms == 9_999
  end

  test "unknown presets and fields raise" do
    assert_raise ArgumentError, ~r/unknown preset/, fn -> Presets.resolve(:turbo) end
    assert_raise KeyError, fn -> Presets.resolve(unknown_option: true) end
  end

  test "high-volume resolution emits a telemetry warning" do
    handler = "preset-warning-#{System.unique_integer()}"
    test_pid = self()

    :ok =
      :telemetry.attach(
        handler,
        [:amarula_antiban, :preset, :warning],
        &__MODULE__.handle_telemetry/4,
        test_pid
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert Presets.resolve(:high_volume).max_per_day == 8_000

    assert_receive {[:amarula_antiban, :preset, :warning], %{},
                    %{preset: :high_volume, account_age_requirement_days: 180}}
  end

  test "all exposes exactly four named presets" do
    assert Presets.all() |> Map.keys() |> Enum.sort() ==
             [:aggressive, :conservative, :high_volume, :moderate]
  end
end

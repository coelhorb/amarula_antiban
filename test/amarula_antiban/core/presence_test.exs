defmodule AmarulaAntiban.Core.PresenceTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.Presence

  @hour 3_600_000

  test "circadian profile curves preserve exact upstream ranges" do
    assert Presence.circadian_multiplier(3, :default) > 4.0
    assert Presence.circadian_multiplier(14, :default) < 1.5

    assert Presence.circadian_multiplier(6, :night_owl) >
             Presence.circadian_multiplier(6, :default)

    assert Presence.circadian_multiplier(23, :early_bird) >
             Presence.circadian_multiplier(23, :default)

    assert Presence.circadian_multiplier(3, :always_on) == 1.0
  end

  test "activity curves use injected clock and fixed UTC offset" do
    presence = Presence.new(enabled: true, activity_curve: :office)
    assert Presence.activity_factor(presence, 10 * @hour) == 0.95
    presence = Presence.new(enabled: true, activity_curve: :social, utc_offset_minutes: 120)
    assert Presence.activity_factor(presence, 8 * @hour) == 0.7
    assert Presence.activity_factor(Presence.new(), 10 * @hour) == 1.0
  end

  test "distraction, offline, and read receipt decisions use injected RNG" do
    presence =
      Presence.new(
        enabled: true,
        distraction_pause_probability: 1.0,
        distraction_pause_min_ms: 100,
        distraction_pause_max_ms: 100,
        offline_gap_probability: 1.0,
        offline_gap_min_ms: 200,
        offline_gap_max_ms: 200,
        read_receipt_skip_probability: 0.0,
        read_receipt_delay_min_ms: 300,
        read_receipt_delay_max_ms: 300,
        circadian_enabled: false,
        rand_fun: fn -> 0.5 end
      )

    assert {{:pause, 100}, presence} = Presence.distraction_pause(presence)
    assert {{:available, 200}, presence} = Presence.offline_gap(presence)
    assert {{:mark, 300}, presence} = Presence.read_receipt(presence, 12 * @hour)
    stats = Presence.stats(presence, 12 * @hour)
    assert stats.distraction_pauses_injected == 1
    assert stats.offline_gaps_injected == 1
    assert stats.read_receipts_delayed == 1
  end

  test "read receipt can skip and disabled state is immediate" do
    skip =
      Presence.new(enabled: true, read_receipt_skip_probability: 1.0, rand_fun: fn -> 0.0 end)

    assert {:skip, skip} = Presence.read_receipt(skip, 0)
    assert Presence.stats(skip, 0).read_receipts_skipped == 1
    disabled = Presence.new()
    assert {{:mark, 0}, ^disabled} = Presence.read_receipt(disabled, 0)
    assert {:none, ^disabled} = Presence.distraction_pause(disabled)
    assert {:none, ^disabled} = Presence.offline_gap(disabled)
  end

  test "typing plan is deterministic, capped, and contains no execution" do
    presence =
      Presence.new(
        enabled: true,
        typing_wpm: 45,
        typing_wpm_std_dev: 0,
        think_pause_probability: 0.0,
        intermittent_paused_probability: 0.0,
        circadian_enabled: false,
        rand_fun: fn -> 0.5 end
      )

    assert {[{:typing, 600}], presence} = Presence.plan(presence, "", 0)
    {steps, presence} = Presence.plan(presence, String.duplicate("x", 10_000), 0)
    assert Enum.sum(for {:typing, ms} <- steps, do: ms) <= 90_000
    assert presence.counters.typing_plans_computed == 2
    presence = Presence.record_executed(presence, steps)
    assert presence.counters.typing_plans_executed == 1
    assert presence.counters.total_typing_time_ms > 0
    assert Presence.reset_stats(presence).counters.typing_plans_computed == 0
  end

  test "disabled typing model returns no presence traffic" do
    presence = Presence.new(enabled: true, enable_typing_model: false, typing_min_ms: 777)
    assert {[], ^presence} = Presence.plan(presence, "long text", 0)
  end

  test "IANA timezone preserves daylight-saving transitions with explicit clock" do
    presence = Presence.new(enabled: true, timezone: "America/New_York")

    winter_ms = unix_ms("2026-01-15T12:00:00Z")
    summer_ms = unix_ms("2026-07-15T12:00:00Z")

    assert Presence.stats(presence, winter_ms).current_hour_local == 7
    assert Presence.stats(presence, summer_ms).current_hour_local == 8
    assert Presence.activity_factor(presence, winter_ms) == 0.1
    assert Presence.activity_factor(presence, summer_ms) == 0.5
  end

  test "IANA timezone errors are explicit and fixed offset remains the alternative" do
    invalid = Presence.new(enabled: true, timezone: "Invalid/Nowhere")

    assert_raise ArgumentError, ~r/invalid IANA timezone/, fn ->
      Presence.stats(invalid, 0)
    end

    fixed = Presence.new(enabled: true, utc_offset_minutes: -180)
    assert Presence.stats(fixed, 5 * @hour).current_hour_local == 2
  end

  test "random durations normalize both injected RNG endpoints" do
    assert :erlang.fun_info(Presence.new().config.rand_fun, :name) ==
             {:name, :uniform_real}

    options = [
      enabled: true,
      distraction_pause_probability: 1.0,
      distraction_pause_min_ms: 10,
      distraction_pause_max_ms: 20
    ]

    minimum = Presence.new(Keyword.put(options, :rand_fun, fn -> 0.0 end))
    maximum = Presence.new(Keyword.put(options, :rand_fun, fn -> 1.0 end))

    assert {{:pause, 10}, _minimum} = Presence.distraction_pause(minimum)
    assert {{:pause, 20}, _maximum} = Presence.distraction_pause(maximum)
  end

  defp unix_ms(iso8601) do
    {:ok, datetime, 0} = DateTime.from_iso8601(iso8601)
    DateTime.to_unix(datetime, :millisecond)
  end
end

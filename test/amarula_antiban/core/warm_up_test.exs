defmodule AmarulaAntiban.Core.WarmUpTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias AmarulaAntiban.Core.WarmUp

  @now 1_700_000_000_000
  @day 86_400_000
  @hour 3_600_000

  defp warmup(options \\ []) do
    defaults = [
      warmup_days: 7,
      day1_limit: 20,
      growth_factor: 1.8,
      inactivity_threshold_hours: 72
    ]

    WarmUp.new(Keyword.merge(defaults, options), @now)
  end

  test "starts at the exact day-one limit and follows the growth curve" do
    warmup = warmup()
    assert {20, warmup} = WarmUp.daily_limit(warmup, @now)
    assert {36, _warmup} = WarmUp.daily_limit(warmup, @now + @day)
    assert {65, _warmup} = WarmUp.daily_limit(warmup, @now + 2 * @day)
  end

  test "graduates after the configured schedule" do
    warmup = warmup()
    assert {:infinity, warmup} = WarmUp.daily_limit(warmup, @now + 7 * @day)
    assert warmup.graduated

    assert {%WarmUp.Status{phase: :graduated, today_limit: -1, progress: 100}, _warmup} =
             WarmUp.status(warmup, @now + 7 * @day)
  end

  test "allows exactly the day-one quota and tracks status" do
    warmup =
      Enum.reduce(1..20, warmup(), fn _, warmup ->
        assert {true, warmup} = WarmUp.can_send(warmup, @now)
        WarmUp.record(warmup, @now)
      end)

    assert {false, warmup} = WarmUp.can_send(warmup, @now)

    assert {%WarmUp.Status{
              phase: :warming,
              day: 1,
              total_days: 7,
              today_limit: 20,
              today_sent: 20,
              progress: 0
            }, _warmup} = WarmUp.status(warmup, @now)
  end

  test "recording expands the per-day count list" do
    warmup = warmup() |> WarmUp.record(@now + 2 * @day)
    assert warmup.daily_counts == [0, 0, 1]
  end

  test "exports and restores state with the same daily count" do
    warmup = warmup() |> WarmUp.record(@now) |> WarmUp.record(@now)
    persisted = WarmUp.export(warmup, @now)

    assert persisted.daily_counts == [2]
    assert persisted.today_sent_count == 2

    restored = WarmUp.restore([], persisted, @now)
    assert {%WarmUp.Status{today_sent: 2}, _restored} = WarmUp.status(restored, @now)
  end

  test "restore uses the larger crash-safe count only for the same UTC day" do
    persisted = %{
      started_at: @now,
      last_active_at: @now,
      daily_counts: [2],
      graduated: false,
      today_sent_count: 9,
      today_date: WarmUp.export(warmup(), @now).today_date
    }

    assert WarmUp.restore([], persisted, @now).daily_counts == [9]
    assert WarmUp.restore([], %{persisted | today_date: "1999-01-01"}, @now).daily_counts == [2]
  end

  test "graduated state re-enters warm-up after extended inactivity" do
    persisted = %{
      started_at: @now - 10 * @day,
      last_active_at: @now - 80 * @hour,
      daily_counts: List.duplicate(100, 7),
      graduated: true
    }

    warmup = WarmUp.restore([inactivity_threshold_hours: 72, growth_factor: 1.8], persisted, @now)
    assert {true, warmup} = WarmUp.can_send(warmup, @now)
    assert warmup.started_at == @now
    assert warmup.daily_counts == []
    refute warmup.graduated
  end

  test "graduated state remains graduated below the inactivity threshold" do
    persisted = %{
      started_at: @now - 10 * @day,
      last_active_at: @now - 10 * @hour,
      daily_counts: List.duplicate(100, 7),
      graduated: true
    }

    warmup = WarmUp.restore([growth_factor: 1.8], persisted, @now)
    assert {true, warmup} = WarmUp.can_send(warmup, @now)
    assert warmup.graduated
  end

  test "reset creates a fresh state at the injected time" do
    warmup = warmup() |> WarmUp.record(@now)
    reset = WarmUp.reset(warmup, @now + 123)

    assert reset.started_at == @now + 123
    assert reset.last_active_at == @now + 123
    assert reset.daily_counts == []
    refute reset.graduated
  end

  property "injected default growth factor is rounded and remains in 1.5 through 2.2" do
    check all(random <- float(min: 0.0, max: 1.0)) do
      warmup = WarmUp.new([rand_fun: fn -> random end], @now)
      assert warmup.config.growth_factor >= 1.5
      assert warmup.config.growth_factor <= 2.2
      rounded = round(warmup.config.growth_factor * 100) / 100
      assert_in_delta warmup.config.growth_factor, rounded, 1.0e-12
    end
  end

  property "daily limits are non-decreasing for safe growth factors" do
    check all(factor <- float(min: 1.5, max: 2.5), days <- integer(1..10)) do
      warmup = WarmUp.new([warmup_days: days + 1, growth_factor: factor], @now)

      limits =
        for day <- 0..days do
          {limit, _warmup} = WarmUp.daily_limit(warmup, @now + day * @day)
          limit
        end

      assert limits == Enum.sort(limits)
    end
  end

  test "default growth factor normalizes injected RNG endpoints" do
    assert :erlang.fun_info(WarmUp.new([], @now).config.rand_fun, :name) ==
             {:name, :uniform_real}

    assert WarmUp.new([rand_fun: fn -> 0.0 end], @now).config.growth_factor == 1.5
    assert WarmUp.new([rand_fun: fn -> 1.0 end], @now).config.growth_factor == 2.2
  end
end

defmodule AmarulaAntiban.SchedulerTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Scheduler

  test "uses active, peak and lunch factors from injected clock" do
    now = DateTime.new!(~D[2024-01-01], ~T[12:00:00], "Etc/UTC")
    scheduler = start_supervised!({Scheduler, now_fun: fn -> now end})
    assert Scheduler.status(scheduler).active
    assert_in_delta Scheduler.speed_factor(scheduler), 0.65, 0.001
    assert Scheduler.adjust_delay(scheduler, 1_000) == 1_538
  end

  test "marks after-hours scheduling inactive and finds next start" do
    now = DateTime.new!(~D[2024-01-01], ~T[22:00:00], "Etc/UTC")
    scheduler = start_supervised!({Scheduler, now_fun: fn -> now end})
    assert :inactive = Scheduler.adjust_delay(scheduler, 1_000)
    assert Scheduler.ms_until_active(scheduler) == 10 * 3_600_000
  end

  test "uses configured IANA database for status and daylight-saving next window" do
    {:ok, winter, 0} = DateTime.from_iso8601("2026-01-15T12:00:00Z")

    winter_scheduler =
      start_supervised!(%{
        id: make_ref(),
        start:
          {Scheduler, :start_link,
           [[timezone: "America/New_York", now_fun: fn -> winter end, active_hours: {7, 21}]]}
      })

    assert %{active: true, current_hour: 7} = Scheduler.status(winter_scheduler)

    # 22:00 EST on the eve of the spring transition to 08:00 EDT is nine real hours.
    {:ok, before_spring_forward, 0} = DateTime.from_iso8601("2026-03-08T03:00:00Z")

    dst_scheduler =
      start_supervised!(%{
        id: make_ref(),
        start:
          {Scheduler, :start_link,
           [
             [
               timezone: "America/New_York",
               now_fun: fn -> before_spring_forward end,
               active_hours: {8, 21}
             ]
           ]}
      })

    assert Scheduler.status(dst_scheduler).current_hour == 22
    assert Scheduler.ms_until_active(dst_scheduler) == 9 * 3_600_000
  end

  test "status captures one now for every field in the snapshot" do
    before_open = DateTime.new!(~D[2026-01-15], ~T[07:59:59], "Etc/UTC")
    after_open = DateTime.new!(~D[2026-01-15], ~T[08:00:00], "Etc/UTC")
    calls = :atomics.new(1, signed: false)

    now_fun = fn ->
      case :atomics.add_get(calls, 1, 1) do
        1 -> before_open
        _later -> after_open
      end
    end

    scheduler = start_supervised!({Scheduler, now_fun: now_fun, active_hours: {8, 21}})

    assert %{
             active: false,
             current_hour: 7,
             speed_factor: 0,
             ms_until_active: 1_000
           } = Scheduler.status(scheduler)

    assert :atomics.get(calls, 1) == 1
  end
end

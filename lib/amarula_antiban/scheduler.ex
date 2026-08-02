defmodule AmarulaAntiban.Scheduler do
  @moduledoc """
  Supervisable safe-hour scheduler with an injectable clock.

  `now_fun` returns a `DateTime`; production defaults to the configured
  timezone. Every conversion, including next-window calculation across DST,
  uses the configured `:time_zone_database` (default:
  `Zoneinfo.TimeZoneDatabase`). Keeping the clock injectable avoids wall-clock
  tests and preserves the upstream scheduling formulas.
  """
  use GenServer
  alias AmarulaAntiban.Telemetry

  @defaults %{
    timezone: "Etc/UTC",
    active_hours: {8, 21},
    weekend_factor: 0.5,
    peak_hours: {10, 14},
    peak_factor: 1.3,
    lunch_break: {12, 13},
    lunch_factor: 0.5,
    time_zone_database: Zoneinfo.TimeZoneDatabase
  }
  @doc "Starts a scheduler process."
  def start_link(options \\ []),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  @doc "Returns status for the current injected time."
  def status(server), do: GenServer.call(server, :status)
  @doc "Returns zero outside active hours, otherwise the pace multiplier."
  def speed_factor(server), do: GenServer.call(server, :speed_factor)
  @doc "Adjusts a base delay, or returns `:inactive` outside the active window."
  def adjust_delay(server, delay_ms), do: GenServer.call(server, {:adjust_delay, delay_ms})
  @doc "Returns milliseconds until the next active window."
  def ms_until_active(server), do: GenServer.call(server, :ms_until_active)
  @impl true
  def init(options) do
    config = Map.merge(@defaults, Map.new(options))

    now_fun =
      Map.get(config, :now_fun, fn ->
        DateTime.now!(config.timezone, config.time_zone_database)
      end)

    {:ok, %{config: config, now_fun: now_fun}}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, status_for(state), state}
  def handle_call(:speed_factor, _from, state), do: {:reply, factor(state), state}
  def handle_call(:ms_until_active, _from, state), do: {:reply, until_active(state), state}

  def handle_call({:adjust_delay, delay_ms}, _from, state) do
    reply =
      case factor(state) do
        0 -> :inactive
        multiplier -> round(delay_ms / multiplier)
      end

    {:reply, reply, state}
  end

  defp status_for(state) do
    now = local_now(state)
    active = active?(state.config, now)
    speed = factor_at(state.config, now)
    ms = until_active_at(state.config, now)

    status = %{
      active: active,
      current_hour: now.hour,
      day: Date.day_of_week(DateTime.to_date(now)),
      is_weekend: Date.day_of_week(DateTime.to_date(now)) in [6, 7],
      speed_factor: speed,
      ms_until_active: ms,
      active_window: active_window(state.config)
    }

    Telemetry.emit(
      [:amarula_antiban, :scheduler, :status],
      %{ms_until_active: ms, speed_factor: speed},
      status
      |> Map.drop([:ms_until_active, :speed_factor])
      |> Map.put(:timezone, state.config.timezone)
    )

    status
  end

  defp factor(state) do
    now = local_now(state)
    factor_at(state.config, now)
  end

  defp factor_at(config, now) do
    if active?(config, now),
      do:
        weekend_factor(config, now) *
          window_factor(now.hour, config.peak_hours, config.peak_factor) *
          window_factor(now.hour, config.lunch_break, config.lunch_factor),
      else: 0
  end

  defp active?(config, now), do: within?(now.hour, config.active_hours)

  defp weekend_factor(config, now),
    do:
      if(Date.day_of_week(DateTime.to_date(now)) in [6, 7], do: config.weekend_factor, else: 1.0)

  defp window_factor(hour, range, multiplier),
    do: if(within?(hour, range), do: multiplier, else: 1.0)

  defp within?(hour, {start_hour, end_hour}), do: hour >= start_hour and hour < end_hour

  defp until_active(state) do
    now = local_now(state)
    until_active_at(state.config, now)
  end

  defp until_active_at(config, now) do
    if active?(config, now),
      do: 0,
      else:
        next_active(
          now,
          elem(config.active_hours, 0),
          elem(config.active_hours, 1),
          config.time_zone_database
        )
        |> DateTime.diff(now, :millisecond)
  end

  defp next_active(now, start_hour, end_hour, time_zone_database) do
    date =
      if now.hour >= end_hour, do: Date.add(DateTime.to_date(now), 1), else: DateTime.to_date(now)

    case DateTime.new(
           date,
           Time.new!(start_hour, 0, 0),
           now.time_zone,
           time_zone_database
         ) do
      {:ok, datetime} -> datetime
      {:ambiguous, first, _second} -> first
      {:gap, _just_before, just_after} -> just_after
      {:error, reason} -> raise ArgumentError, "invalid scheduler timezone: #{inspect(reason)}"
    end
  end

  defp local_now(state) do
    case DateTime.shift_zone(
           state.now_fun.(),
           state.config.timezone,
           state.config.time_zone_database
         ) do
      {:ok, datetime} -> datetime
      {:error, reason} -> raise ArgumentError, "invalid scheduler timezone: #{inspect(reason)}"
    end
  end

  defp active_window(config),
    do: "#{elem(config.active_hours, 0)}:00 - #{elem(config.active_hours, 1)}:00"
end

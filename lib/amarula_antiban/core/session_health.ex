defmodule AmarulaAntiban.Core.SessionHealth do
  @moduledoc "Pure Bad-MAC window and decrypt-health monitor."

  defmodule Config do
    @moduledoc "Bad-MAC degradation threshold and sliding window."
    defstruct bad_mac_threshold: 3, bad_mac_window_ms: 60_000
    @type t :: %__MODULE__{bad_mac_threshold: pos_integer(), bad_mac_window_ms: pos_integer()}
  end

  defmodule Stats do
    @moduledoc "Decrypt health snapshot."
    defstruct decrypt_success: 0,
              decrypt_fail: 0,
              bad_mac_count: 0,
              last_bad_mac: nil,
              is_degraded: false,
              degraded_since: nil

    @type t :: %__MODULE__{}
  end

  @type effect :: {:session_degraded | :session_recovered, Stats.t()}
  @type t :: %__MODULE__{config: Config.t(), stats: Stats.t(), bad_mac_timestamps: [integer()]}
  defstruct config: nil, stats: nil, bad_mac_timestamps: []

  @doc "Builds a health monitor."
  @spec new(keyword() | map()) :: t()
  def new(options \\ []) do
    %__MODULE__{config: struct!(Config, Map.new(options)), stats: struct!(Stats, %{})}
  end

  @doc "Records a successful decrypt and emits recovery after the Bad-MAC window clears."
  @spec record_success(t(), integer()) :: {t(), [effect()]}
  def record_success(health, now_ms) do
    health = put_in(health.stats.decrypt_success, health.stats.decrypt_success + 1)

    if health.stats.is_degraded do
      health = cleanup(health, now_ms)

      if length(health.bad_mac_timestamps) < health.config.bad_mac_threshold do
        health = %{health | stats: %{health.stats | is_degraded: false, degraded_since: nil}}
        {health, [{:session_recovered, health.stats}]}
      else
        {health, []}
      end
    else
      {health, []}
    end
  end

  @doc "Records a decrypt failure and optionally a Bad-MAC occurrence."
  @spec record_failure(t(), boolean(), integer()) :: {t(), [effect()]}
  def record_failure(health, now_ms), do: record_failure(health, false, now_ms)

  def record_failure(health, bad_mac?, now_ms) do
    health = put_in(health.stats.decrypt_fail, health.stats.decrypt_fail + 1)

    if bad_mac? do
      health =
        health
        |> put_in(
          [Access.key!(:stats), Access.key!(:bad_mac_count)],
          health.stats.bad_mac_count + 1
        )
        |> put_in([Access.key!(:stats), Access.key!(:last_bad_mac)], now_ms)
        |> Map.update!(:bad_mac_timestamps, &(&1 ++ [now_ms]))
        |> cleanup(now_ms)

      if not health.stats.is_degraded and
           length(health.bad_mac_timestamps) >= health.config.bad_mac_threshold do
        health = %{health | stats: %{health.stats | is_degraded: true, degraded_since: now_ms}}
        {health, [{:session_degraded, health.stats}]}
      else
        {health, []}
      end
    else
      {health, []}
    end
  end

  @doc "Returns the cumulative health snapshot."
  @spec stats(t()) :: Stats.t()
  def stats(health), do: health.stats

  @doc "Clears all counters and window state."
  @spec reset(t()) :: t()
  def reset(health), do: %{health | stats: struct!(Stats, %{}), bad_mac_timestamps: []}

  defp cleanup(health, now_ms) do
    cutoff = now_ms - health.config.bad_mac_window_ms
    %{health | bad_mac_timestamps: Enum.filter(health.bad_mac_timestamps, &(&1 > cutoff))}
  end
end

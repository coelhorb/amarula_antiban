defmodule AmarulaAntiban.Core.RetryTracker do
  @moduledoc """
  Pure analytical retry tracker and retry-spiral detector.

  Amarula owns protocol retry caching and resend. This module retains the
  upstream antiban statistics as a manual API because public Amarula events do
  not expose message IDs and reason codes together. Reaching `max_retries`
  emits analytical effects and remains observable in stats; it never claims to
  stop, resend, or otherwise control Amarula's transport.
  """

  @reasons [
    :no_session,
    :invalid_key,
    :bad_mac,
    :decryption_failure,
    :server_error_463,
    :server_error_429,
    :timeout,
    :no_route,
    :node_malformed,
    :unknown
  ]
  @max_age_ms 300_000

  defmodule Config do
    @moduledoc "Retry caps and spiral threshold."
    defstruct enabled: false, max_retries: 5, spiral_threshold: 3

    @type t :: %__MODULE__{
            enabled: boolean(),
            max_retries: pos_integer(),
            spiral_threshold: pos_integer()
          }
  end

  defmodule Stats do
    @moduledoc "Cumulative retry and active-message statistics."
    defstruct total_retries: 0,
              by_reason: %{},
              spirals_detected: 0,
              active_retries: 0,
              retry_limits_reached: 0,
              retries_over_limit: 0,
              active_at_retry_limit: 0

    @type t :: %__MODULE__{}
  end

  @type reason ::
          :no_session
          | :invalid_key
          | :bad_mac
          | :decryption_failure
          | :server_error_463
          | :server_error_429
          | :timeout
          | :no_route
          | :node_malformed
          | :unknown
  @type retry_record :: %{
          msg_id: String.t(),
          count: pos_integer(),
          reasons: [reason()],
          first_retry: integer(),
          last_retry: integer()
        }
  @type effect ::
          {:retry_spiral, %{msg_id: String.t(), reason: reason(), count: pos_integer()}}
          | {:retry_limit_reached,
             %{
               msg_id: String.t(),
               reason: reason(),
               count: pos_integer(),
               max_retries: pos_integer()
             }}
          | {:retry_limit_exceeded,
             %{
               msg_id: String.t(),
               reason: reason(),
               count: pos_integer(),
               max_retries: pos_integer()
             }}
  @type t :: %__MODULE__{
          config: Config.t(),
          retries: %{String.t() => retry_record()},
          total_retries: non_neg_integer(),
          reason_counts: %{reason() => non_neg_integer()},
          spirals_detected: non_neg_integer(),
          retry_limits_reached: non_neg_integer(),
          retries_over_limit: non_neg_integer()
        }

  defstruct config: nil,
            retries: %{},
            total_retries: 0,
            reason_counts: %{},
            spirals_detected: 0,
            retry_limits_reached: 0,
            retries_over_limit: 0

  @doc "Builds an analytical retry tracker."
  @spec new(keyword() | map()) :: t()
  def new(options \\ []) do
    %__MODULE__{config: struct!(Config, Map.new(options)), reason_counts: zero_reason_counts()}
  end

  @doc "Classifies arbitrary error terms using upstream status and text patterns."
  @spec classify(term()) :: reason()
  def classify(nil), do: :unknown

  def classify(error) do
    case status_code(error) do
      463 -> :server_error_463
      429 -> :server_error_429
      _other -> classify_text(error_text(error))
    end
  end

  @doc "Records a manually observed retry at the injected time."
  @spec record(t(), String.t(), reason(), integer()) :: {t(), [effect()]}
  def record(%__MODULE__{config: %{enabled: false}} = tracker, _msg_id, _reason, _now_ms),
    do: {tracker, []}

  def record(tracker, msg_id, reason, now_ms) when reason in @reasons do
    record =
      Map.get(tracker.retries, msg_id, %{
        msg_id: msg_id,
        count: 0,
        reasons: [],
        first_retry: now_ms,
        last_retry: now_ms
      })

    record = %{
      record
      | count: record.count + 1,
        reasons: record.reasons ++ [reason],
        last_retry: now_ms
    }

    tracker = %{
      tracker
      | retries: Map.put(tracker.retries, msg_id, record),
        total_retries: tracker.total_retries + 1,
        reason_counts: Map.update!(tracker.reason_counts, reason, &(&1 + 1))
    }

    {tracker, effects} = retry_limit_effects(tracker, record, reason)
    spiral_effects(tracker, record, reason, effects)
  end

  @doc "Adapts a Baileys-shaped manual update when one is explicitly supplied."
  @spec on_message_update(t(), map(), integer()) :: {t(), [effect()]}
  def on_message_update(%__MODULE__{config: %{enabled: false}} = tracker, _update, _now_ms),
    do: {tracker, []}

  def on_message_update(tracker, update, now_ms) do
    msg_id = get_in_any(update, [[:key, :id], ["key", "id"]])
    status = get_in_any(update, [[:status], ["status"]])
    error = get_in_any(update, [[:error], ["error"]])

    cond do
      not is_binary(msg_id) ->
        {tracker, []}

      status != 0 and is_nil(error) ->
        {tracker, []}

      true ->
        record(
          tracker,
          msg_id,
          classify(error || get_in_any(update, [[:update], ["update"]]) || update),
          now_ms
        )
    end
  end

  @doc "Returns whether a message reached the spiral threshold."
  @spec spiraling?(t(), String.t()) :: boolean()
  def spiraling?(tracker, msg_id) do
    case Map.get(tracker.retries, msg_id) do
      %{count: count} -> count >= tracker.config.spiral_threshold
      nil -> false
    end
  end

  @doc "Returns whether an active message has reached the configured analytical retry limit."
  @spec retry_limit_reached?(t(), String.t()) :: boolean()
  def retry_limit_reached?(tracker, msg_id) do
    case Map.get(tracker.retries, msg_id) do
      %{count: count} -> count >= tracker.config.max_retries
      nil -> false
    end
  end

  @doc "Clears active retry state for a delivered message."
  @spec clear(t(), String.t()) :: t()
  def clear(tracker, msg_id), do: %{tracker | retries: Map.delete(tracker.retries, msg_id)}

  @doc "Drops active retry records older than five minutes."
  @spec cleanup(t(), integer()) :: t()
  def cleanup(tracker, now_ms) do
    retries =
      Map.reject(tracker.retries, fn {_msg_id, record} ->
        now_ms - record.last_retry > @max_age_ms
      end)

    %{tracker | retries: retries}
  end

  @doc "Returns cumulative and active retry statistics."
  @spec stats(t()) :: Stats.t()
  def stats(tracker) do
    %Stats{
      total_retries: tracker.total_retries,
      by_reason: tracker.reason_counts,
      spirals_detected: tracker.spirals_detected,
      active_retries: map_size(tracker.retries),
      retry_limits_reached: tracker.retry_limits_reached,
      retries_over_limit: tracker.retries_over_limit,
      active_at_retry_limit:
        Enum.count(tracker.retries, fn {_msg_id, record} ->
          record.count >= tracker.config.max_retries
        end)
    }
  end

  @doc "Clears all active records and cumulative counters."
  @spec reset(t()) :: t()
  def reset(tracker) do
    %{
      tracker
      | retries: %{},
        total_retries: 0,
        reason_counts: zero_reason_counts(),
        spirals_detected: 0,
        retry_limits_reached: 0,
        retries_over_limit: 0
    }
  end

  defp zero_reason_counts, do: Map.new(@reasons, &{&1, 0})

  defp retry_limit_effects(tracker, %{count: count} = record, reason)
       when count == tracker.config.max_retries do
    tracker = %{tracker | retry_limits_reached: tracker.retry_limits_reached + 1}
    effect = {:retry_limit_reached, retry_limit_metadata(tracker, record, reason)}
    {tracker, [effect]}
  end

  defp retry_limit_effects(tracker, %{count: count} = record, reason)
       when count > tracker.config.max_retries do
    tracker = %{tracker | retries_over_limit: tracker.retries_over_limit + 1}
    effect = {:retry_limit_exceeded, retry_limit_metadata(tracker, record, reason)}
    {tracker, [effect]}
  end

  defp retry_limit_effects(tracker, _record, _reason), do: {tracker, []}

  defp retry_limit_metadata(tracker, record, reason) do
    %{
      msg_id: record.msg_id,
      reason: reason,
      count: record.count,
      max_retries: tracker.config.max_retries
    }
  end

  defp spiral_effects(tracker, record, reason, effects) do
    if record.count >= tracker.config.spiral_threshold do
      tracker = %{tracker | spirals_detected: tracker.spirals_detected + 1}
      effect = {:retry_spiral, %{msg_id: record.msg_id, reason: reason, count: record.count}}
      {tracker, effects ++ [effect]}
    else
      {tracker, effects}
    end
  end

  defp status_code(error) when is_map(error) do
    get_in_any(error, [
      [:output, :statusCode],
      [:output, :status_code],
      ["output", "statusCode"],
      [:statusCode],
      [:status_code],
      ["statusCode"],
      ["status_code"],
      [:status],
      ["status"]
    ])
  end

  defp status_code(_error), do: nil

  defp error_text(error) when is_binary(error), do: String.downcase(error)

  defp error_text(error) when is_map(error) do
    error
    |> get_in_any([[:message], ["message"], [:text], ["text"]])
    |> case do
      nil -> inspect(error)
      text -> to_string(text)
    end
    |> String.downcase()
  end

  defp error_text(error), do: error |> inspect() |> String.downcase()

  defp classify_text(text) do
    cond do
      String.contains?(text, "bad mac") -> :bad_mac
      String.contains?(text, ["no session", "session not found"]) -> :no_session
      String.contains?(text, ["invalid key", "key error"]) -> :invalid_key
      String.contains?(text, ["decryption", "decrypt"]) -> :decryption_failure
      String.contains?(text, ["timeout", "timed out"]) -> :timeout
      String.contains?(text, ["no route", "unreachable", "offline"]) -> :no_route
      String.contains?(text, ["malformed", "invalid node"]) -> :node_malformed
      true -> :unknown
    end
  end

  defp get_in_any(map, paths) do
    Enum.find_value(paths, fn path -> get_in(map, Enum.map(path, &Access.key(&1))) end)
  end
end

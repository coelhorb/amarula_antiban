defmodule AmarulaAntiban.Core.DeliveryTracker do
  @moduledoc "Pure delivery-rate tracking keyed by Amarula message IDs."
  defmodule Config do
    @moduledoc false
    @type t :: %__MODULE__{
            window_ms: pos_integer(),
            min_sample_size: pos_integer(),
            low_rate_threshold: float()
          }
    defstruct window_ms: 3_600_000, min_sample_size: 10, low_rate_threshold: 0.6
  end

  defmodule Stats do
    @moduledoc false
    @type t :: %__MODULE__{
            sent_in_window: non_neg_integer(),
            delivered_in_window: non_neg_integer(),
            delivery_rate: float() | nil,
            window_ms: pos_integer()
          }
    defstruct [:sent_in_window, :delivered_in_window, :delivery_rate, :window_ms]
  end

  @type t :: %__MODULE__{
          config: Config.t(),
          messages: %{String.t() => %{sent_at: integer(), delivered: boolean()}},
          last_low_rate_alert: integer()
        }
  defstruct config: nil, messages: %{}, last_low_rate_alert: 0
  @doc "Builds an empty tracker."
  @spec new(keyword() | map()) :: t()
  def new(options \\ []), do: %__MODULE__{config: struct!(Config, Map.new(options))}
  @doc "Registers a sent message at explicit `now_ms`."
  @spec sent(t(), String.t(), integer()) :: t()
  def sent(tracker, id, now_ms),
    do:
      tracker
      |> Map.update!(:messages, &Map.put(&1, id, %{sent_at: now_ms, delivered: false}))
      |> prune(now_ms)

  @doc "Records a delivery/read receipt and emits a rate alert at most once per hour."
  @spec receipt(t(), String.t(), integer()) :: {t(), [{:low_delivery_rate, float()}]}
  def receipt(tracker, id, now_ms) do
    messages =
      if Map.has_key?(tracker.messages, id) do
        Map.update!(tracker.messages, id, fn record -> %{record | delivered: true} end)
      else
        tracker.messages
      end

    tracker = %{tracker | messages: messages} |> prune(now_ms)

    {stats, tracker} = stats(tracker, now_ms)

    if is_number(stats.delivery_rate) and
         stats.delivery_rate < tracker.config.low_rate_threshold and
         now_ms - tracker.last_low_rate_alert >= 3_600_000,
       do:
         {%{tracker | last_low_rate_alert: now_ms}, [{:low_delivery_rate, stats.delivery_rate}]},
       else: {tracker, []}
  end

  @doc "Returns current statistics after pruning the configured window."
  @spec stats(t(), integer()) :: {Stats.t(), t()}
  def stats(tracker, now_ms) do
    tracker = prune(tracker, now_ms)
    records = Map.values(tracker.messages)
    sent = length(records)
    delivered = Enum.count(records, & &1.delivered)

    {%Stats{
       sent_in_window: sent,
       delivered_in_window: delivered,
       delivery_rate: if(sent >= tracker.config.min_sample_size, do: delivered / sent, else: nil),
       window_ms: tracker.config.window_ms
     }, tracker}
  end

  @doc "Clears messages and alert cooldown."
  @spec reset(t()) :: t()
  def reset(tracker), do: %{tracker | messages: %{}, last_low_rate_alert: 0}

  defp prune(tracker, now_ms),
    do: %{
      tracker
      | messages:
          Map.filter(tracker.messages, fn {_id, record} ->
            record.sent_at >= now_ms - tracker.config.window_ms
          end)
    }
end

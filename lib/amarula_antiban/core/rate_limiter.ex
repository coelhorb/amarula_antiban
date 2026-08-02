defmodule AmarulaAntiban.Core.RateLimiter do
  @moduledoc """
  Pure sliding-window rate limiter with human-like Gaussian timing jitter.

  Every time-sensitive operation receives `now_ms` explicitly. Calls that
  calculate a delay return the updated limiter because burst accounting and
  expiry cleanup are part of the calculation.
  """

  import Bitwise

  alias AmarulaAntiban.Presets

  @millisecond_per_second 1_000
  @millisecond_per_minute 60_000
  @millisecond_per_hour 3_600_000
  @millisecond_per_day 86_400_000
  @burst_reset_ms 30_000
  @identical_count_max 10_000

  defmodule Config do
    @moduledoc "Rate-limiter thresholds and injected random-number source."

    @type t :: %__MODULE__{
            max_per_minute: pos_integer(),
            max_per_hour: pos_integer(),
            max_per_day: pos_integer(),
            min_delay_ms: non_neg_integer(),
            max_delay_ms: non_neg_integer(),
            new_chat_delay_ms: non_neg_integer(),
            max_identical_messages: pos_integer(),
            burst_allowance: non_neg_integer(),
            identical_message_window_ms: pos_integer(),
            rand_fun: (-> float())
          }

    defstruct max_per_minute: 8,
              max_per_hour: 200,
              max_per_day: 1_500,
              min_delay_ms: 1_500,
              max_delay_ms: 5_000,
              new_chat_delay_ms: 3_000,
              max_identical_messages: 3,
              burst_allowance: 3,
              identical_message_window_ms: 3_600_000,
              rand_fun: &:rand.uniform_real/0
  end

  defmodule Stats do
    @moduledoc "A snapshot of sliding-window utilization and active limits."

    @type t :: %__MODULE__{
            last_minute: non_neg_integer(),
            last_hour: non_neg_integer(),
            last_day: non_neg_integer(),
            limits: map(),
            known_chats: non_neg_integer(),
            current_factor: float()
          }

    defstruct [:last_minute, :last_hour, :last_day, :limits, :known_chats, :current_factor]
  end

  @type message_record :: %{
          timestamp: integer(),
          recipient: String.t(),
          content_hash: String.t()
        }
  @type identical_tracker :: %{
          count: pos_integer(),
          first_seen: integer(),
          last_seen: integer()
        }
  @type t :: %__MODULE__{
          config: Config.t(),
          original_config: Config.t(),
          messages: [message_record()],
          identical_count: %{String.t() => identical_tracker()},
          known_chats: MapSet.t(String.t()),
          burst_count: non_neg_integer(),
          last_message_time: integer()
        }

  defstruct config: nil,
            original_config: nil,
            messages: [],
            identical_count: %{},
            known_chats: MapSet.new(),
            burst_count: 0,
            last_message_time: 0

  @doc "Builds a limiter from keyword options, a map, or a resolved preset."
  @spec new(keyword() | map() | Presets.Config.t()) :: t()
  def new(options \\ []) do
    config = struct!(Config, config_options(options))
    %__MODULE__{config: config, original_config: config}
  end

  @doc """
  Calculates the next human-like delay and returns the updated limiter.

  A daily or identical-content hard limit returns `{:deny, reason, limiter}`.
  Hourly and minute limits remain soft blocks represented as positive delays,
  matching the upstream contract.
  """
  @spec get_delay(t(), String.t(), String.t(), integer()) ::
          {:allow, non_neg_integer(), t()} | {:deny, atom(), t()}
  def get_delay(limiter, recipient, content, now_ms) do
    limiter = cleanup(limiter, now_ms)
    hash = content_hash(content)

    with :ok <- check_day(limiter, now_ms),
         :ok <- check_hour(limiter, now_ms),
         :ok <- check_minute(limiter, now_ms),
         :ok <- check_identical(limiter, hash, now_ms) do
      calculate_delay(limiter, recipient, content, now_ms)
    else
      {:delay, delay_ms} -> {:allow, delay_ms, limiter}
      {:deny, reason} -> {:deny, reason, limiter}
    end
  end

  @doc "Records a successfully sent message at `now_ms`."
  @spec record(t(), String.t(), String.t(), integer()) :: t()
  def record(limiter, recipient, content, now_ms) do
    hash = content_hash(content)
    time_since_last = now_ms - limiter.last_message_time

    # Upstream bug fix: inspect inactivity before replacing last_message_time.
    burst_count = if time_since_last > @burst_reset_ms, do: 0, else: limiter.burst_count

    tracker =
      case Map.get(limiter.identical_count, hash) do
        %{first_seen: first_seen} = current
        when now_ms - first_seen < limiter.config.identical_message_window_ms ->
          %{current | count: current.count + 1, last_seen: now_ms}

        _expired_or_missing ->
          %{count: 1, first_seen: now_ms, last_seen: now_ms}
      end

    message = %{timestamp: now_ms, recipient: recipient, content_hash: hash}

    %{
      limiter
      | messages: limiter.messages ++ [message],
        identical_count: Map.put(limiter.identical_count, hash, tracker),
        known_chats: MapSet.put(limiter.known_chats, recipient),
        burst_count: burst_count,
        last_message_time: now_ms
    }
  end

  @doc "Returns current utilization and the limiter after expiry cleanup."
  @spec stats(t(), integer()) :: {Stats.t(), t()}
  def stats(limiter, now_ms) do
    limiter = cleanup(limiter, now_ms)
    config = limiter.config

    stats = %Stats{
      last_minute: count_since(limiter.messages, now_ms, @millisecond_per_minute),
      last_hour: count_since(limiter.messages, now_ms, @millisecond_per_hour),
      last_day: count_since(limiter.messages, now_ms, @millisecond_per_day),
      limits: %{
        per_minute: config.max_per_minute,
        per_hour: config.max_per_hour,
        per_day: config.max_per_day
      },
      known_chats: MapSet.size(limiter.known_chats),
      current_factor: current_factor(limiter)
    }

    {stats, limiter}
  end

  @doc "Scales effective limits by a factor clamped to 0.1 through 1.0."
  @spec adapt_limits(t(), number()) :: t()
  def adapt_limits(limiter, factor) do
    factor = factor |> max(0.1) |> min(1.0)
    original = limiter.original_config
    delay_scale = 1 + (1 - factor) * 2

    config = %{
      limiter.config
      | max_per_minute: max(1, floor(original.max_per_minute * factor)),
        max_per_hour: max(5, floor(original.max_per_hour * factor)),
        max_per_day: max(20, floor(original.max_per_day * factor)),
        min_delay_ms: floor(original.min_delay_ms * delay_scale),
        max_delay_ms: floor(original.max_delay_ms * delay_scale)
    }

    %{limiter | config: config}
  end

  @doc "Returns the effective per-minute factor relative to original config."
  @spec current_factor(t()) :: float()
  def current_factor(limiter) do
    limiter.config.max_per_minute / limiter.original_config.max_per_minute
  end

  @doc "Returns the immutable set of known chat JIDs."
  @spec known_chats(t()) :: MapSet.t(String.t())
  def known_chats(limiter), do: limiter.known_chats

  @doc "Adds persisted JIDs to the known-chat set."
  @spec restore_known_chats(t(), [String.t()]) :: t()
  def restore_known_chats(limiter, chats) do
    %{limiter | known_chats: Enum.into(chats, limiter.known_chats)}
  end

  @doc """
  Merges external sliding-window timestamps from the previous 24 hours.

  Duplicate timestamps are ignored and the resulting records are ordered by
  timestamp, preserving the upstream reconnect protection.
  """
  @spec inject_timestamps(t(), [integer()], integer()) :: t()
  def inject_timestamps(limiter, timestamps, now_ms) do
    recent = Enum.filter(timestamps, &(now_ms - &1 < @millisecond_per_day))
    existing = MapSet.new(limiter.messages, & &1.timestamp)

    injected =
      recent
      |> Enum.uniq()
      |> Enum.reject(&MapSet.member?(existing, &1))
      |> Enum.map(fn timestamp ->
        %{timestamp: timestamp, recipient: "__injected__", content_hash: "__injected__"}
      end)

    max_injected = Enum.max(recent, fn -> 0 end)

    %{
      limiter
      | messages: Enum.sort_by(limiter.messages ++ injected, & &1.timestamp),
        last_message_time: max(limiter.last_message_time, max_injected)
    }
  end

  defp config_options(%Presets.Config{} = config) do
    config
    |> Map.from_struct()
    |> Map.take(Map.keys(%Config{}))
  end

  defp config_options(options), do: Map.new(options)

  defp check_day(limiter, now_ms) do
    if count_since(limiter.messages, now_ms, @millisecond_per_day) >=
         limiter.config.max_per_day do
      {:deny, :rate_limit_day}
    else
      :ok
    end
  end

  defp check_hour(limiter, now_ms) do
    messages = messages_since(limiter.messages, now_ms, @millisecond_per_hour)

    if length(messages) >= limiter.config.max_per_hour do
      # Sorting is intentional: injected timestamps need not be in insertion order.
      oldest = messages |> Enum.sort_by(& &1.timestamp) |> hd()
      delay = max(oldest.timestamp + @millisecond_per_hour - now_ms, @millisecond_per_minute)
      {:delay, delay}
    else
      :ok
    end
  end

  defp check_minute(limiter, now_ms) do
    messages = messages_since(limiter.messages, now_ms, @millisecond_per_minute)

    if length(messages) >= limiter.config.max_per_minute do
      oldest = messages |> Enum.sort_by(& &1.timestamp) |> hd()
      delay = max(oldest.timestamp + @millisecond_per_minute - now_ms, @millisecond_per_second)
      {:delay, delay}
    else
      :ok
    end
  end

  defp check_identical(limiter, hash, now_ms) do
    case Map.get(limiter.identical_count, hash) do
      %{count: count, first_seen: first_seen}
      when now_ms - first_seen < limiter.config.identical_message_window_ms and
             count >= limiter.config.max_identical_messages ->
        {:deny, :identical_message_limit}

      _tracker ->
        :ok
    end
  end

  defp calculate_delay(limiter, recipient, content, now_ms) do
    config = limiter.config

    {delay, limiter} =
      if limiter.burst_count < config.burst_allowance do
        {jitter(config, config.min_delay_ms * 0.5, config.min_delay_ms),
         %{limiter | burst_count: limiter.burst_count + 1}}
      else
        {jitter(config, config.min_delay_ms, config.max_delay_ms), limiter}
      end

    delay =
      if MapSet.member?(limiter.known_chats, recipient) do
        delay
      else
        delay + jitter(config, config.new_chat_delay_ms * 0.5, config.new_chat_delay_ms)
      end

    time_since_last = now_ms - limiter.last_message_time

    delay =
      if time_since_last < config.min_delay_ms do
        max(delay, config.min_delay_ms - time_since_last)
      else
        delay
      end

    typing_delay = min(utf16_length(content) * 30, 3_000)
    delay = delay + jitter(config, typing_delay * 0.5, typing_delay)
    {:allow, round(delay), limiter}
  end

  defp jitter(config, minimum, maximum) do
    u1 = max(sample(config.rand_fun), 1.0e-12)
    u2 = sample(config.rand_fun)
    normal = :math.sqrt(-2 * :math.log(u1)) * :math.cos(2 * :math.pi() * u2)
    normalized = (normal + 3) / 6
    clamped = normalized |> max(0) |> min(1)
    round(minimum + clamped * (maximum - minimum))
  end

  defp sample(rand_fun), do: rand_fun.() |> max(0.0) |> min(1.0 - 1.0e-12)

  defp cleanup(limiter, now_ms) do
    messages = messages_since(limiter.messages, now_ms, @millisecond_per_day)

    identical_count =
      limiter.identical_count
      |> Enum.reject(fn {_hash, tracker} ->
        now_ms - tracker.last_seen > limiter.config.identical_message_window_ms
      end)
      |> Map.new()
      |> cap_identical_trackers()

    %{limiter | messages: messages, identical_count: identical_count}
  end

  defp cap_identical_trackers(trackers) when map_size(trackers) <= @identical_count_max,
    do: trackers

  defp cap_identical_trackers(trackers) do
    excess = map_size(trackers) - @identical_count_max

    trackers
    |> Enum.sort_by(fn {_hash, tracker} -> tracker.last_seen end)
    |> Enum.drop(excess)
    |> Map.new()
  end

  defp count_since(messages, now_ms, window_ms) do
    messages |> messages_since(now_ms, window_ms) |> length()
  end

  defp messages_since(messages, now_ms, window_ms) do
    Enum.filter(messages, &(now_ms - &1.timestamp < window_ms))
  end

  defp content_hash(content) do
    hash =
      Enum.reduce(utf16_units(content), 0, fn unit, hash ->
        value = band(hash * 31 + unit, 0xFFFF_FFFF)
        if value >= 0x8000_0000, do: value - 0x1_0000_0000, else: value
      end)

    Integer.to_string(hash, 36)
  end

  defp utf16_length(content), do: content |> utf16_units() |> length()

  defp utf16_units(content) do
    content
    |> :unicode.characters_to_binary(:utf8, {:utf16, :big})
    |> then(fn binary -> for <<unit::unsigned-big-16 <- binary>>, do: unit end)
  end
end

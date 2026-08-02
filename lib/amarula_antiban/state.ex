defmodule AmarulaAntiban.State do
  @moduledoc """
  Pure aggregate of every stateful antiban core module.

  This struct contains no process identifiers and performs no I/O. `Session`
  is the sole mutable owner of it.
  """

  alias AmarulaAntiban.Core
  alias AmarulaAntiban.Presets

  @type t :: %__MODULE__{
          config: Presets.Config.t(),
          rate_limiter: Core.RateLimiter.t(),
          warm_up: Core.WarmUp.t(),
          health: Core.Health.t(),
          timelock_guard: Core.TimelockGuard.t(),
          reply_ratio: Core.ReplyRatio.t(),
          contact_graph: Core.ContactGraph.t(),
          presence: Core.Presence.t(),
          retry_tracker: Core.RetryTracker.t(),
          reconnect_throttle: Core.ReconnectThrottle.t(),
          delivery_tracker: Core.DeliveryTracker.t(),
          circuit_breaker: Core.JidCircuitBreaker.t(),
          session_health: Core.SessionHealth.t(),
          deaf_session: Core.DeafSession.t(),
          jid_canonicalizer: Core.JidCanonicalizer.t(),
          message_type_registry: Core.MessageTypeRegistry.t(),
          content_variator: Core.ContentVariator.t(),
          read_receipt_variance: Core.ReadReceiptVariance.t(),
          topology_throttler: Core.TopologyThrottler.t(),
          ban_recovery: Core.BanRecovery.t(),
          reservations: map(),
          messages_allowed: non_neg_integer(),
          messages_blocked: non_neg_integer(),
          total_delay_ms: non_neg_integer()
        }

  @enforce_keys [
    :config,
    :rate_limiter,
    :warm_up,
    :health,
    :timelock_guard,
    :reply_ratio,
    :contact_graph,
    :presence,
    :retry_tracker,
    :reconnect_throttle,
    :delivery_tracker,
    :circuit_breaker,
    :session_health,
    :deaf_session,
    :jid_canonicalizer,
    :message_type_registry,
    :content_variator,
    :read_receipt_variance,
    :topology_throttler,
    :ban_recovery
  ]
  defstruct @enforce_keys ++
              [reservations: %{}, messages_allowed: 0, messages_blocked: 0, total_delay_ms: 0]

  @doc "Builds a fresh aggregate at the explicit Unix-millisecond clock value."
  @spec new(keyword() | map(), integer()) :: t()
  def new(options \\ [], now_ms) do
    options = Map.new(options)
    config = resolve_config(options)
    rand_fun = config.rand_fun

    %__MODULE__{
      config: config,
      rate_limiter: Core.RateLimiter.new(config),
      warm_up: Core.WarmUp.new(config, now_ms),
      health: Core.Health.new(config, now_ms),
      timelock_guard: Core.TimelockGuard.new(nested(options, :timelock)),
      reply_ratio: Core.ReplyRatio.new(with_rand(nested(options, :reply_ratio), rand_fun)),
      contact_graph: Core.ContactGraph.new(nested(options, :contact_graph), now_ms),
      presence: Core.Presence.new(with_rand(nested(options, :presence), rand_fun)),
      retry_tracker: Core.RetryTracker.new(nested(options, :retry_tracker)),
      reconnect_throttle:
        Core.ReconnectThrottle.new(
          nested(options, :reconnect_throttle)
          |> Map.put_new(:baseline_rate_per_minute, config.max_per_minute)
        ),
      delivery_tracker: Core.DeliveryTracker.new(nested(options, :delivery_tracker)),
      circuit_breaker:
        Core.JidCircuitBreaker.new(with_rand(nested(options, :circuit_breaker), rand_fun)),
      session_health: Core.SessionHealth.new(nested(options, :session_health)),
      deaf_session: Core.DeafSession.new(nested(options, :deaf_session)),
      jid_canonicalizer: Core.JidCanonicalizer.new(),
      message_type_registry: Core.MessageTypeRegistry.new(rand_fun: rand_fun),
      content_variator:
        Core.ContentVariator.new(with_rand(nested(options, :content_variator), rand_fun)),
      read_receipt_variance:
        Core.ReadReceiptVariance.new(with_rand(nested(options, :read_receipt_variance), rand_fun)),
      topology_throttler:
        Core.TopologyThrottler.new(nested(options, :topology_throttler), now_ms),
      ban_recovery: Core.BanRecovery.new(nested(options, :ban_recovery))
    }
  end

  defp resolve_config(options) do
    keys = Map.keys(%Presets.Config{})
    overrides = Map.take(options, keys)
    preset = Map.get(options, :preset, :conservative)
    Presets.resolve({preset, overrides})
  end

  defp nested(options, key) do
    case Map.get(options, key, %{}) do
      value when is_list(value) or is_map(value) -> Map.new(value)
      nil -> %{}
    end
  end

  defp with_rand(options, rand_fun), do: Map.put_new(options, :rand_fun, rand_fun)
end

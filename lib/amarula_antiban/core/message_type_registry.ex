defmodule AmarulaAntiban.Core.MessageTypeRegistry do
  @moduledoc """
  Pure registry for typed-message provenance, engagement, and pool limits.

  This is the OTP-native form of baileys-antiban's `MessageTypeRegistry`.
  Transport is intentionally outside the core: `prepare_send/5` validates and
  plans a send, and `record_sent/4` records it after Amarula returns a message
  ID. All time and randomness enter explicitly.
  """

  alias AmarulaAntiban.Core.RateLimiter

  @five_minutes_ms 300_000
  @day_ms 86_400_000
  @minimum_warning_sample 10
  @minimum_rate_warning_sample 20

  defmodule LegitimacySignals do
    @moduledoc "Legitimacy thresholds attached to a message type."

    @type t :: %__MODULE__{
            max_action_delta_ms: non_neg_integer() | nil,
            min_engagement_score: number() | nil,
            min_subscription_age_days: number() | nil
          }

    defstruct max_action_delta_ms: nil,
              min_engagement_score: nil,
              min_subscription_age_days: nil
  end

  defmodule EngagementTracking do
    @moduledoc "Whether engagement for a type expects replies rather than reads."

    @type t :: %__MODULE__{expect_reply: boolean() | nil}
    defstruct expect_reply: nil
  end

  defmodule Definition do
    @moduledoc "Priority, provenance, legitimacy, and delivery policy for a type."

    alias AmarulaAntiban.Core.MessageTypeRegistry.{EngagementTracking, LegitimacySignals}

    @type priority :: :critical | :normal | :bulk
    @type delivery_guarantee :: :at_least_once | :best_effort

    @type t :: %__MODULE__{
            priority: priority(),
            rate_limit_pool: String.t() | nil,
            requires_provenance: [atom() | String.t()],
            legitimacy_signals: LegitimacySignals.t() | nil,
            delivery_guarantee: delivery_guarantee() | nil,
            engagement_tracking: EngagementTracking.t() | nil
          }

    @enforce_keys [:priority]
    defstruct priority: nil,
              rate_limit_pool: nil,
              requires_provenance: [],
              legitimacy_signals: nil,
              delivery_guarantee: nil,
              engagement_tracking: nil

    @doc "Builds a typed definition from snake-case keyword or map options."
    @spec new(keyword() | map()) :: t()
    def new(options) do
      options = Map.new(options)

      struct!(__MODULE__, %{
        priority: value(options, :priority),
        rate_limit_pool: value(options, :rate_limit_pool),
        requires_provenance: value(options, :requires_provenance, []),
        legitimacy_signals: nested(options, :legitimacy_signals, LegitimacySignals),
        delivery_guarantee: value(options, :delivery_guarantee),
        engagement_tracking: nested(options, :engagement_tracking, EngagementTracking)
      })
    end

    defp nested(options, key, module) do
      case value(options, key) do
        nil -> nil
        %{__struct__: ^module} = value -> value
        value when is_map(value) or is_list(value) -> struct!(module, Map.new(value))
      end
    end

    defp value(map, key, default \\ nil) do
      Map.get(map, key, Map.get(map, Atom.to_string(key), default))
    end
  end

  defmodule Stats do
    @moduledoc "Per-type delivery and engagement statistics."

    @type t :: %__MODULE__{
            sent: non_neg_integer(),
            delivered: non_neg_integer(),
            read: non_neg_integer(),
            replied: non_neg_integer(),
            blocked: non_neg_integer(),
            avg_action_delta_ms: non_neg_integer(),
            engagement_score: non_neg_integer(),
            last_warning_at: integer() | nil
          }

    defstruct sent: 0,
              delivered: 0,
              read: 0,
              replied: 0,
              blocked: 0,
              avg_action_delta_ms: 0,
              engagement_score: 100,
              last_warning_at: nil
  end

  defmodule Warning do
    @moduledoc "A warning emitted for a degraded type metric."

    @type metric :: :engagement | :action_delta | :delivery_rate | :blocked_rate
    @type t :: %__MODULE__{
            type: String.t(),
            metric: metric(),
            current: number(),
            threshold: number(),
            message: String.t()
          }

    @enforce_keys [:type, :metric, :current, :threshold, :message]
    defstruct [:type, :metric, :current, :threshold, :message]
  end

  defmodule PendingMessage do
    @moduledoc "A sent message awaiting delivery/read/reply observations."

    @type t :: %__MODULE__{
            type: String.t(),
            jid: String.t() | nil,
            sent_at: integer(),
            provenance: map() | nil,
            delivered: boolean(),
            read: boolean()
          }

    @enforce_keys [:type, :sent_at]
    defstruct [:type, :jid, :sent_at, :provenance, delivered: false, read: false]
  end

  defmodule PreparedSend do
    @moduledoc "Validated send data to record after the external transport succeeds."

    @type t :: %__MODULE__{
            type: String.t(),
            jid: String.t(),
            provenance: map() | nil,
            delay_ms: non_neg_integer(),
            pool: String.t() | nil,
            pool_record_content: String.t()
          }

    @enforce_keys [:type, :jid, :delay_ms, :pool_record_content]
    defstruct [:type, :jid, :provenance, :delay_ms, :pool, :pool_record_content]
  end

  @type error_reason ::
          :invalid_definition
          | {:type_not_registered, String.t()}
          | {:provenance_required, String.t(), [atom() | String.t()]}
          | {:provenance_field_required, String.t(), atom() | String.t()}
          | {:max_action_delta_exceeded, String.t(), integer(), non_neg_integer()}
          | {:min_engagement_score_not_met, String.t(), number(), number()}
          | {:min_subscription_age_not_met, String.t(), float(), number()}
          | {:rate_limit_exceeded, String.t(), atom()}

  @type t :: %__MODULE__{
          types: %{String.t() => Definition.t()},
          stats: %{String.t() => Stats.t()},
          pools: %{String.t() => RateLimiter.t()},
          pending_messages: %{String.t() => PendingMessage.t()},
          locked: MapSet.t(String.t()),
          rand_fun: (-> float())
        }

  defstruct types: %{},
            stats: %{},
            pools: %{},
            pending_messages: %{},
            locked: MapSet.new(),
            rand_fun: &:rand.uniform_real/0

  @doc "Builds an empty registry with an optional injected `:rand_fun`."
  @spec new(keyword()) :: t()
  def new(options \\ []) do
    %__MODULE__{rand_fun: Keyword.get(options, :rand_fun, &:rand.uniform_real/0)}
  end

  @doc """
  Registers or replaces a type definition before its first prepared send.

  As upstream, registering an unlocked name resets that type's statistics.
  Once a send is prepared, the definition is immutable.
  """
  @spec register_message_type(t(), String.t(), Definition.t() | keyword() | map()) ::
          {:ok, t()} | {:error, :type_locked | :invalid_definition, t()}
  def register_message_type(%__MODULE__{} = registry, name, definition)
      when is_binary(name) do
    if MapSet.member?(registry.locked, name) do
      {:error, :type_locked, registry}
    else
      case normalize_definition(definition) do
        {:ok, definition} ->
          registry =
            registry
            |> put_type(name, definition)
            |> ensure_pool(definition)

          {:ok, registry}

        :error ->
          {:error, :invalid_definition, registry}
      end
    end
  end

  def register_message_type(%__MODULE__{} = registry, _name, _definition),
    do: {:error, :invalid_definition, registry}

  @doc """
  Validates a typed send and calculates its pool delay without performing I/O.

  The type is locked as soon as preparation begins, matching upstream's
  first-send immutability even when later validation rejects the send.
  """
  @spec prepare_send(t(), String.t(), term(), map() | keyword(), integer()) ::
          {:ok, PreparedSend.t(), t()} | {:error, error_reason(), t()}
  def prepare_send(%__MODULE__{} = registry, jid, content, options, now_ms)
      when is_binary(jid) and (is_map(options) or is_list(options)) do
    options = Map.new(options)
    type = value(options, :type)

    case Map.fetch(registry.types, type) do
      :error ->
        {:error, {:type_not_registered, type}, registry}

      {:ok, definition} ->
        registry = %{registry | locked: MapSet.put(registry.locked, type)}
        provenance = value(options, :provenance)
        engagement_score = value(options, :engagement_score)

        with :ok <- validate_provenance(type, definition, provenance),
             :ok <- validate_legitimacy(type, definition, provenance, engagement_score, now_ms),
             {:ok, delay_ms, registry} <- pool_delay(registry, definition, jid, content, now_ms) do
          prepared = %PreparedSend{
            type: type,
            jid: jid,
            provenance: provenance,
            delay_ms: delay_ms,
            pool: definition.rate_limit_pool,
            pool_record_content: content_value(content, :text) || ""
          }

          {:ok, prepared, registry}
        else
          {:error, reason, %__MODULE__{} = registry} -> {:error, reason, registry}
          {:error, reason} -> {:error, reason, registry}
        end
    end
  end

  @doc "Records a successful external send and optionally tracks its message ID."
  @spec record_sent(t(), PreparedSend.t(), String.t() | nil, integer()) :: t()
  def record_sent(
        %__MODULE__{} = registry,
        %PreparedSend{} = prepared,
        message_id,
        now_ms
      ) do
    registry =
      registry
      |> update_sent_stats(prepared, now_ms)
      |> record_pool_send(prepared, now_ms)

    if present_string?(message_id) do
      pending = %PendingMessage{
        type: prepared.type,
        jid: prepared.jid,
        sent_at: now_ms,
        provenance: prepared.provenance
      }

      %{registry | pending_messages: Map.put(registry.pending_messages, message_id, pending)}
    else
      registry
    end
  end

  @doc "Records delivery once for a pending message ID. Unknown and duplicate receipts are ignored."
  @spec record_delivered(t(), String.t()) :: t()
  def record_delivered(registry, message_id),
    do: record_observation(registry, message_id, :delivered)

  @doc "Records a read once for a pending message ID. Unknown and duplicate receipts are ignored."
  @spec record_read(t(), String.t()) :: t()
  def record_read(registry, message_id), do: record_observation(registry, message_id, :read)

  @doc "Records a reply and removes its message from pending tracking."
  @spec record_replied(t(), String.t()) :: t()
  def record_replied(%__MODULE__{} = registry, message_id) do
    case Map.fetch(registry.pending_messages, message_id) do
      :error ->
        registry

      {:ok, pending} ->
        registry = increment_engagement(registry, pending.type, :replied)
        %{registry | pending_messages: Map.delete(registry.pending_messages, message_id)}
    end
  end

  @doc "Marks pending sends to `jid` from the previous five minutes as blocked."
  @spec record_blocked(t(), String.t(), integer()) :: t()
  def record_blocked(%__MODULE__{} = registry, jid, now_ms) do
    Enum.reduce(registry.pending_messages, registry, fn {_message_id, pending}, registry ->
      maybe_record_blocked(registry, pending, jid, now_ms)
    end)
  end

  @doc "Returns a type's immutable stats snapshot, or `nil` when unregistered."
  @spec get_stats(t(), String.t()) :: Stats.t() | nil
  def get_stats(%__MODULE__{} = registry, type), do: Map.get(registry.stats, type)

  @doc """
  Returns warning-only policy signals and the state with warning timestamps.

  The function never throttles or changes pool limits.
  """
  @spec warnings(t(), integer()) :: {[Warning.t()], t()}
  def warnings(%__MODULE__{} = registry, now_ms) do
    Enum.reduce(registry.stats, {[], registry}, fn {type, stat}, {warnings, registry} ->
      type_warnings = warnings_for_type(type, stat, Map.fetch!(registry.types, type))

      registry =
        if type_warnings == [] do
          registry
        else
          update_type_stats(registry, type, &%{&1 | last_warning_at: now_ms})
        end

      {warnings ++ type_warnings, registry}
    end)
  end

  @doc "Removes pending messages older than 24 hours."
  @spec cleanup(t(), integer()) :: t()
  def cleanup(%__MODULE__{} = registry, now_ms) do
    pending =
      Map.reject(registry.pending_messages, fn {_message_id, record} ->
        now_ms - record.sent_at > @day_ms
      end)

    %{registry | pending_messages: pending}
  end

  @doc "Exports a JSON-friendly state map for persistence."
  @spec export_state(t()) :: map()
  def export_state(%__MODULE__{} = registry) do
    %{
      types:
        Map.new(registry.types, fn {name, definition} -> {name, plain_definition(definition)} end),
      stats: Map.new(registry.stats, fn {name, stat} -> {name, Map.from_struct(stat)} end),
      pools:
        Map.new(registry.pools, fn {name, _limiter} -> {name, %{sent: [], timestamps: []}} end),
      pending_messages:
        Map.new(registry.pending_messages, fn {id, record} -> {id, Map.from_struct(record)} end),
      locked: MapSet.to_list(registry.locked)
    }
  end

  @doc "Imports an exported registry state and recreates pure pool limiters."
  @spec import_state(map(), keyword()) :: t()
  def import_state(state, options \\ []) when is_map(state) do
    registry = new(options)

    types =
      state
      |> value(:types, %{})
      |> Map.new(fn {name, definition} ->
        {name, Definition.new(atomize_definition(definition))}
      end)

    registry = %{registry | types: types}

    registry =
      Enum.reduce(types, registry, fn {_name, definition}, registry ->
        ensure_pool(registry, definition)
      end)

    %{
      registry
      | stats: import_stats(value(state, :stats, %{})),
        pending_messages: import_pending(value(state, :pending_messages, %{})),
        locked: MapSet.new(value(state, :locked, []))
    }
  end

  defp normalize_definition(%Definition{} = definition), do: validate_definition(definition)

  defp normalize_definition(definition) when is_map(definition) or is_list(definition) do
    definition |> Definition.new() |> validate_definition()
  rescue
    _error -> :error
  end

  defp normalize_definition(_definition), do: :error

  defp validate_definition(%Definition{priority: priority} = definition)
       when priority in [:critical, :normal, :bulk],
       do: {:ok, definition}

  defp validate_definition(_definition), do: :error

  defp put_type(registry, name, definition) do
    %{
      registry
      | types: Map.put(registry.types, name, definition),
        stats: Map.put(registry.stats, name, %Stats{})
    }
  end

  defp ensure_pool(registry, %Definition{rate_limit_pool: nil}), do: registry

  defp ensure_pool(registry, %Definition{rate_limit_pool: pool} = definition) do
    if Map.has_key?(registry.pools, pool) do
      registry
    else
      limiter = RateLimiter.new(pool_config(definition.priority, registry.rand_fun))
      %{registry | pools: Map.put(registry.pools, pool, limiter)}
    end
  end

  defp pool_config(priority, rand_fun) do
    base = %{
      max_per_minute: 8,
      max_per_hour: 200,
      max_per_day: 1_500,
      min_delay_ms: 1_500,
      max_delay_ms: 5_000,
      new_chat_delay_ms: 3_000,
      max_identical_messages: 3,
      burst_allowance: 3,
      identical_message_window_ms: 3_600_000,
      rand_fun: rand_fun
    }

    case priority do
      :critical ->
        Map.merge(base, %{max_per_minute: 5, max_per_hour: 100, max_per_day: 500})

      :bulk ->
        Map.merge(base, %{
          max_per_minute: 15,
          max_per_hour: 300,
          max_per_day: 2_000,
          min_delay_ms: 1_000,
          max_delay_ms: 3_000
        })

      :normal ->
        base
    end
  end

  defp validate_provenance(_type, %Definition{requires_provenance: []}, _provenance), do: :ok

  defp validate_provenance(type, %Definition{requires_provenance: fields}, provenance)
       when not is_map(provenance),
       do: {:error, {:provenance_required, type, fields}}

  defp validate_provenance(type, %Definition{requires_provenance: fields}, provenance) do
    case Enum.find(fields, &(not provenance_key?(provenance, &1))) do
      nil -> :ok
      field -> {:error, {:provenance_field_required, type, field}}
    end
  end

  defp validate_legitimacy(type, definition, provenance, engagement_score, now_ms) do
    signals = definition.legitimacy_signals

    with :ok <- validate_action_delta(type, signals, provenance, now_ms),
         :ok <- validate_engagement(type, signals, engagement_score) do
      validate_subscription_age(type, signals, provenance, now_ms)
    end
  end

  defp maybe_record_blocked(registry, pending, jid, now_ms) do
    if pending.jid == jid and now_ms - pending.sent_at < @five_minutes_ms do
      update_type_stats(registry, pending.type, fn stat ->
        stat |> Map.update!(:blocked, &(&1 + 1)) |> update_engagement_score()
      end)
    else
      registry
    end
  end

  defp validate_action_delta(_type, nil, _provenance, _now_ms), do: :ok

  defp validate_action_delta(type, signals, provenance, now_ms) do
    timestamp = provenance_value(provenance, :action_timestamp)

    if signals.max_action_delta_ms != nil and truthy_number?(timestamp) and
         now_ms - timestamp > signals.max_action_delta_ms do
      {:error,
       {:max_action_delta_exceeded, type, now_ms - timestamp, signals.max_action_delta_ms}}
    else
      :ok
    end
  end

  defp validate_engagement(_type, nil, _engagement_score), do: :ok

  defp validate_engagement(type, signals, engagement_score) do
    if signals.min_engagement_score != nil and engagement_score != nil and
         engagement_score < signals.min_engagement_score do
      {:error,
       {:min_engagement_score_not_met, type, engagement_score, signals.min_engagement_score}}
    else
      :ok
    end
  end

  defp validate_subscription_age(_type, nil, _provenance, _now_ms), do: :ok

  defp validate_subscription_age(type, signals, provenance, now_ms) do
    verified_at = provenance_value(provenance, :subscription_verified_at)

    if signals.min_subscription_age_days != nil and truthy_number?(verified_at) do
      age_days = (now_ms - verified_at) / @day_ms

      if age_days < signals.min_subscription_age_days do
        {:error,
         {:min_subscription_age_not_met, type, age_days, signals.min_subscription_age_days}}
      else
        :ok
      end
    else
      :ok
    end
  end

  defp pool_delay(registry, %Definition{rate_limit_pool: nil}, _jid, _content, _now_ms),
    do: {:ok, 0, registry}

  defp pool_delay(registry, definition, jid, content, now_ms) do
    pool_name = definition.rate_limit_pool
    limiter = Map.fetch!(registry.pools, pool_name)
    text = content_value(content, :text) || content_value(content, :caption) || ""

    case RateLimiter.get_delay(limiter, jid, text, now_ms) do
      {:allow, delay_ms, limiter} ->
        {:ok, delay_ms, %{registry | pools: Map.put(registry.pools, pool_name, limiter)}}

      {:deny, reason, limiter} ->
        registry = %{registry | pools: Map.put(registry.pools, pool_name, limiter)}
        {:error, {:rate_limit_exceeded, pool_name, reason}, registry}
    end
  end

  defp update_sent_stats(registry, prepared, now_ms) do
    update_type_stats(registry, prepared.type, fn stat ->
      sent = stat.sent + 1
      timestamp = provenance_value(prepared.provenance, :action_timestamp)

      average =
        if truthy_number?(timestamp) do
          delta = now_ms - timestamp
          floor((stat.avg_action_delta_ms * stat.sent + delta) / sent)
        else
          stat.avg_action_delta_ms
        end

      %{stat | sent: sent, avg_action_delta_ms: average}
    end)
  end

  defp record_pool_send(registry, %PreparedSend{pool: nil}, _now_ms), do: registry

  defp record_pool_send(registry, prepared, now_ms) do
    limiter = Map.fetch!(registry.pools, prepared.pool)
    limiter = RateLimiter.record(limiter, prepared.jid, prepared.pool_record_content, now_ms)
    %{registry | pools: Map.put(registry.pools, prepared.pool, limiter)}
  end

  defp record_observation(%__MODULE__{} = registry, message_id, field) do
    case Map.fetch(registry.pending_messages, message_id) do
      :error ->
        registry

      {:ok, pending} ->
        if Map.fetch!(pending, field) do
          registry
        else
          registry
          |> increment_engagement(pending.type, field)
          |> put_pending_observation(message_id, pending, field)
        end
    end
  end

  defp increment_engagement(registry, type, field) do
    update_type_stats(registry, type, fn stat ->
      stat |> Map.update!(field, &(&1 + 1)) |> update_engagement_score()
    end)
  end

  defp put_pending_observation(registry, message_id, pending, field) do
    pending = Map.replace!(pending, field, true)
    %{registry | pending_messages: Map.put(registry.pending_messages, message_id, pending)}
  end

  defp update_engagement_score(%Stats{sent: 0} = stat), do: stat

  defp update_engagement_score(stat) do
    read_rate = stat.read / stat.sent
    reply_rate = stat.replied / stat.sent
    not_blocked_rate = 1 - stat.blocked / stat.sent
    score = round((read_rate * 0.3 + reply_rate * 0.5 + not_blocked_rate * 0.2) * 100)
    %{stat | engagement_score: score}
  end

  defp update_type_stats(registry, type, update_fun) do
    case Map.fetch(registry.stats, type) do
      :error -> registry
      {:ok, stat} -> %{registry | stats: Map.put(registry.stats, type, update_fun.(stat))}
    end
  end

  defp warnings_for_type(_type, %Stats{sent: sent}, _definition)
       when sent < @minimum_warning_sample,
       do: []

  defp warnings_for_type(type, stat, definition) do
    []
    |> maybe_engagement_warning(type, stat)
    |> maybe_delivery_warning(type, stat)
    |> maybe_blocked_warning(type, stat)
    |> maybe_action_delta_warning(type, stat, definition)
  end

  defp maybe_engagement_warning(warnings, type, stat) when stat.engagement_score < 50 do
    warnings ++
      [
        warning(
          type,
          :engagement,
          stat.engagement_score,
          50,
          "Low engagement score for '#{type}': #{one_decimal(stat.engagement_score)}/100"
        )
      ]
  end

  defp maybe_engagement_warning(warnings, _type, _stat), do: warnings

  defp maybe_delivery_warning(warnings, type, stat)
       when stat.sent >= @minimum_rate_warning_sample and stat.delivered / stat.sent < 0.7 do
    rate = stat.delivered / stat.sent

    warnings ++
      [
        warning(
          type,
          :delivery_rate,
          rate,
          0.7,
          "Low delivery rate for '#{type}': #{one_decimal(rate * 100)}%"
        )
      ]
  end

  defp maybe_delivery_warning(warnings, _type, _stat), do: warnings

  defp maybe_blocked_warning(warnings, type, stat)
       when stat.sent >= @minimum_rate_warning_sample and stat.blocked / stat.sent > 0.1 do
    rate = stat.blocked / stat.sent

    warnings ++
      [
        warning(
          type,
          :blocked_rate,
          rate,
          0.1,
          "High blocked rate for '#{type}': #{one_decimal(rate * 100)}%"
        )
      ]
  end

  defp maybe_blocked_warning(warnings, _type, _stat), do: warnings

  defp maybe_action_delta_warning(warnings, type, stat, %Definition{priority: :critical})
       when stat.sent >= @minimum_warning_sample and stat.avg_action_delta_ms > 5_000 do
    warnings ++
      [
        warning(
          type,
          :action_delta,
          stat.avg_action_delta_ms,
          5_000,
          "High action delta for '#{type}': #{one_decimal(stat.avg_action_delta_ms / 1_000)}s"
        )
      ]
  end

  defp maybe_action_delta_warning(warnings, _type, _stat, _definition), do: warnings

  defp warning(type, metric, current, threshold, message) do
    %Warning{type: type, metric: metric, current: current, threshold: threshold, message: message}
  end

  defp plain_definition(definition) do
    definition
    |> Map.from_struct()
    |> Map.update!(:legitimacy_signals, &plain_nested/1)
    |> Map.update!(:engagement_tracking, &plain_nested/1)
  end

  defp plain_nested(nil), do: nil
  defp plain_nested(struct), do: Map.from_struct(struct)

  defp atomize_definition(definition) do
    definition = Map.new(definition)

    %{
      priority: enum_atom(value(definition, :priority), [:critical, :normal, :bulk]),
      rate_limit_pool: value(definition, :rate_limit_pool),
      requires_provenance: value(definition, :requires_provenance, []),
      legitimacy_signals: atomize_nested(value(definition, :legitimacy_signals)),
      delivery_guarantee:
        enum_atom(value(definition, :delivery_guarantee), [:at_least_once, :best_effort]),
      engagement_tracking: atomize_nested(value(definition, :engagement_tracking))
    }
  end

  defp atomize_nested(nil), do: nil

  defp atomize_nested(value) do
    value
    |> Map.new()
    |> Map.new(fn {key, item} -> {known_atom(key), item} end)
  end

  defp known_atom(key) when is_atom(key), do: key

  defp known_atom(key) when is_binary(key) do
    String.to_existing_atom(key)
  rescue
    ArgumentError -> key
  end

  defp enum_atom(value, allowed) when is_binary(value) do
    Enum.find(allowed, &(Atom.to_string(&1) == value))
  end

  defp enum_atom(value, allowed) do
    if Enum.member?(allowed, value), do: value, else: nil
  end

  defp import_stats(stats) do
    defaults = struct(Stats) |> Map.from_struct()

    Map.new(stats, fn {name, stat} ->
      values = Map.new(defaults, fn {key, default} -> {key, value(stat, key, default)} end)

      {name, struct!(Stats, values)}
    end)
  end

  defp import_pending(pending_messages) do
    Map.new(pending_messages, fn {id, pending} ->
      {id,
       %PendingMessage{
         type: value(pending, :type),
         jid: value(pending, :jid),
         sent_at: value(pending, :sent_at),
         provenance: value(pending, :provenance),
         delivered: value(pending, :delivered, false),
         read: value(pending, :read, false)
       }}
    end)
  end

  defp provenance_key?(provenance, field) when is_atom(field) do
    Map.has_key?(provenance, field) or Map.has_key?(provenance, Atom.to_string(field))
  end

  defp provenance_key?(provenance, field) when is_binary(field) do
    Map.has_key?(provenance, field) or
      case safe_existing_atom(field) do
        nil -> false
        atom -> Map.has_key?(provenance, atom)
      end
  end

  defp provenance_value(provenance, key) when is_map(provenance), do: value(provenance, key)
  defp provenance_value(_provenance, _key), do: nil

  defp content_value(content, key) when is_map(content), do: value(content, key)
  defp content_value(_content, _key), do: nil

  defp value(map, key, default \\ nil) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp safe_existing_atom(value) do
    String.to_existing_atom(value)
  rescue
    ArgumentError -> nil
  end

  defp truthy_number?(number), do: is_number(number) and number != 0
  defp present_string?(value), do: is_binary(value) and value != ""
  defp one_decimal(value), do: :erlang.float_to_binary(value / 1, decimals: 1)
end

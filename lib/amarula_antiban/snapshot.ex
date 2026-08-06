defmodule AmarulaAntiban.Snapshot do
  @moduledoc """
  Versioned, JSON-safe export and restore of `AmarulaAntiban.State`.

  Every import performs an actual Jason encode/decode boundary before touching
  core state. Tagged maps preserve atom keys, tuples, and `MapSet`s without
  creating atoms from external input.
  """

  alias AmarulaAntiban.Core
  alias AmarulaAntiban.State

  @schema_version 1
  @tag "$amarula_antiban_type"

  @doc "Returns the current snapshot schema version."
  @spec schema_version() :: pos_integer()
  def schema_version, do: @schema_version

  @doc "Exports all mutable core state at the explicit clock value."
  @spec export(State.t(), integer()) :: map()
  def export(%State{} = state, now_ms) do
    payload = %{
      rate_limiter: rate_limiter_data(state.rate_limiter),
      warm_up: Core.WarmUp.export(state.warm_up, now_ms),
      health: mutable_data(state.health),
      timelock_guard: mutable_data(state.timelock_guard),
      reply_ratio: Core.ReplyRatio.export(state.reply_ratio),
      contact_graph: Core.ContactGraph.export(state.contact_graph),
      presence: mutable_data(state.presence),
      retry_tracker: mutable_data(state.retry_tracker),
      reconnect_throttle: mutable_data(state.reconnect_throttle),
      delivery_tracker: mutable_data(state.delivery_tracker),
      circuit_breaker: Core.JidCircuitBreaker.export(state.circuit_breaker),
      session_health: mutable_data(state.session_health),
      deaf_session: mutable_data(state.deaf_session),
      jid_canonicalizer: mutable_data(state.jid_canonicalizer),
      message_type_registry: Core.MessageTypeRegistry.export_state(state.message_type_registry),
      content_variator: mutable_data(state.content_variator),
      topology_throttler: Core.TopologyThrottler.export(state.topology_throttler),
      ban_recovery: Core.BanRecovery.export(state.ban_recovery),
      legitimacy_signals: mutable_data(state.legitimacy_signals),
      group_operation_guard: Core.GroupOperationGuard.export(state.group_operation_guard),
      human_entropy: mutable_data(state.human_entropy),
      reservations: state.reservations,
      counters: %{
        messages_allowed: state.messages_allowed,
        messages_blocked: state.messages_blocked,
        total_delay_ms: state.total_delay_ms
      }
    }

    %{
      "schema_version" => @schema_version,
      "exported_at" => now_ms,
      "state" => encode_term(payload)
    }
  end

  @doc """
  Restores a snapshot into a freshly configured aggregate.

  Configuration and injected functions always come from `fresh`; only mutable
  state is restored.
  """
  @spec restore(map(), State.t(), integer()) :: {:ok, State.t()} | {:error, term()}
  def restore(snapshot, %State{} = fresh, now_ms) when is_map(snapshot) do
    with {:ok, json} <- Jason.encode(snapshot),
         {:ok, decoded_snapshot} <- Jason.decode(json),
         :ok <- validate(decoded_snapshot),
         {:ok, payload} <- decode_term(decoded_snapshot["state"]),
         :ok <- validate_payload(payload, fresh, now_ms) do
      safe_restore_payload(fresh, payload, now_ms)
    else
      {:error, %Jason.EncodeError{} = error} -> {:error, {:not_json_safe, error}}
      {:error, %Jason.DecodeError{} = error} -> {:error, {:invalid_json, error}}
      {:error, _reason} = error -> error
    end
  end

  def restore(_snapshot, %State{}, _now_ms), do: {:error, :invalid_snapshot}

  defp validate(%{"schema_version" => @schema_version, "state" => state})
       when is_map(state),
       do: :ok

  defp validate(%{"schema_version" => version}),
    do: {:error, {:unsupported_schema_version, version}}

  defp validate(_snapshot), do: {:error, :invalid_snapshot}

  defp safe_restore_payload(fresh, payload, now_ms) do
    restored = restore_payload(fresh, payload, now_ms)

    if valid_restored_state?(restored),
      do: {:ok, restored},
      else: {:error, :invalid_snapshot}
  rescue
    _error -> {:error, :invalid_snapshot}
  catch
    _kind, _reason -> {:error, :invalid_snapshot}
  end

  defp restore_payload(fresh, payload, now_ms) do
    fresh
    |> Map.put(
      :rate_limiter,
      restore_rate_limiter(fresh.rate_limiter, value(payload, :rate_limiter))
    )
    |> Map.put(:warm_up, restore_warm_up(fresh.warm_up, value(payload, :warm_up), now_ms))
    |> Map.put(:health, restore_struct(fresh.health, value(payload, :health)))
    |> Map.put(
      :timelock_guard,
      restore_struct(fresh.timelock_guard, value(payload, :timelock_guard))
    )
    |> Map.put(
      :reply_ratio,
      restore_reply_ratio(fresh.reply_ratio, value(payload, :reply_ratio))
    )
    |> Map.put(
      :contact_graph,
      restore_contact_graph(fresh.contact_graph, value(payload, :contact_graph))
    )
    |> Map.put(:presence, restore_presence(fresh.presence, value(payload, :presence)))
    |> Map.put(
      :retry_tracker,
      restore_struct(fresh.retry_tracker, value(payload, :retry_tracker))
    )
    |> Map.put(
      :reconnect_throttle,
      restore_struct(fresh.reconnect_throttle, value(payload, :reconnect_throttle))
    )
    |> Map.put(
      :delivery_tracker,
      restore_struct(fresh.delivery_tracker, value(payload, :delivery_tracker))
    )
    |> Map.put(
      :circuit_breaker,
      Core.JidCircuitBreaker.import(fresh.circuit_breaker, value(payload, :circuit_breaker, []))
    )
    |> Map.put(
      :session_health,
      restore_session_health(fresh.session_health, value(payload, :session_health))
    )
    |> Map.put(:deaf_session, restore_struct(fresh.deaf_session, value(payload, :deaf_session)))
    |> Map.put(
      :jid_canonicalizer,
      restore_jid_canonicalizer(fresh.jid_canonicalizer, value(payload, :jid_canonicalizer))
    )
    |> Map.put(
      :message_type_registry,
      Core.MessageTypeRegistry.import_state(
        value(payload, :message_type_registry, %{}),
        rand_fun: fresh.config.rand_fun
      )
    )
    |> Map.put(
      :content_variator,
      restore_struct(fresh.content_variator, value(payload, :content_variator))
    )
    |> Map.put(
      :topology_throttler,
      restore_topology_throttler(fresh.topology_throttler, value(payload, :topology_throttler))
    )
    |> Map.put(
      :ban_recovery,
      restore_ban_recovery(fresh.ban_recovery, value(payload, :ban_recovery))
    )
    |> Map.put(
      :legitimacy_signals,
      restore_legitimacy_signals(fresh.legitimacy_signals, value(payload, :legitimacy_signals))
    )
    |> Map.put(
      :group_operation_guard,
      restore_group_operation_guard(
        fresh.group_operation_guard,
        value(payload, :group_operation_guard)
      )
    )
    |> Map.put(
      :human_entropy,
      restore_struct(fresh.human_entropy, value(payload, :human_entropy))
    )
    |> Map.put(:reservations, value(payload, :reservations, %{}))
    |> restore_counters(value(payload, :counters, %{}))
  end

  defp restore_reply_ratio(ratio, nil), do: ratio
  defp restore_reply_ratio(ratio, data), do: Core.ReplyRatio.restore(ratio, data)

  defp restore_contact_graph(graph, nil), do: graph
  defp restore_contact_graph(graph, data), do: Core.ContactGraph.restore(graph, data)

  defp restore_topology_throttler(throttler, nil), do: throttler

  defp restore_topology_throttler(throttler, data),
    do: Core.TopologyThrottler.restore(throttler, data)

  defp restore_ban_recovery(recovery, nil), do: recovery
  defp restore_ban_recovery(recovery, data), do: Core.BanRecovery.restore(recovery, data)

  defp restore_group_operation_guard(guard, nil), do: guard

  defp restore_group_operation_guard(guard, data),
    do: Core.GroupOperationGuard.restore(guard, data)

  defp restore_rate_limiter(limiter, data) do
    data = data || %{}
    factor = value(data, :current_factor, 1.0)

    limiter
    |> restore_struct(Map.delete(data, :current_factor))
    |> Core.RateLimiter.adapt_limits(factor)
  end

  defp restore_warm_up(warm_up, nil, _now_ms), do: warm_up

  defp restore_warm_up(warm_up, persisted, now_ms) do
    config = Map.from_struct(warm_up.config)
    Core.WarmUp.restore(config, persisted, now_ms)
  end

  defp restore_presence(presence, nil), do: presence

  defp restore_presence(presence, data) do
    counters = restore_struct(presence.counters, value(data, :counters, %{}))
    %{restore_struct(presence, Map.delete(data, :counters)) | counters: counters}
  end

  defp restore_session_health(health, nil), do: health

  defp restore_session_health(health, data) do
    stats = restore_struct(health.stats, value(data, :stats, %{}))
    %{restore_struct(health, Map.delete(data, :stats)) | stats: stats}
  end

  defp restore_jid_canonicalizer(canonicalizer, nil), do: canonicalizer

  defp restore_jid_canonicalizer(canonicalizer, data) do
    stats = restore_struct(canonicalizer.stats, value(data, :stats, %{}))
    %{canonicalizer | stats: stats}
  end

  defp restore_legitimacy_signals(injector, nil), do: injector

  defp restore_legitimacy_signals(injector, data) do
    stats = restore_struct(injector.stats, value(data, :stats, %{}))
    %{restore_struct(injector, Map.delete(data, :stats)) | stats: stats}
  end

  defp restore_counters(state, counters) do
    %{
      state
      | messages_allowed: value(counters, :messages_allowed, 0),
        messages_blocked: value(counters, :messages_blocked, 0),
        total_delay_ms: value(counters, :total_delay_ms, 0)
    }
  end

  defp restore_struct(struct, nil), do: struct

  defp restore_struct(struct, data) when is_struct(struct) and is_map(data) do
    current = Map.from_struct(struct)
    restored = Map.merge(current, Map.take(data, Map.keys(current)))
    struct(struct.__struct__, restored)
  end

  defp restore_struct(struct, _invalid), do: struct

  defp validate_payload(payload, fresh, now_ms) when is_map(payload) do
    reference = export(fresh, now_ms)["state"]

    with {:ok, decoded_reference} <- decode_term(reference),
         true <- compatible_map?(payload, decoded_reference),
         true <- valid_counters?(value(payload, :counters, %{})),
         true <- is_map(value(payload, :reservations, %{})) do
      :ok
    else
      _invalid -> {:error, :invalid_snapshot}
    end
  end

  defp validate_payload(_payload, _fresh, _now_ms), do: {:error, :invalid_snapshot}

  defp compatible_map?(candidate, reference)
       when is_map(candidate) and is_map(reference) and map_size(reference) == 0,
       do: true

  defp compatible_map?(candidate, reference) when is_map(candidate) and is_map(reference),
    do: Enum.all?(candidate, &compatible_entry?(&1, reference))

  defp compatible_map?(_candidate, _reference), do: false

  defp compatible_entry?({key, value}, reference) do
    case Map.fetch(reference, key) do
      {:ok, reference_value} -> compatible_value?(value, reference_value)
      :error -> false
    end
  end

  defp compatible_value?(%MapSet{}, %MapSet{}), do: true

  defp compatible_value?(candidate, reference)
       when is_map(candidate) and is_map(reference),
       do: compatible_map?(candidate, reference)

  defp compatible_value?(candidate, reference) when is_list(candidate) and is_list(reference),
    do: true

  defp compatible_value?(candidate, reference) when is_tuple(candidate) and is_tuple(reference),
    do: tuple_size(candidate) == tuple_size(reference)

  defp compatible_value?(candidate, reference) when is_integer(reference),
    do: is_integer(candidate) and (reference < 0 or candidate >= 0)

  defp compatible_value?(candidate, reference) when is_float(reference),
    do: is_number(candidate) and (reference < 0 or candidate >= 0)

  defp compatible_value?(candidate, reference) when is_binary(reference),
    do: is_binary(candidate)

  defp compatible_value?(candidate, reference) when is_boolean(reference),
    do: is_boolean(candidate)

  defp compatible_value?(candidate, nil),
    do: is_nil(candidate) or is_integer(candidate) or is_binary(candidate)

  defp compatible_value?(candidate, reference) when is_atom(reference),
    do: is_atom(candidate)

  defp compatible_value?(_candidate, _reference), do: false

  defp valid_counters?(counters) when is_map(counters) do
    Enum.all?([:messages_allowed, :messages_blocked, :total_delay_ms], fn key ->
      case value(counters, key, 0) do
        number when is_integer(number) and number >= 0 -> true
        _invalid -> false
      end
    end)
  end

  defp valid_counters?(_counters), do: false

  defp valid_restored_state?(%State{} = state) do
    is_map(state.reservations) and
      valid_reservations?(state.reservations) and
      Enum.all?(
        [state.messages_allowed, state.messages_blocked, state.total_delay_ms],
        fn value ->
          is_integer(value) and value >= 0
        end
      ) and runtime_valid?(state)
  end

  defp valid_reservations?(reservations) do
    Enum.all?(reservations, fn
      {msg_id, %{reserved_at: reserved_at, decision: decision}}
      when is_binary(msg_id) and is_integer(reserved_at) and reserved_at >= 0 and is_map(decision) ->
        true

      _invalid ->
        false
    end)
  end

  defp runtime_valid?(state) do
    now_ms = max(state.health.start_time, 0)
    _ = Core.Health.status(state.health, now_ms)
    _ = Core.WarmUp.status(state.warm_up, now_ms)
    _ = Core.RateLimiter.stats(state.rate_limiter, now_ms)
    _ = Core.DeliveryTracker.stats(state.delivery_tracker, now_ms)
    _ = Core.ReplyRatio.stats(state.reply_ratio, now_ms)
    _ = Core.ContactGraph.stats(state.contact_graph)
    _ = Core.Presence.stats(state.presence, now_ms)
    _ = Core.RetryTracker.stats(state.retry_tracker)
    _ = Core.ReconnectThrottle.stats(state.reconnect_throttle, now_ms)
    _ = Core.JidCircuitBreaker.stats(state.circuit_breaker)
    _ = Core.SessionHealth.stats(state.session_health)
    _ = Core.JidCanonicalizer.stats(state.jid_canonicalizer)
    _ = Core.TopologyThrottler.stats(state.topology_throttler, now_ms)
    _ = Core.BanRecovery.status(state.ban_recovery, now_ms)
    _ = Core.LegitimacySignals.stats(state.legitimacy_signals)
    _ = Core.GroupOperationGuard.stats(state.group_operation_guard)
    _ = Core.HumanEntropy.stats(state.human_entropy)
    true
  end

  defp rate_limiter_data(limiter) do
    limiter
    |> mutable_data()
    |> Map.put(:current_factor, Core.RateLimiter.current_factor(limiter))
  end

  defp mutable_data(struct) do
    struct
    |> Map.from_struct()
    |> Map.drop([:config, :original_config, :rand_fun])
  end

  defp value(map, key, default \\ nil)
  defp value(nil, _key, default), do: default

  defp value(map, key, default),
    do: Map.get(map, key, Map.get(map, Atom.to_string(key), default))

  defp encode_term(%MapSet{} = set) do
    %{@tag => "map_set", "value" => Enum.map(set, &encode_term/1)}
  end

  defp encode_term(%_{} = struct), do: struct |> Map.from_struct() |> encode_term()

  defp encode_term(map) when is_map(map) do
    entries = Enum.map(map, fn {key, value} -> [encode_term(key), encode_term(value)] end)
    %{@tag => "map", "entries" => entries}
  end

  defp encode_term(tuple) when is_tuple(tuple) do
    %{@tag => "tuple", "value" => tuple |> Tuple.to_list() |> Enum.map(&encode_term/1)}
  end

  defp encode_term(nil), do: nil

  defp encode_term(atom) when is_atom(atom),
    do: %{@tag => "atom", "value" => Atom.to_string(atom)}

  defp encode_term(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: value

  defp encode_term(list) when is_list(list), do: Enum.map(list, &encode_term/1)

  defp decode_term(%{@tag => "map", "entries" => entries}) when is_list(entries) do
    Enum.reduce_while(entries, {:ok, %{}}, fn
      [encoded_key, encoded_value], {:ok, map} ->
        with {:ok, key} <- decode_term(encoded_key),
             {:ok, value} <- decode_term(encoded_value) do
          {:cont, {:ok, Map.put(map, key, value)}}
        else
          {:error, _reason} = error -> {:halt, error}
        end

      _invalid, _accumulator ->
        {:halt, {:error, :invalid_map_entry}}
    end)
  end

  defp decode_term(%{@tag => "map_set", "value" => values}) when is_list(values) do
    with {:ok, decoded} <- decode_list(values), do: {:ok, MapSet.new(decoded)}
  end

  defp decode_term(%{@tag => "tuple", "value" => values}) when is_list(values) do
    with {:ok, decoded} <- decode_list(values), do: {:ok, List.to_tuple(decoded)}
  end

  defp decode_term(%{@tag => "atom", "value" => atom}) when is_binary(atom) do
    {:ok, String.to_existing_atom(atom)}
  rescue
    ArgumentError -> {:error, {:unknown_atom, atom}}
  end

  defp decode_term(value) when is_binary(value) or is_number(value) or is_boolean(value),
    do: {:ok, value}

  defp decode_term(nil), do: {:ok, nil}
  defp decode_term(list) when is_list(list), do: decode_list(list)
  defp decode_term(_invalid), do: {:error, :invalid_tagged_term}

  defp decode_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn encoded, {:ok, decoded} ->
      case decode_term(encoded) do
        {:ok, value} -> {:cont, {:ok, [value | decoded]}}
        {:error, _reason} = error -> {:halt, error}
      end
    end)
    |> then(fn
      {:ok, decoded} -> {:ok, Enum.reverse(decoded)}
      error -> error
    end)
  end
end

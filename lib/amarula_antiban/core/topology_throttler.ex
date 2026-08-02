defmodule AmarulaAntiban.Core.TopologyThrottler do
  @moduledoc """
  Pure contact-graph expansion limiter and per-contact risk scorer.

  WhatsApp bans on network topology, not just message timing: how fast the
  contact graph grows, cold-contact ratio, and reply reciprocity. This module
  enforces graph-expansion limits (new contacts/hour/day, minimum reply
  ratio) and scores each contact's risk before a send.

  Resets are rolling windows (elapsed time since the last reset), not
  calendar-boundary resets, matching the upstream `resetLimitsIfNeeded`
  behavior exactly.

  The upstream `knownGroups`/`sourceGroup` signals (mutual-group membership,
  same-group hotspot detection) require group metadata Amarula does not yet
  expose to the plugin. `assess/4` always treats mutual groups as empty
  (upstream's own default when the caller passes no context), which is
  conservative — it never under-estimates risk.
  """

  @ms_per_hour 3_600_000
  @ms_per_day 86_400_000
  @reply_window_ms 7 * @ms_per_day

  defmodule Config do
    @moduledoc "Graph-expansion limits and risk-scoring weights."

    @type t :: %__MODULE__{
            enabled: boolean(),
            max_new_contacts_per_hour: pos_integer(),
            max_new_contacts_per_day: pos_integer(),
            min_reply_ratio_for_new_contacts: float(),
            cooldown_ms: non_neg_integer(),
            first_contact_penalty: integer(),
            no_reply_penalty: integer(),
            no_mutual_groups_penalty: integer(),
            recent_contact_bonus: integer(),
            replied_before_bonus: integer(),
            delay_threshold: non_neg_integer(),
            abort_threshold: non_neg_integer()
          }

    defstruct enabled: false,
              max_new_contacts_per_hour: 5,
              max_new_contacts_per_day: 20,
              min_reply_ratio_for_new_contacts: 0.3,
              cooldown_ms: 3_600_000,
              first_contact_penalty: 40,
              no_reply_penalty: 20,
              no_mutual_groups_penalty: 15,
              recent_contact_bonus: -20,
              replied_before_bonus: -30,
              delay_threshold: 40,
              abort_threshold: 75
  end

  defmodule Stats do
    @moduledoc "Rolling-window topology statistics."

    @type t :: %__MODULE__{
            new_contacts_this_hour: non_neg_integer(),
            new_contacts_today: non_neg_integer(),
            reply_ratio: float() | nil,
            cooldown_remaining_ms: non_neg_integer() | nil,
            tracked_contacts: non_neg_integer()
          }

    defstruct new_contacts_this_hour: 0,
              new_contacts_today: 0,
              reply_ratio: nil,
              cooldown_remaining_ms: nil,
              tracked_contacts: 0
  end

  @type contact_record :: %{
          first_contact_at: integer(),
          send_timestamps: [integer()],
          reply_timestamps: [integer()],
          blocked: boolean()
        }
  @type recommendation :: :send | :delay | :abort
  @type t :: %__MODULE__{
          config: Config.t(),
          contacts: %{optional(String.t()) => contact_record()},
          new_contacts_this_hour: non_neg_integer(),
          new_contacts_today: non_neg_integer(),
          last_hour_reset_at: integer(),
          last_day_reset_at: integer(),
          limit_hit_at: integer() | nil
        }

  defstruct config: nil,
            contacts: %{},
            new_contacts_this_hour: 0,
            new_contacts_today: 0,
            last_hour_reset_at: 0,
            last_day_reset_at: 0,
            limit_hit_at: nil

  @doc "Builds a throttler at the injected time."
  @spec new(keyword() | map(), integer()) :: t()
  def new(options \\ [], now_ms) do
    %__MODULE__{
      config: struct!(Config, Map.new(options)),
      last_hour_reset_at: now_ms,
      last_day_reset_at: now_ms
    }
  end

  @doc """
  Gates and risk-assesses a prospective send to `jid`.

  New contacts (never previously recorded via `record_sent/3`) go through the
  hard graph-expansion gate first (cooldown, hourly/daily caps, minimum reply
  ratio). Any contact that passes the gate — new or already known — is then
  risk-scored; `:abort` denies the send, `:delay` allows it with a suggested
  delay, `:send` allows it immediately.
  """
  @spec before_send(t(), String.t(), integer()) ::
          {:allow, :send | :delay, non_neg_integer(), t()} | {:deny, String.t(), t()}
  def before_send(%__MODULE__{config: %{enabled: false}} = throttler, _jid, _now_ms),
    do: {:allow, :send, 0, throttler}

  def before_send(throttler, jid, now_ms) do
    throttler = reset_if_needed(throttler, now_ms)
    known? = Map.has_key?(throttler.contacts, jid)

    gate_result =
      if known?, do: {:allow, throttler}, else: check_new_contact_gate(throttler, now_ms)

    case gate_result do
      {:deny, reason, throttler} ->
        {:deny, reason, throttler}

      {:allow, throttler} ->
        {score, recommendation} = assess(throttler, jid, known?, now_ms)
        respond(recommendation, score, throttler)
    end
  end

  @doc "Records a sent message, registering a new contact if unseen."
  @spec record_sent(t(), String.t(), integer()) :: t()
  def record_sent(%__MODULE__{config: %{enabled: false}} = throttler, _jid, _now_ms),
    do: throttler

  def record_sent(throttler, jid, now_ms) do
    throttler = reset_if_needed(throttler, now_ms)
    {record, throttler} = fetch_or_register(throttler, jid, now_ms)
    send_timestamps = prune_window([now_ms | record.send_timestamps], now_ms, @reply_window_ms)
    put_contact(throttler, jid, %{record | send_timestamps: send_timestamps})
  end

  @doc "Records a reply from `jid`. A no-op if the contact was never sent to."
  @spec record_replied(t(), String.t(), integer()) :: t()
  def record_replied(throttler, jid, now_ms) do
    case Map.get(throttler.contacts, jid) do
      nil ->
        throttler

      record ->
        reply_timestamps =
          prune_window([now_ms | record.reply_timestamps], now_ms, @reply_window_ms)

        put_contact(throttler, jid, %{record | reply_timestamps: reply_timestamps})
    end
  end

  @doc "Records that `jid` blocked the account. A no-op if never contacted."
  @spec record_blocked(t(), String.t()) :: t()
  def record_blocked(throttler, jid) do
    case Map.get(throttler.contacts, jid) do
      nil -> throttler
      record -> put_contact(throttler, jid, %{record | blocked: true})
    end
  end

  @doc "Returns rolling-window statistics and the reset-cleaned throttler."
  @spec stats(t(), integer()) :: {Stats.t(), t()}
  def stats(throttler, now_ms) do
    throttler = reset_if_needed(throttler, now_ms)

    stats = %Stats{
      new_contacts_this_hour: throttler.new_contacts_this_hour,
      new_contacts_today: throttler.new_contacts_today,
      reply_ratio: reply_ratio(throttler, now_ms),
      cooldown_remaining_ms: cooldown_remaining_ms(throttler, now_ms),
      tracked_contacts: map_size(throttler.contacts)
    }

    {stats, throttler}
  end

  @doc "Exports throttler state for persistence."
  @spec export(t()) :: map()
  def export(throttler) do
    Map.take(throttler, [
      :contacts,
      :new_contacts_this_hour,
      :new_contacts_today,
      :last_hour_reset_at,
      :last_day_reset_at,
      :limit_hit_at
    ])
  end

  @doc "Restores throttler state while retaining configuration."
  @spec restore(t(), map()) :: t()
  def restore(throttler, state) when is_map(state) do
    %{
      throttler
      | contacts: state |> persisted_value(:contacts, %{}) |> normalize_contacts(),
        new_contacts_this_hour:
          persisted_value(state, :new_contacts_this_hour, throttler.new_contacts_this_hour),
        new_contacts_today:
          persisted_value(state, :new_contacts_today, throttler.new_contacts_today),
        last_hour_reset_at:
          persisted_value(state, :last_hour_reset_at, throttler.last_hour_reset_at),
        last_day_reset_at:
          persisted_value(state, :last_day_reset_at, throttler.last_day_reset_at),
        limit_hit_at: normalize_limit_hit_at(persisted_value(state, :limit_hit_at))
    }
  end

  defp respond(:abort, score, throttler) do
    {:deny,
     "Contact risk score #{score} exceeds abort threshold (#{throttler.config.abort_threshold})",
     throttler}
  end

  defp respond(:delay, score, throttler) do
    delay_ms = floor((score - throttler.config.delay_threshold) / 10) * 60_000
    {:allow, :delay, delay_ms, throttler}
  end

  defp respond(:send, _score, throttler), do: {:allow, :send, 0, throttler}

  defp check_new_contact_gate(throttler, now_ms) do
    cond do
      cooldown_active?(throttler, now_ms) ->
        {:deny, "Cooldown active — limit hit recently", throttler}

      throttler.new_contacts_this_hour >= throttler.config.max_new_contacts_per_hour ->
        {:deny,
         "Hourly new contact limit reached (#{throttler.config.max_new_contacts_per_hour})",
         %{throttler | limit_hit_at: now_ms}}

      throttler.new_contacts_today >= throttler.config.max_new_contacts_per_day ->
        {:deny, "Daily new contact limit reached (#{throttler.config.max_new_contacts_per_day})",
         %{throttler | limit_hit_at: now_ms}}

      true ->
        check_reply_ratio_gate(throttler, now_ms)
    end
  end

  defp check_reply_ratio_gate(throttler, now_ms) do
    case reply_ratio(throttler, now_ms) do
      nil ->
        {:allow, throttler}

      ratio when ratio < throttler.config.min_reply_ratio_for_new_contacts ->
        required = round(throttler.config.min_reply_ratio_for_new_contacts * 100)
        {:deny, "Reply ratio too low (#{round(ratio * 100)}% < #{required}%)", throttler}

      _ratio ->
        {:allow, throttler}
    end
  end

  defp cooldown_active?(%{limit_hit_at: nil}, _now_ms), do: false

  defp cooldown_active?(throttler, now_ms),
    do: now_ms < throttler.limit_hit_at + throttler.config.cooldown_ms

  defp assess(throttler, jid, known?, now_ms) do
    config = throttler.config
    record = Map.get(throttler.contacts, jid)

    score = if known?, do: 0, else: config.first_contact_penalty
    score = score + no_reply_penalty(record, known?, config)
    score = score + config.no_mutual_groups_penalty
    score = score + recent_contact_bonus(record, config, now_ms)
    score = score + replied_before_bonus(record, config)
    score = score |> max(0) |> min(100)

    recommendation =
      cond do
        score >= config.abort_threshold -> :abort
        score >= config.delay_threshold -> :delay
        true -> :send
      end

    {score, recommendation}
  end

  defp no_reply_penalty(%{reply_timestamps: [], send_timestamps: [_ | _]}, true, config),
    do: config.no_reply_penalty

  defp no_reply_penalty(_record, _known?, _config), do: 0

  defp recent_contact_bonus(%{send_timestamps: [last | _]}, config, now_ms)
       when now_ms - last < @ms_per_day,
       do: config.recent_contact_bonus

  defp recent_contact_bonus(_record, _config, _now_ms), do: 0

  defp replied_before_bonus(%{reply_timestamps: [_ | _]}, config), do: config.replied_before_bonus
  defp replied_before_bonus(_record, _config), do: 0

  defp fetch_or_register(throttler, jid, now_ms) do
    case Map.get(throttler.contacts, jid) do
      nil ->
        record = %{
          first_contact_at: now_ms,
          send_timestamps: [],
          reply_timestamps: [],
          blocked: false
        }

        throttler = %{
          throttler
          | new_contacts_this_hour: throttler.new_contacts_this_hour + 1,
            new_contacts_today: throttler.new_contacts_today + 1
        }

        {record, throttler}

      record ->
        {record, throttler}
    end
  end

  defp put_contact(throttler, jid, record),
    do: %{throttler | contacts: Map.put(throttler.contacts, jid, record)}

  defp reset_if_needed(throttler, now_ms) do
    throttler =
      if now_ms - throttler.last_hour_reset_at >= @ms_per_hour,
        do: %{throttler | new_contacts_this_hour: 0, last_hour_reset_at: now_ms},
        else: throttler

    if now_ms - throttler.last_day_reset_at >= @ms_per_day,
      do: %{throttler | new_contacts_today: 0, last_day_reset_at: now_ms},
      else: throttler
  end

  defp reply_ratio(throttler, now_ms) do
    {sent, replied} =
      Enum.reduce(throttler.contacts, {0, 0}, fn {_jid, record}, {sent, replied} ->
        {sent + count_within(record.send_timestamps, now_ms),
         replied + count_within(record.reply_timestamps, now_ms)}
      end)

    if sent == 0, do: nil, else: replied / sent
  end

  defp count_within(timestamps, now_ms),
    do: Enum.count(timestamps, &(now_ms - &1 < @reply_window_ms))

  defp cooldown_remaining_ms(%{limit_hit_at: nil}, _now_ms), do: nil

  defp cooldown_remaining_ms(throttler, now_ms) do
    remaining = throttler.limit_hit_at + throttler.config.cooldown_ms - now_ms
    if remaining > 0, do: remaining, else: nil
  end

  defp prune_window(timestamps, now_ms, window_ms),
    do: Enum.filter(timestamps, &(now_ms - &1 < window_ms))

  defp normalize_contacts(contacts) when is_map(contacts) do
    Map.new(contacts, fn {jid, record} ->
      normalized = %{
        first_contact_at: persisted_value(record, :first_contact_at, 0),
        send_timestamps:
          record |> persisted_value(:send_timestamps, []) |> normalize_timestamps(),
        reply_timestamps:
          record |> persisted_value(:reply_timestamps, []) |> normalize_timestamps(),
        blocked: persisted_value(record, :blocked, false) == true
      }

      {to_string(jid), normalized}
    end)
  end

  defp normalize_contacts(_invalid), do: %{}

  defp normalize_timestamps(list) when is_list(list), do: Enum.filter(list, &is_integer/1)
  defp normalize_timestamps(_invalid), do: []

  defp normalize_limit_hit_at(value) when is_integer(value), do: value
  defp normalize_limit_hit_at(_invalid), do: nil

  defp persisted_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end

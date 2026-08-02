defmodule AmarulaAntiban.Core.JidCircuitBreaker do
  @moduledoc "Pure per-recipient circuit breaker with explicit clock and RNG."

  @eviction_age_ms 600_000

  defmodule Config do
    @moduledoc "Failure threshold, cooldown, and injected RNG."
    defstruct failure_threshold: 3, cooldown_ms: 30_000, rand_fun: &:rand.uniform_real/0

    @type t :: %__MODULE__{
            failure_threshold: pos_integer(),
            cooldown_ms: non_neg_integer(),
            rand_fun: (-> float())
          }
  end

  defmodule Stats do
    @moduledoc "Counts of circuits by state."
    defstruct open: 0, half_open: 0, closed: 0, total: 0
    @type t :: %__MODULE__{}
  end

  @type circuit_state :: :closed | :open | :half_open
  @type entry :: %{
          state: circuit_state(),
          failures: non_neg_integer(),
          opened_at: integer() | nil,
          half_open_probe_used: boolean()
        }
  @type effect ::
          {:circuit_opened | :circuit_half_open | :circuit_closed | :circuit_reopened, map()}
  @type t :: %__MODULE__{config: Config.t(), circuits: %{String.t() => entry()}}
  defstruct config: nil, circuits: %{}

  @doc "Builds a circuit breaker."
  @spec new(keyword() | map()) :: t()
  def new(options \\ []), do: %__MODULE__{config: struct!(Config, Map.new(options))}

  @doc "Checks whether a send may proceed, consuming a half-open probe when granted."
  @spec can_send(t(), String.t(), integer()) :: {boolean(), t(), [effect()]}
  def can_send(breaker, jid, now_ms) do
    {entry, breaker} = get_or_create(breaker, jid, now_ms)

    case entry.state do
      :closed ->
        {true, breaker, []}

      :open ->
        if not is_nil(entry.opened_at) and now_ms - entry.opened_at >= breaker.config.cooldown_ms do
          # The transition itself is the single probe. The upstream implementation
          # forgot to mark it used here, contradicting its own test and contract.
          entry = %{entry | state: :half_open, half_open_probe_used: true}
          breaker = put_entry(breaker, jid, entry)
          {true, breaker, [{:circuit_half_open, %{jid: jid}}]}
        else
          {false, breaker, []}
        end

      :half_open ->
        if entry.half_open_probe_used do
          {false, breaker, []}
        else
          entry = %{entry | half_open_probe_used: true}
          {true, put_entry(breaker, jid, entry), []}
        end
    end
  end

  @doc "Records a successful send and closes a half-open circuit."
  @spec record_success(t(), String.t(), integer()) :: {t(), [effect()]}
  def record_success(breaker, jid, now_ms) do
    {entry, breaker} = get_or_create(breaker, jid, now_ms)

    case entry.state do
      :half_open ->
        closed = %{
          entry
          | state: :closed,
            failures: 0,
            opened_at: nil,
            half_open_probe_used: false
        }

        {put_entry(breaker, jid, closed), [{:circuit_closed, %{jid: jid}}]}

      :closed ->
        {put_entry(breaker, jid, %{entry | failures: 0}), []}

      :open ->
        {breaker, []}
    end
  end

  @doc "Records a failed send and opens or reopens its recipient circuit."
  @spec record_failure(t(), String.t(), integer()) :: {t(), [effect()]}
  def record_failure(breaker, jid, now_ms) do
    {entry, breaker} = get_or_create(breaker, jid, now_ms)

    case entry.state do
      :half_open ->
        open = %{entry | state: :open, opened_at: now_ms, half_open_probe_used: false}
        {put_entry(breaker, jid, open), [{:circuit_reopened, %{jid: jid}}]}

      :closed ->
        entry = %{entry | failures: entry.failures + 1}

        if entry.failures >= breaker.config.failure_threshold do
          open = %{entry | state: :open, opened_at: now_ms}

          {put_entry(breaker, jid, open),
           [
             {:circuit_opened,
              %{jid: jid, failures: open.failures, threshold: breaker.config.failure_threshold}}
           ]}
        else
          {put_entry(breaker, jid, entry), []}
        end

      :open ->
        {breaker, []}
    end
  end

  @doc "Returns a known circuit state without creating an entry."
  @spec state(t(), String.t()) :: circuit_state()
  def state(breaker, jid), do: get_in(breaker.circuits, [jid, :state]) || :closed

  @doc "Returns upstream broadcast jitter (400 through 899 ms)."
  @spec jitter(t(), boolean()) :: non_neg_integer()
  def jitter(_breaker, false), do: 0
  def jitter(breaker, true), do: floor(sample(breaker.config.rand_fun) * 500) + 400

  @doc "Returns counts of tracked circuits by state."
  @spec stats(t()) :: Stats.t()
  def stats(breaker) do
    counts = Enum.frequencies_by(Map.values(breaker.circuits), & &1.state)

    %Stats{
      open: Map.get(counts, :open, 0),
      half_open: Map.get(counts, :half_open, 0),
      closed: Map.get(counts, :closed, 0),
      total: map_size(breaker.circuits)
    }
  end

  @doc "Exports non-trivial circuit states for persistence."
  @spec export(t()) :: [map()]
  def export(breaker) do
    for {jid, entry} <- breaker.circuits,
        entry.state != :closed or entry.failures > 0,
        do: Map.put(entry, :jid, jid)
  end

  @doc "Imports persisted circuit states while retaining configuration."
  @spec import(t(), [map()]) :: t()
  def import(breaker, states) when is_list(states) do
    circuits =
      Enum.reduce(states, breaker.circuits, fn state, circuits ->
        jid = persisted_value!(state, :jid) |> to_string()

        entry = %{
          state: normalize_state(persisted_value!(state, :state)),
          failures: persisted_value!(state, :failures),
          opened_at: persisted_value(state, :opened_at),
          half_open_probe_used: persisted_value(state, :half_open_probe_used, false)
        }

        Map.put(circuits, jid, entry)
      end)

    %{breaker | circuits: circuits}
  end

  @doc "Clears all recipient circuits."
  @spec reset(t()) :: t()
  def reset(breaker), do: %{breaker | circuits: %{}}

  defp get_or_create(breaker, jid, now_ms) do
    case Map.fetch(breaker.circuits, jid) do
      {:ok, entry} ->
        {entry, breaker}

      :error ->
        entry = %{state: :closed, failures: 0, opened_at: nil, half_open_probe_used: false}
        breaker = put_entry(breaker, jid, entry)

        breaker =
          if map_size(breaker.circuits) > 1_000, do: evict_stale(breaker, now_ms), else: breaker

        {entry, breaker}
    end
  end

  defp evict_stale(breaker, now_ms) do
    circuits =
      Map.reject(breaker.circuits, fn {_jid, entry} ->
        age = if entry.opened_at, do: now_ms - entry.opened_at, else: :infinity
        entry.state == :closed and (age == :infinity or age > @eviction_age_ms)
      end)

    %{breaker | circuits: circuits}
  end

  defp put_entry(breaker, jid, entry),
    do: %{breaker | circuits: Map.put(breaker.circuits, jid, entry)}

  defp normalize_state(:closed), do: :closed
  defp normalize_state(:open), do: :open
  defp normalize_state(:half_open), do: :half_open
  defp normalize_state("closed"), do: :closed
  defp normalize_state("open"), do: :open
  defp normalize_state("half_open"), do: :half_open

  defp persisted_value!(map, key) do
    case persisted_value(map, key, :missing) do
      :missing -> raise KeyError, key: key, term: map
      value -> value
    end
  end

  defp persisted_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end

  defp sample(rand_fun), do: rand_fun.() |> max(0.0) |> min(1.0 - 1.0e-12)
end

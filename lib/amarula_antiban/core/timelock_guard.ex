defmodule AmarulaAntiban.Core.TimelockGuard do
  @moduledoc """
  Pure reachout-timelock state and routing decisions.

  Timer work is returned as `{:schedule_resume, generation, delay_ms}` effects.
  A caller must pass the generation back to `resume/3`; stale generations are
  ignored, which preserves the upstream timer-race fix without processes or
  `Process.cancel_timer/1` in the core.
  """

  alias AmarulaAntiban.Jid

  defmodule Config do
    @moduledoc "Safety buffer applied after WhatsApp's reported expiry."

    @type t :: %__MODULE__{resume_buffer_ms: non_neg_integer()}
    defstruct resume_buffer_ms: 10_000
  end

  @type lock_state :: %{
          required(:is_active) => boolean(),
          required(:error_count) => non_neg_integer(),
          optional(:enforcement_type) => String.t() | nil,
          optional(:expires_at) => integer() | nil,
          optional(:detected_at) => integer() | nil
        }
  @type effect ::
          {:timelock_detected, lock_state()}
          | {:timelock_lifted, lock_state()}
          | {:schedule_resume, non_neg_integer(), pos_integer()}
  @type t :: %__MODULE__{
          config: Config.t(),
          is_active: boolean(),
          enforcement_type: String.t() | nil,
          expires_at: integer() | nil,
          detected_at: integer() | nil,
          error_count: non_neg_integer(),
          known_chats: MapSet.t(String.t()),
          timer_generation: non_neg_integer(),
          scheduled_generation: non_neg_integer() | nil
        }

  defstruct config: nil,
            is_active: false,
            enforcement_type: nil,
            expires_at: nil,
            detected_at: nil,
            error_count: 0,
            known_chats: MapSet.new(),
            timer_generation: 0,
            scheduled_generation: nil

  @doc "Builds an inactive timelock guard."
  @spec new(keyword() | map()) :: t()
  def new(options \\ []), do: %__MODULE__{config: struct!(Config, Map.new(options))}

  @doc """
  Applies a timelock update from connection metadata.

  Expected keys are `:is_active`, `:time_enforcement_ends`, and
  `:enforcement_type`; expiry values are Unix milliseconds.
  """
  @spec update(t(), map(), integer()) :: {t(), [effect()]}
  def update(guard, data, now_ms) do
    was_active = guard.is_active

    guard = %{
      guard
      | is_active: !!Map.get(data, :is_active),
        enforcement_type: Map.get(data, :enforcement_type),
        expires_at: Map.get(data, :time_enforcement_ends)
    }

    cond do
      guard.is_active and not was_active ->
        guard = %{guard | detected_at: now_ms, error_count: 0}
        detected = {:timelock_detected, state(guard)}
        {guard, schedule_effects} = schedule_resume(guard, now_ms)
        {guard, [detected | schedule_effects]}

      guard.is_active and was_active ->
        schedule_resume(guard, now_ms)

      not guard.is_active and was_active ->
        {guard, effects} = invalidate_timer(guard)
        {guard, [{:timelock_lifted, state(guard)} | effects]}

      true ->
        {guard, []}
    end
  end

  @doc "Records a 463 error, assuming a 60-second lock if metadata is absent."
  @spec record_463_error(t(), integer()) :: {t(), [effect()]}
  def record_463_error(guard, now_ms) do
    guard = %{guard | error_count: guard.error_count + 1}

    if guard.is_active do
      {guard, []}
    else
      guard = %{
        guard
        | is_active: true,
          detected_at: now_ms,
          expires_at: now_ms + 60_000
      }

      detected = {:timelock_detected, state(guard)}
      {guard, schedule_effects} = schedule_resume(guard, now_ms)
      {guard, [detected | schedule_effects]}
    end
  end

  @doc "Registers one existing chat that remains reachable while locked."
  @spec register_known_chat(t(), String.t()) :: t()
  def register_known_chat(guard, jid) do
    %{guard | known_chats: MapSet.put(guard.known_chats, jid)}
  end

  @doc "Registers multiple existing chats."
  @spec register_known_chats(t(), [String.t()]) :: t()
  def register_known_chats(guard, jids) do
    %{guard | known_chats: Enum.into(jids, guard.known_chats)}
  end

  @doc """
  Decides whether a recipient is reachable under the current lock.

  Groups, newsletters, and known chats always pass. An expired lock is lifted
  first and its effect is returned with the allow decision.
  """
  @spec can_send(t(), String.t(), integer()) ::
          {:allow, t(), [effect()]} | {:deny, String.t(), t()}
  def can_send(guard, jid, now_ms) do
    cond do
      not guard.is_active ->
        {:allow, guard, []}

      expired?(guard, now_ms) ->
        {guard, effects} = lift(guard)
        {:allow, guard, effects}

      Jid.group?(jid) or Jid.newsletter?(jid) or MapSet.member?(guard.known_chats, jid) ->
        {:allow, guard, []}

      true ->
        expires_in = if guard.expires_at, do: max(0, guard.expires_at - now_ms), else: 60_000
        seconds = ceil_div(expires_in, 1_000)

        reason =
          "Reachout timelocked (#{guard.enforcement_type || "unknown"}). " <>
            "New contacts blocked. Expires in #{seconds}s."

        {:deny, reason, guard}
    end
  end

  @doc "Returns whether the guard is active, auto-lifting after buffered expiry."
  @spec timelocked?(t(), integer()) :: {boolean(), t(), [effect()]}
  def timelocked?(%__MODULE__{is_active: false} = guard, _now_ms), do: {false, guard, []}

  def timelocked?(guard, now_ms) do
    if expired?(guard, now_ms) do
      {guard, effects} = lift(guard)
      {false, guard, effects}
    else
      {true, guard, []}
    end
  end

  @doc "Returns the externally meaningful lock-state snapshot."
  @spec state(t()) :: lock_state()
  def state(guard) do
    %{
      is_active: guard.is_active,
      enforcement_type: guard.enforcement_type,
      expires_at: guard.expires_at,
      detected_at: guard.detected_at,
      error_count: guard.error_count
    }
  end

  @doc "Returns the immutable known-chat set."
  @spec known_chats(t()) :: MapSet.t(String.t())
  def known_chats(guard), do: guard.known_chats

  @doc "Manually lifts an active timelock and invalidates its timer generation."
  @spec lift(t()) :: {t(), [effect()]}
  def lift(%__MODULE__{is_active: false} = guard), do: {guard, []}

  def lift(guard) do
    guard = %{guard | is_active: false}
    {guard, invalidation_effects} = invalidate_timer(guard)
    {guard, [{:timelock_lifted, state(guard)} | invalidation_effects]}
  end

  @doc """
  Handles a scheduled resume only if `generation` is still current.

  Passing an old generation is a no-op, even if its former expiry has passed.
  """
  @spec resume(t(), non_neg_integer(), integer()) :: {t(), [effect()]}
  def resume(guard, generation, now_ms) do
    if generation == guard.scheduled_generation and expired?(guard, now_ms) do
      lift(guard)
    else
      {guard, []}
    end
  end

  @doc "Resets lock state, known chats, and timer validity while retaining config."
  @spec reset(t()) :: t()
  def reset(guard) do
    %__MODULE__{config: guard.config, timer_generation: guard.timer_generation + 1}
  end

  defp schedule_resume(guard, now_ms) do
    guard = %{
      guard
      | timer_generation: guard.timer_generation + 1,
        scheduled_generation: nil
    }

    if guard.expires_at do
      delay = guard.expires_at - now_ms + guard.config.resume_buffer_ms

      if delay > 0 do
        guard = %{guard | scheduled_generation: guard.timer_generation}
        {guard, [{:schedule_resume, guard.timer_generation, delay}]}
      else
        {guard, []}
      end
    else
      {guard, []}
    end
  end

  defp invalidate_timer(guard) do
    {%{
       guard
       | timer_generation: guard.timer_generation + 1,
         scheduled_generation: nil
     }, []}
  end

  defp expired?(%__MODULE__{expires_at: nil}, _now_ms), do: false

  defp expired?(guard, now_ms) do
    now_ms >= guard.expires_at + guard.config.resume_buffer_ms
  end

  defp ceil_div(0, _divisor), do: 0
  defp ceil_div(value, divisor), do: div(value + divisor - 1, divisor)
end

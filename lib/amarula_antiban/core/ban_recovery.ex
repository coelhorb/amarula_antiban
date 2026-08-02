defmodule AmarulaAntiban.Core.BanRecovery do
  @moduledoc """
  Pure, structured post-ban recovery: an initial pause followed by a weekly
  ramp back to full rate, with automatic escalation to a permanent "hard ban"
  verdict after repeated bans.

  Upstream (`banRecoveryOrchestrator.ts`) requires an external `tick()` call
  once per week to advance the ramp. This port has no timer at all: `status/2`
  recomputes `rate_multiplier`/`phase` purely from elapsed time, the same way
  `AmarulaAntiban.Core.Health.status/2` and `AmarulaAntiban.Core.WarmUp.status/2`
  already do. Because the weekly ramp is a deterministic geometric
  progression, computing `weeks = div(now_ms - pause_end, week_ms)` and
  applying the compounding formula directly is exactly equivalent to calling
  `tick()` once every week — no behavior is lost, only the scheduling
  requirement. Upstream's `recovering`/`ramping` phases (which differ only in
  whether a tick has fired yet, not in behavior) collapse into one
  `:recovering` phase here.
  """

  @ms_per_day 86_400_000
  @week_ms 7 * @ms_per_day

  defmodule Config do
    @moduledoc "Recovery plans per ban type and escalation thresholds."

    @type plan :: %{
            pause_ms: non_neg_integer(),
            resume_rate: float(),
            weekly_ramp_percent: number(),
            description: String.t()
          }

    @type t :: %__MODULE__{
            plans: %{AmarulaAntiban.Core.BanRecovery.ban_event_type() => plan()},
            max_recovery_weeks: pos_integer(),
            ban_escalation_threshold: pos_integer(),
            ban_window_days: pos_integer()
          }

    defstruct plans: %{
                timelock: %{
                  pause_ms: 86_400_000,
                  resume_rate: 0.10,
                  weekly_ramp_percent: 15,
                  description: "WA reachout timelock — 24h pause then slow ramp"
                },
                rate_overlimit: %{
                  pause_ms: 14_400_000,
                  resume_rate: 0.25,
                  weekly_ramp_percent: 25,
                  description: "Rate limit hit — 4h pause then moderate ramp"
                },
                soft_ban: %{
                  pause_ms: 172_800_000,
                  resume_rate: 0.05,
                  weekly_ramp_percent: 10,
                  description: "Soft ban detected — 48h pause then very slow ramp"
                },
                # pause_ms is unused for :hard_ban — `status/2` short-circuits before
                # ever reading `pause_until` for this event type (see the module doc).
                hard_ban: %{
                  pause_ms: 0,
                  resume_rate: 0.0,
                  weekly_ramp_percent: 0,
                  description: "Hard ban — number is dead, replace SIM"
                }
              },
              max_recovery_weeks: 8,
              ban_escalation_threshold: 3,
              ban_window_days: 30
  end

  defmodule Status do
    @moduledoc "Computed recovery phase, allowed rate, and recommendation."

    @type phase :: :graduated | :paused | :recovering | :dead
    @type t :: %__MODULE__{
            phase: phase(),
            rate_multiplier: float(),
            pause_remaining_ms: non_neg_integer() | nil,
            estimated_full_recovery_at: integer() | nil,
            recommendation: String.t(),
            should_replace_number: boolean()
          }

    defstruct phase: :graduated,
              rate_multiplier: 1.0,
              pause_remaining_ms: nil,
              estimated_full_recovery_at: nil,
              recommendation: "No active recovery — operating normally",
              should_replace_number: false
  end

  @type ban_event_type :: :timelock | :rate_overlimit | :soft_ban | :hard_ban
  @type effect ::
          {:recovery_started, Status.t()}
          | {:recovery_escalated, %{from: ban_event_type(), to: ban_event_type()}}
          | {:hard_ban_detected, Status.t()}
  @type t :: %__MODULE__{
          config: Config.t(),
          event_type: ban_event_type() | nil,
          ban_detected_at: integer() | nil,
          pause_until: integer() | nil,
          ban_count_30d: non_neg_integer(),
          last_ban_at: integer() | nil
        }

  defstruct config: nil,
            event_type: nil,
            ban_detected_at: nil,
            pause_until: nil,
            ban_count_30d: 0,
            last_ban_at: nil

  @doc "Builds a fresh, inactive recovery tracker."
  @spec new(keyword() | map()) :: t()
  def new(options \\ []), do: %__MODULE__{config: struct!(Config, Map.new(options))}

  @doc """
  Records a ban event and starts (or escalates) recovery.

  Escalates to `:hard_ban` when this is the `ban_escalation_threshold`-th ban
  within `ban_window_days`, regardless of the reported `event_type`.
  """
  @spec record_ban_event(t(), ban_event_type(), integer()) :: {t(), [effect()]}
  def record_ban_event(recovery, event_type, now_ms) do
    recovery = maybe_reset_ban_count(recovery, now_ms)
    ban_count = recovery.ban_count_30d + 1
    escalate? = ban_count >= recovery.config.ban_escalation_threshold and event_type != :hard_ban
    final_type = if escalate?, do: :hard_ban, else: event_type
    plan = plan_for(recovery.config, final_type)

    recovery = %{
      recovery
      | event_type: final_type,
        ban_detected_at: now_ms,
        pause_until: now_ms + plan.pause_ms,
        ban_count_30d: ban_count,
        last_ban_at: now_ms
    }

    status = status(recovery, now_ms)
    effects = [{:recovery_started, status}]

    effects =
      if escalate?,
        do: effects ++ [{:recovery_escalated, %{from: event_type, to: :hard_ban}}],
        else: effects

    effects =
      if final_type == :hard_ban, do: effects ++ [{:hard_ban_detected, status}], else: effects

    {recovery, effects}
  end

  @doc "Computes the current phase, allowed rate, and recommendation."
  @spec status(t(), integer()) :: Status.t()
  def status(%__MODULE__{event_type: nil}, _now_ms), do: %Status{}

  def status(%__MODULE__{event_type: :hard_ban}, _now_ms) do
    %Status{
      phase: :dead,
      rate_multiplier: 0.0,
      recommendation: "Account is permanently restricted. Replace number and start fresh.",
      should_replace_number: true
    }
  end

  def status(recovery, now_ms) do
    plan = plan_for(recovery.config, recovery.event_type)

    if now_ms < recovery.pause_until do
      %Status{
        phase: :paused,
        rate_multiplier: plan.resume_rate,
        pause_remaining_ms: recovery.pause_until - now_ms,
        recommendation: "Pause period active. #{plan.description}",
        should_replace_number: replace_number?(recovery)
      }
    else
      weeks = div(now_ms - recovery.pause_until, @week_ms)
      recovering_status(recovery, plan, weeks, now_ms)
    end
  end

  @doc "Current allowed-rate multiplier as a fraction of normal limits (0.0-1.0)."
  @spec rate_multiplier(t(), integer()) :: float()
  def rate_multiplier(recovery, now_ms), do: status(recovery, now_ms).rate_multiplier

  @doc "Classifies an already-normalized WA error code or reason into a ban event type."
  @spec classify_error(term()) :: ban_event_type() | nil
  def classify_error(463), do: :timelock
  def classify_error(429), do: :rate_overlimit
  def classify_error(401), do: :hard_ban
  def classify_error(:logged_out), do: :hard_ban
  def classify_error(_other), do: nil

  @doc """
  Exports recovery state for persistence.

  `event_type` is exported as a string (or `nil`), not an atom: a fresh
  tracker's `event_type` reference is `nil`, and `Snapshot`'s generic
  external-data type check only allows `nil`/integer/binary candidates
  against a `nil` reference — never atoms, to avoid smuggling arbitrary
  atoms in from persisted data.
  """
  @spec export(t()) :: map()
  def export(recovery) do
    %{
      event_type: event_type_string(recovery.event_type),
      ban_detected_at: recovery.ban_detected_at,
      pause_until: recovery.pause_until,
      ban_count_30d: recovery.ban_count_30d,
      last_ban_at: recovery.last_ban_at
    }
  end

  @doc "Restores recovery state while retaining configuration."
  @spec restore(t(), map()) :: t()
  def restore(recovery, data) when is_map(data) do
    %{
      recovery
      | event_type: data |> persisted_value(:event_type) |> string_to_event_type(),
        ban_detected_at: normalize_timestamp(persisted_value(data, :ban_detected_at)),
        pause_until: normalize_timestamp(persisted_value(data, :pause_until)),
        ban_count_30d: normalize_count(persisted_value(data, :ban_count_30d)),
        last_ban_at: normalize_timestamp(persisted_value(data, :last_ban_at))
    }
  end

  defp recovering_status(recovery, plan, weeks, now_ms) do
    if weeks >= recovery.config.max_recovery_weeks do
      %Status{
        phase: :dead,
        rate_multiplier: 0.0,
        recommendation: "Account is permanently restricted. Replace number and start fresh.",
        should_replace_number: true
      }
    else
      multiplier =
        min(1.0, plan.resume_rate * :math.pow(1 + plan.weekly_ramp_percent / 100, weeks))

      if multiplier >= 1.0 do
        %Status{
          phase: :graduated,
          rate_multiplier: 1.0,
          recommendation: "Recovery complete. Operating at full capacity.",
          should_replace_number: false
        }
      else
        %Status{
          phase: :recovering,
          rate_multiplier: multiplier,
          estimated_full_recovery_at: estimated_full_recovery_at(plan, multiplier, now_ms),
          recommendation:
            "Recovery phase. Operating at #{round(multiplier * 100)}% capacity. " <>
              "Ramp: #{plan.weekly_ramp_percent}%/week.",
          should_replace_number: replace_number?(recovery)
        }
      end
    end
  end

  defp estimated_full_recovery_at(%{weekly_ramp_percent: ramp}, multiplier, now_ms)
       when ramp > 0 and multiplier > 0 do
    rate_to_gain = 1.0 - multiplier
    weeks_needed = ceil(rate_to_gain / (ramp / 100) * (1 / multiplier))
    now_ms + weeks_needed * @week_ms
  end

  defp estimated_full_recovery_at(_plan, _multiplier, _now_ms), do: nil

  defp replace_number?(recovery),
    do: recovery.ban_count_30d >= recovery.config.ban_escalation_threshold

  defp maybe_reset_ban_count(%{last_ban_at: nil} = recovery, _now_ms), do: recovery

  defp maybe_reset_ban_count(recovery, now_ms) do
    window_ms = recovery.config.ban_window_days * @ms_per_day

    if now_ms - recovery.last_ban_at > window_ms,
      do: %{recovery | ban_count_30d: 0},
      else: recovery
  end

  defp plan_for(config, event_type), do: Map.fetch!(config.plans, event_type)

  defp event_type_string(nil), do: nil
  defp event_type_string(event_type), do: Atom.to_string(event_type)

  defp string_to_event_type("timelock"), do: :timelock
  defp string_to_event_type("rate_overlimit"), do: :rate_overlimit
  defp string_to_event_type("soft_ban"), do: :soft_ban
  defp string_to_event_type("hard_ban"), do: :hard_ban
  defp string_to_event_type(_other), do: nil

  defp normalize_timestamp(value) when is_integer(value), do: value
  defp normalize_timestamp(_invalid), do: nil

  defp normalize_count(value) when is_integer(value) and value >= 0, do: value
  defp normalize_count(_invalid), do: 0

  defp persisted_value(map, key, default \\ nil) when is_map(map) do
    Map.get(map, key, Map.get(map, Atom.to_string(key), default))
  end
end

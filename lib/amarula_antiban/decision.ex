defmodule AmarulaAntiban.Decision do
  @moduledoc """
  Result of a session send decision.

  Delays and presence steps are data. The caller executes them outside the
  session process, keeping the single state-owning GenServer responsive.
  """

  alias AmarulaAntiban.Core.Health
  alias AmarulaAntiban.Core.Presence

  @type t :: %__MODULE__{
          allowed: boolean(),
          delay_ms: non_neg_integer(),
          reason: atom() | nil,
          detail: String.t() | nil,
          health: Health.Status.t(),
          warmup_day: pos_integer() | nil,
          presence_plan: [Presence.step()],
          typo: AmarulaAntiban.Core.LegitimacySignals.typo() | nil
        }

  @enforce_keys [:allowed, :health]
  defstruct allowed: false,
            delay_ms: 0,
            reason: nil,
            detail: nil,
            health: nil,
            warmup_day: nil,
            presence_plan: [],
            typo: nil
end

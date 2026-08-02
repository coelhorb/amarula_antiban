defmodule AmarulaAntiban.Telemetry do
  @moduledoc """
  Canonical `:telemetry` event catalogue for Amarula Antiban.

  Metadata never contains JIDs, message content, phone numbers, or key
  material. `:profile` is present when the emitting component was configured
  with a session identity. Queue IDs are local opaque correlation IDs; the
  transport `:msg_id` is present only on `queue.sent`, where W4 needs it to
  feed `DeliveryTracker`.

  ## Event contracts

  * `queue.added` — measurements: `count`; metadata: `queue_id`, `priority`,
    optional `profile`.
  * `queue.sent` — measurements: `attempts`; metadata: `queue_id`, `msg_id`,
    optional `profile`. `msg_id` is `nil` for the legacy `:ok` result.
  * `queue.retry` — measurements: `attempts`, `delay_ms`; metadata: `queue_id`,
    `reason`, optional `profile`.
  * `queue.failed` — measurements: `attempts`; metadata: `queue_id`, `reason`,
    optional `profile`.
  * `queue.delayed` — measurements: `count`; metadata: `queue_id`, `reason`,
    optional `profile`.
  * `queue.started`, `queue.stopped` — measurements: `count`; metadata:
    optional `profile`.
  * `queue.cleared` — measurements: `count`; metadata: optional `profile`.
  * `scheduler.status` — measurements: `ms_until_active`, `speed_factor`;
    metadata: `active`, `current_hour`, `day`, `is_weekend`, `active_window`,
    `timezone`, optional `profile`.
  * `delivery_tracker.low_rate` — measurements: `delivery_rate`; metadata:
    optional `profile`.
  * `webhook.sent` — measurements: `status`; metadata: optional `profile`.
  * `webhook.failed` — measurements: optional `status`; metadata: optional
    `profile`.
  * `session.decision` — measurements: `delay_ms`; metadata: `session_id`,
    `outcome`, optional `reason`.
  * `session.risk_changed` — measurements: `score`; metadata: `session_id`, `risk`.
  * `session.timelock_detected`, `session.timelock_lifted` — measurements: `count`;
    metadata: `session_id`.
  * `session.protocol_restart` — measurements: `count`; metadata: `session_id`, `code`.
  * `session.paused`, `session.resumed` — measurements: `count`; metadata:
    `session_id`, and a safe `reason` for pause.
  * `session.persistence_failed`, `session.restore_failed` — measurements: `count`;
    metadata: `session_id`, safe `reason`.
  * `session.low_delivery_rate` — measurements: `delivery_rate`; metadata: `session_id`.
  * `session.effect` — measurements: `count`; metadata: `session_id`, `effect`.
  * `session.recovery_started` — measurements: `count`; metadata: `session_id`.
  * `session.recovery_escalated` — measurements: `count`; metadata: `session_id`.
  * `session.hard_ban_detected` — measurements: `count`; metadata: `session_id`.

  `contracts/0` exposes the same schema as data for consumers and tests.
  """

  @event_contracts [
    %{
      event: [:amarula_antiban, :queue, :added],
      measurements: %{count: "pos_integer()"},
      metadata: %{
        queue_id: "String.t()",
        priority: ":high | :normal | :low",
        profile: "optional term()"
      }
    },
    %{
      event: [:amarula_antiban, :queue, :sent],
      measurements: %{attempts: "pos_integer()"},
      metadata: %{queue_id: "String.t()", msg_id: "String.t() | nil", profile: "optional term()"}
    },
    %{
      event: [:amarula_antiban, :queue, :retry],
      measurements: %{attempts: "pos_integer()", delay_ms: "non_neg_integer()"},
      metadata: %{queue_id: "String.t()", reason: "atom()", profile: "optional term()"}
    },
    %{
      event: [:amarula_antiban, :queue, :failed],
      measurements: %{attempts: "pos_integer()"},
      metadata: %{queue_id: "String.t()", reason: "atom()", profile: "optional term()"}
    },
    %{
      event: [:amarula_antiban, :queue, :delayed],
      measurements: %{count: "pos_integer()"},
      metadata: %{queue_id: "String.t()", reason: ":antiban", profile: "optional term()"}
    },
    %{
      event: [:amarula_antiban, :queue, :started],
      measurements: %{count: "pos_integer()"},
      metadata: %{profile: "optional term()"}
    },
    %{
      event: [:amarula_antiban, :queue, :stopped],
      measurements: %{count: "pos_integer()"},
      metadata: %{profile: "optional term()"}
    },
    %{
      event: [:amarula_antiban, :queue, :cleared],
      measurements: %{count: "non_neg_integer()"},
      metadata: %{profile: "optional term()"}
    },
    %{
      event: [:amarula_antiban, :scheduler, :status],
      measurements: %{ms_until_active: "non_neg_integer()", speed_factor: "number()"},
      metadata: %{
        active: "boolean()",
        current_hour: "0..23",
        day: "1..7",
        is_weekend: "boolean()",
        active_window: "String.t()",
        timezone: "Calendar.time_zone()",
        profile: "optional term()"
      }
    },
    %{
      event: [:amarula_antiban, :delivery_tracker, :low_rate],
      measurements: %{delivery_rate: "float()"},
      metadata: %{profile: "optional term()"}
    },
    %{
      event: [:amarula_antiban, :webhook, :sent],
      measurements: %{status: "200..299"},
      metadata: %{profile: "optional term()"}
    },
    %{
      event: [:amarula_antiban, :webhook, :failed],
      measurements: %{status: "optional non_neg_integer()"},
      metadata: %{profile: "optional term()"}
    },
    %{
      event: [:amarula_antiban, :session, :decision],
      measurements: %{delay_ms: "non_neg_integer()"},
      metadata: %{session_id: "term()", outcome: ":allow | :deny", reason: "atom() | nil"}
    },
    %{
      event: [:amarula_antiban, :session, :risk_changed],
      measurements: %{score: "0..100"},
      metadata: %{session_id: "term()", risk: ":low | :medium | :high | :critical"}
    },
    %{
      event: [:amarula_antiban, :session, :timelock_detected],
      measurements: %{count: "pos_integer()"},
      metadata: %{session_id: "term()"}
    },
    %{
      event: [:amarula_antiban, :session, :timelock_lifted],
      measurements: %{count: "pos_integer()"},
      metadata: %{session_id: "term()"}
    },
    %{
      event: [:amarula_antiban, :session, :protocol_restart],
      measurements: %{count: "pos_integer()"},
      metadata: %{session_id: "term()", code: "515"}
    },
    %{
      event: [:amarula_antiban, :session, :paused],
      measurements: %{count: "pos_integer()"},
      metadata: %{session_id: "term()", reason: "atom() | integer()"}
    },
    %{
      event: [:amarula_antiban, :session, :resumed],
      measurements: %{count: "pos_integer()"},
      metadata: %{session_id: "term()"}
    },
    %{
      event: [:amarula_antiban, :session, :persistence_failed],
      measurements: %{count: "pos_integer()"},
      metadata: %{session_id: "term()", reason: "atom() | integer()"}
    },
    %{
      event: [:amarula_antiban, :session, :restore_failed],
      measurements: %{count: "pos_integer()"},
      metadata: %{session_id: "term()", reason: "atom() | integer()"}
    },
    %{
      event: [:amarula_antiban, :session, :low_delivery_rate],
      measurements: %{delivery_rate: "float()"},
      metadata: %{session_id: "term()"}
    },
    %{
      event: [:amarula_antiban, :session, :effect],
      measurements: %{count: "pos_integer()"},
      metadata: %{session_id: "term()", effect: "atom()"}
    },
    %{
      event: [:amarula_antiban, :session, :recovery_started],
      measurements: %{count: "pos_integer()"},
      metadata: %{session_id: "term()"}
    },
    %{
      event: [:amarula_antiban, :session, :recovery_escalated],
      measurements: %{count: "pos_integer()"},
      metadata: %{session_id: "term()"}
    },
    %{
      event: [:amarula_antiban, :session, :hard_ban_detected],
      measurements: %{count: "pos_integer()"},
      metadata: %{session_id: "term()"}
    }
  ]

  @events Enum.map(@event_contracts, fn contract -> contract.event end)

  @doc "Lists every canonical event this library may emit."
  @spec events() :: [[atom()]]
  def events, do: @events

  @doc "Returns measurements and metadata fields documented for every event."
  @spec contracts() :: [map()]
  def contracts, do: @event_contracts

  @doc "Emits a documented event. Measurements are numeric and metadata follows `contracts/0`."
  @spec emit([atom()], map(), map()) :: :ok
  def emit(event, measurements \\ %{}, metadata \\ %{}),
    do: :telemetry.execute(event, measurements, metadata)
end

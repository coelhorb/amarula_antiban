defmodule AmarulaAntiban.Core.Disconnect do
  @moduledoc "Pure classifier for WhatsApp disconnect status codes."

  defmodule Classification do
    @moduledoc "Typed disconnect category and reconnect recommendation."
    defstruct [
      :category,
      :should_reconnect,
      :backoff_ms,
      :message,
      :code,
      restart_required: false
    ]

    @type t :: %__MODULE__{
            category: :fatal | :recoverable | :rate_limited | :unknown,
            should_reconnect: boolean(),
            backoff_ms: non_neg_integer() | nil,
            message: String.t(),
            code: integer(),
            restart_required: boolean()
          }
  end

  @doc "Classifies a disconnect code using upstream numbers and Amarula's 515 lifecycle."
  @spec classify(integer()) :: Classification.t()
  def classify(code) when code in [401, 440] do
    result(:fatal, false, nil, "Logged out — restart with QR code required", code)
  end

  # Intentional Amarula divergence: 515 is the normal post-pairing restart
  # protocol and Amarula reconnects it immediately. Treating it as fatal would
  # fight the host lifecycle and incorrectly require a new QR code.
  def classify(515) do
    %Classification{
      category: :recoverable,
      should_reconnect: true,
      backoff_ms: 0,
      message: "Restart required by WhatsApp — perform protocol restart immediately",
      code: 515,
      restart_required: true
    }
  end

  def classify(405),
    do: result(:fatal, false, nil, "Method not allowed — server rejected connection method", 405)

  def classify(code) when code in [409, 428] do
    result(:fatal, false, nil, "Connection replaced — another device took over", code)
  end

  def classify(412) do
    result(
      :recoverable,
      true,
      30_000,
      "Precondition failed — auth state mismatch, retry after delay",
      412
    )
  end

  def classify(429) do
    result(
      :rate_limited,
      true,
      300_000,
      "Rate limited by WhatsApp — cool-off period required",
      429
    )
  end

  def classify(503) do
    result(:rate_limited, true, 60_000, "WhatsApp service unavailable — temporary outage", 503)
  end

  def classify(408) do
    result(:recoverable, true, 5_000, "Connection timeout — network issue, safe to retry", 408)
  end

  def classify(500) do
    result(:recoverable, true, 10_000, "WhatsApp internal error — temporary server issue", 500)
  end

  def classify(1000) do
    result(:recoverable, true, 2_000, "Connection closed gracefully — safe to reconnect", 1000)
  end

  def classify(code) do
    result(
      :unknown,
      true,
      15_000,
      "Unknown disconnect reason (code #{code}) — reconnect with caution",
      code
    )
  end

  defp result(category, reconnect, backoff, message, code) do
    %Classification{
      category: category,
      should_reconnect: reconnect,
      backoff_ms: backoff,
      message: message,
      code: code
    }
  end
end

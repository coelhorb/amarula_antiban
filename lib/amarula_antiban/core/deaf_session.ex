defmodule AmarulaAntiban.Core.DeafSession do
  @moduledoc "Pure detector for connected sessions that stop delivering message activity."

  defmodule Config do
    @moduledoc "Silence threshold, minimum uptime, and reconnect recommendation."
    defstruct timeout_ms: 300_000, min_uptime_ms: 120_000, auto_reconnect: true

    @type t :: %__MODULE__{
            timeout_ms: pos_integer(),
            min_uptime_ms: non_neg_integer(),
            auto_reconnect: boolean()
          }
  end

  defmodule Info do
    @moduledoc "Details of a detected deaf session."
    defstruct [:last_message_at, :silence_duration_ms, :connected_since_ms, :auto_reconnect]
    @type t :: %__MODULE__{}
  end

  @type t :: %__MODULE__{
          config: Config.t(),
          last_message_at: integer() | nil,
          connected_at: integer() | nil,
          triggered: boolean()
        }
  defstruct config: nil, last_message_at: nil, connected_at: nil, triggered: false

  @doc "Builds a detector."
  @spec new(keyword() | map()) :: t()
  def new(options \\ []), do: %__MODULE__{config: struct!(Config, Map.new(options))}

  @doc "Starts a fresh connected interval at `now_ms`."
  @spec connect(t(), integer()) :: t()
  def connect(deaf, now_ms),
    do: %{deaf | connected_at: now_ms, last_message_at: now_ms, triggered: false}

  @doc "Ends the current connected interval."
  @spec disconnect(t()) :: t()
  def disconnect(deaf), do: %{deaf | connected_at: nil, triggered: false}

  @doc "Records inbound message activity."
  @spec activity(t(), integer()) :: t()
  def activity(deaf, now_ms), do: %{deaf | last_message_at: now_ms}

  @doc "Checks session silence without timers or sleeps."
  @spec check(t(), integer()) :: {:healthy, t()} | {:deaf, Info.t(), t()}
  def check(%__MODULE__{connected_at: nil} = deaf, _now_ms), do: {:healthy, deaf}
  def check(%__MODULE__{triggered: true} = deaf, _now_ms), do: {:healthy, deaf}

  def check(deaf, now_ms) do
    uptime = now_ms - deaf.connected_at
    silence = now_ms - (deaf.last_message_at || deaf.connected_at)

    if uptime >= deaf.config.min_uptime_ms and silence >= deaf.config.timeout_ms do
      info = %Info{
        last_message_at: deaf.last_message_at,
        silence_duration_ms: silence,
        connected_since_ms: uptime,
        auto_reconnect: deaf.config.auto_reconnect
      }

      {:deaf, info, %{deaf | triggered: true}}
    else
      {:healthy, deaf}
    end
  end

  @doc "Releases detector state while retaining configuration."
  @spec reset(t()) :: t()
  def reset(deaf), do: %{deaf | last_message_at: nil, connected_at: nil, triggered: false}
end

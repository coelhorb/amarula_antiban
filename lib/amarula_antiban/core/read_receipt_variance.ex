defmodule AmarulaAntiban.Core.ReadReceiptVariance do
  @moduledoc "Pure Gaussian read-receipt delay calculations with injected randomness."
  defmodule Config do
    @moduledoc false
    @type t :: %__MODULE__{
            mean_ms: number(),
            std_dev_ms: number(),
            min_ms: number(),
            max_ms: number(),
            skip_if_older_than_ms: non_neg_integer(),
            rand_fun: (-> float())
          }
    defstruct mean_ms: 1_500,
              std_dev_ms: 800,
              min_ms: 200,
              max_ms: 8_000,
              skip_if_older_than_ms: 60_000,
              rand_fun: &:rand.uniform_real/0
  end

  @type t :: %__MODULE__{config: Config.t()}
  defstruct config: nil
  @doc "Builds a receipt delay calculator."
  @spec new(keyword() | map()) :: t()
  def new(options \\ []), do: %__MODULE__{config: struct!(Config, Map.new(options))}
  @doc "Calculates one clamped Gaussian delay in milliseconds."
  @spec delay_ms(t()) :: non_neg_integer()
  def delay_ms(%__MODULE__{config: config}) do
    u = sample(config.rand_fun)
    v = sample(config.rand_fun)
    gaussian = :math.sqrt(-2.0 * :math.log(u)) * :math.cos(2.0 * :math.pi() * v)

    (config.mean_ms + gaussian * config.std_dev_ms)
    |> max(config.min_ms)
    |> min(config.max_ms)
    |> round()
  end

  @doc "Whether every timestamp (Unix seconds) is old enough to skip a delay."
  @spec backlog?([map()], t(), integer()) :: boolean()
  def backlog?([], _variance, _now_ms), do: false

  def backlog?(keys, %__MODULE__{config: config}, now_ms),
    do:
      Enum.all?(keys, fn key ->
        with value when not is_nil(value) <-
               Map.get(key, :message_timestamp, Map.get(key, "messageTimestamp")),
             {seconds, ""} <- Integer.parse(to_string(value)),
             do: now_ms - seconds * 1_000 > config.skip_if_older_than_ms,
             else: (_ -> false)
      end)

  defp sample(rand_fun), do: rand_fun.() |> max(1.0e-12) |> min(1.0 - 1.0e-12)
end

defmodule AmarulaAntiban.Core.ReadReceiptVarianceTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.ReadReceiptVariance

  test "clamps gaussian values to configured bounds" do
    variance =
      ReadReceiptVariance.new(
        mean_ms: 1_000,
        std_dev_ms: 200,
        min_ms: 500,
        max_ms: 1_100,
        rand_fun: fn -> 0.1 end
      )

    assert ReadReceiptVariance.delay_ms(variance) in 500..1_100
  end

  test "normalizes constant RNG boundary values without resampling" do
    for sample <- [0.0, 1.0] do
      variance =
        ReadReceiptVariance.new(
          mean_ms: 1_000,
          std_dev_ms: 200,
          min_ms: 500,
          max_ms: 1_100,
          rand_fun: fn -> sample end
        )

      assert ReadReceiptVariance.delay_ms(variance) in 500..1_100
    end
  end

  test "skips only when every receipt is backlog" do
    variance = ReadReceiptVariance.new(skip_if_older_than_ms: 60_000)
    now = 1_000_000
    assert ReadReceiptVariance.backlog?([%{message_timestamp: 800}], variance, now)

    refute ReadReceiptVariance.backlog?(
             [%{message_timestamp: 800}, %{message_timestamp: 980}],
             variance,
             now
           )
  end
end

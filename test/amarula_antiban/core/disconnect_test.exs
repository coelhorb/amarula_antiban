defmodule AmarulaAntiban.Core.DisconnectTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.Disconnect

  test "classifies upstream fatal, recoverable, rate limited and unknown codes" do
    for code <- [401, 440, 405, 409, 428] do
      result = Disconnect.classify(code)
      assert result.category == :fatal
      refute result.should_reconnect
    end

    assert %{category: :recoverable, backoff_ms: 30_000} = Disconnect.classify(412)
    assert %{category: :rate_limited, backoff_ms: 300_000} = Disconnect.classify(429)
    assert %{category: :rate_limited, backoff_ms: 60_000} = Disconnect.classify(503)
    assert %{category: :recoverable, backoff_ms: 5_000} = Disconnect.classify(408)
    assert %{category: :recoverable, backoff_ms: 10_000} = Disconnect.classify(500)
    assert %{category: :recoverable, backoff_ms: 2_000} = Disconnect.classify(1000)
    assert %{category: :unknown, backoff_ms: 15_000, code: 999} = Disconnect.classify(999)
  end

  test "515 is Amarula protocol restart, not fatal" do
    result = Disconnect.classify(515)
    assert result.category == :recoverable
    assert result.should_reconnect
    assert result.backoff_ms == 0
    assert result.restart_required
    assert result.message =~ "protocol restart"
  end
end

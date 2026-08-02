defmodule AmarulaAntiban.Core.DeafSessionTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.DeafSession

  @now 1_700_000_000_000

  test "requires minimum uptime and silence threshold" do
    deaf = DeafSession.new(timeout_ms: 300, min_uptime_ms: 200) |> DeafSession.connect(@now)
    assert {:healthy, ^deaf} = DeafSession.check(deaf, @now + 199)
    assert {:deaf, info, deaf} = DeafSession.check(deaf, @now + 300)
    assert info.silence_duration_ms == 300
    assert info.connected_since_ms == 300
    assert info.auto_reconnect
    assert {:healthy, ^deaf} = DeafSession.check(deaf, @now + 1_000)
  end

  test "activity and reconnect reset the silence anchor" do
    deaf = DeafSession.new(timeout_ms: 100, min_uptime_ms: 0) |> DeafSession.connect(@now)
    deaf = DeafSession.activity(deaf, @now + 90)
    assert {:healthy, ^deaf} = DeafSession.check(deaf, @now + 100)
    assert {:deaf, %{last_message_at: last}, _deaf} = DeafSession.check(deaf, @now + 190)
    assert last == @now + 90

    disconnected = DeafSession.disconnect(deaf)
    assert {:healthy, ^disconnected} = DeafSession.check(disconnected, @now + 10_000)
    assert DeafSession.reset(disconnected).last_message_at == nil
  end
end

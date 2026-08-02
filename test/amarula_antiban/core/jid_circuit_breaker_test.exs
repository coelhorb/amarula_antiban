defmodule AmarulaAntiban.Core.JidCircuitBreakerTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.JidCircuitBreaker

  @now 1_700_000_000_000
  @jid "contact@s.whatsapp.net"

  test "opens after threshold, grants exactly one half-open probe, then closes" do
    breaker = JidCircuitBreaker.new(failure_threshold: 2, cooldown_ms: 1_000)
    assert {true, breaker, []} = JidCircuitBreaker.can_send(breaker, @jid, @now)
    {breaker, []} = JidCircuitBreaker.record_failure(breaker, @jid, @now)
    {breaker, [{:circuit_opened, _}]} = JidCircuitBreaker.record_failure(breaker, @jid, @now)
    assert JidCircuitBreaker.state(breaker, @jid) == :open
    assert {false, ^breaker, []} = JidCircuitBreaker.can_send(breaker, @jid, @now + 999)

    assert {true, breaker, [{:circuit_half_open, _}]} =
             JidCircuitBreaker.can_send(breaker, @jid, @now + 1_000)

    assert {false, ^breaker, []} = JidCircuitBreaker.can_send(breaker, @jid, @now + 1_001)

    {breaker, [{:circuit_closed, _}]} =
      JidCircuitBreaker.record_success(breaker, @jid, @now + 1_001)

    assert JidCircuitBreaker.state(breaker, @jid) == :closed
  end

  test "failed half-open probe reopens and normal success resets failures" do
    breaker = JidCircuitBreaker.new(failure_threshold: 1, cooldown_ms: 1)
    {breaker, [_]} = JidCircuitBreaker.record_failure(breaker, @jid, @now)
    {true, breaker, [_]} = JidCircuitBreaker.can_send(breaker, @jid, @now + 1)

    {breaker, [{:circuit_reopened, _}]} =
      JidCircuitBreaker.record_failure(breaker, @jid, @now + 1)

    assert JidCircuitBreaker.state(breaker, @jid) == :open

    other = "other@s.whatsapp.net"

    {breaker, []} =
      JidCircuitBreaker.record_failure(
        %{breaker | config: %{breaker.config | failure_threshold: 3}},
        other,
        @now
      )

    {breaker, []} = JidCircuitBreaker.record_success(breaker, other, @now)
    assert breaker.circuits[other].failures == 0
  end

  test "broadcast jitter, stats, persistence and reset" do
    breaker = JidCircuitBreaker.new(rand_fun: fn -> 0.5 end)
    assert JidCircuitBreaker.jitter(breaker, false) == 0
    assert JidCircuitBreaker.jitter(breaker, true) == 650
    {breaker, []} = JidCircuitBreaker.record_failure(breaker, @jid, @now)
    assert %{closed: 1, total: 1} = JidCircuitBreaker.stats(breaker)
    [persisted] = JidCircuitBreaker.export(breaker)
    restored = JidCircuitBreaker.import(JidCircuitBreaker.new(), [persisted])
    assert restored.circuits[@jid].failures == 1
    assert JidCircuitBreaker.reset(restored).circuits == %{}
  end

  test "imports open state after a real JSON round-trip" do
    breaker = JidCircuitBreaker.new(failure_threshold: 1, cooldown_ms: 1_000)
    {breaker, [_opened]} = JidCircuitBreaker.record_failure(breaker, @jid, @now)

    persisted = breaker |> JidCircuitBreaker.export() |> Jason.encode!() |> Jason.decode!()
    restored = JidCircuitBreaker.import(JidCircuitBreaker.new(cooldown_ms: 1_000), persisted)

    assert JidCircuitBreaker.state(restored, @jid) == :open
    assert {false, ^restored, []} = JidCircuitBreaker.can_send(restored, @jid, @now + 999)
  end

  test "jitter clamps injected RNG endpoints to 400 through 899" do
    assert :erlang.fun_info(JidCircuitBreaker.new().config.rand_fun, :name) ==
             {:name, :uniform_real}

    minimum = JidCircuitBreaker.new(rand_fun: fn -> 0.0 end)
    maximum = JidCircuitBreaker.new(rand_fun: fn -> 1.0 end)
    assert JidCircuitBreaker.jitter(minimum, true) == 400
    assert JidCircuitBreaker.jitter(maximum, true) == 899
  end

  test "import accepts atom and JSON enum variants without creating atoms" do
    states = [
      %{jid: "atom-open", state: :open, failures: 1, opened_at: @now},
      %{jid: "atom-half", state: :half_open, failures: 1, opened_at: @now},
      %{"jid" => "json-closed", "state" => "closed", "failures" => 0},
      %{"jid" => "json-half", "state" => "half_open", "failures" => 1}
    ]

    breaker = JidCircuitBreaker.import(JidCircuitBreaker.new(), states)
    assert JidCircuitBreaker.state(breaker, "atom-open") == :open
    assert JidCircuitBreaker.state(breaker, "atom-half") == :half_open
    assert JidCircuitBreaker.state(breaker, "json-closed") == :closed
    assert JidCircuitBreaker.state(breaker, "json-half") == :half_open

    assert_raise KeyError, fn ->
      JidCircuitBreaker.import(JidCircuitBreaker.new(), [%{"state" => "open"}])
    end
  end
end

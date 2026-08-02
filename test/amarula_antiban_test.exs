defmodule AmarulaAntibanTest do
  use ExUnit.Case

  test "starts its supervision tree" do
    assert Process.whereis(AmarulaAntiban.Registry)
    assert Process.whereis(AmarulaAntiban.SessionSupervisor)
  end
end

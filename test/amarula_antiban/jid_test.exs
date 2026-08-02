defmodule AmarulaAntiban.JidTest do
  use ExUnit.Case, async: true

  alias AmarulaAntiban.Jid

  test "detects groups, newsletters, and broadcasts" do
    assert Jid.group?("120363000000000000@g.us")
    refute Jid.group?("27821234567@s.whatsapp.net")
    refute Jid.group?("27821234567@newsletter")

    assert Jid.newsletter?("12345@newsletter")
    refute Jid.newsletter?("27821234567@s.whatsapp.net")

    assert Jid.broadcast?("status@broadcast")
    assert Jid.broadcast?("list@broadcast")
    refute Jid.broadcast?("27821234567@s.whatsapp.net")
  end

  test "group profile includes groups and newsletters" do
    assert Jid.group_profile?("group@g.us")
    assert Jid.group_profile?("channel@newsletter")
    refute Jid.group_profile?("person@s.whatsapp.net")
  end

  test "multiplier floors scaled limits and enforces a minimum of one" do
    assert Jid.apply_group_multiplier(
             %{max_per_minute: 10, max_per_hour: 300, max_per_day: 1_500},
             0.5
           ) == %{max_per_minute: 5, max_per_hour: 150, max_per_day: 750}

    assert Jid.apply_group_multiplier(
             %{max_per_minute: 7, max_per_hour: 100, max_per_day: 300},
             0.7
           ) == %{max_per_minute: 4, max_per_hour: 70, max_per_day: 210}

    assert Jid.apply_group_multiplier(
             %{max_per_minute: 1, max_per_hour: 1, max_per_day: 1},
             0.1
           ) == %{max_per_minute: 1, max_per_hour: 1, max_per_day: 1}
  end
end

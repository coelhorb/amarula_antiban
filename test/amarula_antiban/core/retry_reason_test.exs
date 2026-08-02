defmodule AmarulaAntiban.Core.RetryReasonTest do
  use ExUnit.Case, async: true

  alias AmarulaAntiban.Core.RetryReason

  @reasons %{
    0 => :unknown_error,
    1 => :generic_error,
    3 => :signal_error_invalid_key_id,
    4 => :signal_error_invalid_message,
    5 => :signal_error_no_session,
    7 => :signal_error_bad_mac,
    8 => :message_expired,
    9 => :decryption_error
  }

  test "preserves every upstream numeric enum value" do
    assert RetryReason.all() == @reasons

    for {code, reason} <- @reasons do
      assert RetryReason.parse(code) == reason
      assert RetryReason.parse(Integer.to_string(code)) == reason
      assert RetryReason.code(reason) == code
    end
  end

  test "unknown and malformed inputs become unknown_error" do
    for input <- [nil, 2, 6, 100, -1, "abc", "100", "", %{}] do
      assert RetryReason.parse(input) == :unknown_error
    end

    assert RetryReason.parse(" 7trailing") == :signal_error_bad_mac
    assert RetryReason.parse(7.0) == :signal_error_bad_mac
    assert RetryReason.parse(7.5) == :unknown_error
  end

  test "MAC error set contains exactly the four upstream Signal failures" do
    expected =
      MapSet.new([
        :signal_error_bad_mac,
        :signal_error_invalid_message,
        :signal_error_no_session,
        :signal_error_invalid_key_id
      ])

    assert RetryReason.mac_error_codes() == expected

    for reason <- expected, do: assert(RetryReason.mac_error?(reason))

    for reason <- Map.values(@reasons) -- MapSet.to_list(expected) do
      refute RetryReason.mac_error?(reason)
    end
  end

  test "descriptions retain the exact upstream wording" do
    assert RetryReason.describe(:unknown_error) == "Unknown error"
    assert RetryReason.describe(:generic_error) == "Generic error"

    assert RetryReason.describe(:signal_error_invalid_key_id) ==
             "Invalid key ID — peer prekey rotated"

    assert RetryReason.describe(:signal_error_invalid_message) == "Invalid message format"
    assert RetryReason.describe(:signal_error_no_session) == "No session — peer not initialized"

    assert RetryReason.describe(:signal_error_bad_mac) ==
             "Bad MAC — encryption session mismatch"

    assert RetryReason.describe(:message_expired) == "Message expired — too old to decrypt"
    assert RetryReason.describe(:decryption_error) == "Decryption failed"
    assert RetryReason.describe(999) == "Unknown reason code 999"
  end
end

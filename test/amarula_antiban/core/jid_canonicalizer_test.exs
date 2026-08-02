defmodule AmarulaAntiban.Core.JidCanonicalizerTest do
  use ExUnit.Case, async: true

  alias AmarulaAntiban.Core.JidCanonicalizer

  test "PN, group, broadcast, newsletter, and unknown domains match upstream keys" do
    canonicalizer = JidCanonicalizer.new()

    assert {"thread:27825651069", canonicalizer} =
             JidCanonicalizer.canonical_key(
               canonicalizer,
               "27825651069@s.whatsapp.net"
             )

    assert {"thread:group:1234567890-1234567890", canonicalizer} =
             JidCanonicalizer.canonical_key(canonicalizer, "1234567890-1234567890@g.us")

    assert {"thread:broadcast:status", canonicalizer} =
             JidCanonicalizer.canonical_key(canonicalizer, "status@broadcast")

    assert {"thread:newsletter:abc123", canonicalizer} =
             JidCanonicalizer.canonical_key(canonicalizer, "abc123@newsletter")

    assert {"thread:unknown.domain:user", _canonicalizer} =
             JidCanonicalizer.canonical_key(canonicalizer, "user@unknown.domain")
  end

  test "LID uses only a PN explicitly resolved by Amarula and retains no mapping" do
    canonicalizer = JidCanonicalizer.new()

    assert {"thread:27825651069", canonicalizer} =
             JidCanonicalizer.canonical_key(
               canonicalizer,
               "123456789@lid",
               "27825651069@s.whatsapp.net"
             )

    assert JidCanonicalizer.stats(canonicalizer).canonical_key_hits == 1

    assert {"thread:lid:123456789", canonicalizer} =
             JidCanonicalizer.canonical_key(canonicalizer, "123456789@lid")

    assert JidCanonicalizer.stats(canonicalizer).canonical_key_hits == 1
    assert JidCanonicalizer.stats(canonicalizer).canonical_key_misses == 1
  end

  test "invalid resolved PN cannot create a second identity source" do
    canonicalizer = JidCanonicalizer.new()

    canonicalizer =
      Enum.reduce(["wrong@lid", "digits-only", "@s.whatsapp.net", nil], canonicalizer, fn
        resolved, canonicalizer ->
          assert {"thread:lid:123", canonicalizer} =
                   JidCanonicalizer.canonical_key(canonicalizer, "123@lid", resolved)

          canonicalizer
      end)

    assert JidCanonicalizer.stats(canonicalizer).canonical_key_misses == 4
  end

  test "empty, nil, and malformed values return the invalid key without changing stats" do
    canonicalizer = JidCanonicalizer.new()

    for jid <- ["", "   ", "no-at-sign", nil, 123] do
      assert {"thread:invalid", ^canonicalizer} =
               JidCanonicalizer.canonical_key(canonicalizer, jid)
    end

    assert JidCanonicalizer.stats(canonicalizer).canonical_key_hits == 0
    assert JidCanonicalizer.stats(canonicalizer).canonical_key_misses == 0
  end

  test "normalizes case and whitespace and reset clears counters" do
    canonicalizer = JidCanonicalizer.new()

    assert {"thread:27825651069", canonicalizer} =
             JidCanonicalizer.canonical_key(
               canonicalizer,
               "  27825651069@S.WHATSAPP.NET  "
             )

    assert JidCanonicalizer.stats(canonicalizer).canonical_key_hits == 1
    assert JidCanonicalizer.stats(JidCanonicalizer.reset(canonicalizer)).canonical_key_hits == 0
  end
end

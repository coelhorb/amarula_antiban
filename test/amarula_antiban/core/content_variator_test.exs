defmodule AmarulaAntiban.Core.ContentVariatorTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.ContentVariator

  test "uses custom variator with advancing index" do
    state = ContentVariator.new(custom_variator: fn text, index -> "#{text}-#{index}" end)
    assert {"hello-1", state} = ContentVariator.vary(state, "hello")
    assert {"hello-2", _} = ContentVariator.vary(state, "hello")
  end

  test "injects deterministic zero width characters" do
    Process.put(:variation_random_values, [0.0, 0.5, 0.0, 0.0])

    random = fn ->
      [value | rest] = Process.get(:variation_random_values)
      Process.put(:variation_random_values, rest)
      value
    end

    state = ContentVariator.new(punctuation_variation: false, rand_fun: random)
    assert {value, _} = ContentVariator.vary(state, "one two three")
    assert value != "one two three"
  end

  test "applies synonyms, emoji, and bulk variation" do
    Process.put(:variation_random_values, [0.9, 0.0])

    random = fn ->
      [value | rest] = Process.get(:variation_random_values)
      Process.put(:variation_random_values, rest)
      value
    end

    state =
      ContentVariator.new(
        zero_width_chars: false,
        synonyms: true,
        emoji_padding: true,
        rand_fun: random
      )

    assert {value, _} = ContentVariator.vary(state, "Hello")
    assert value =~ "Hi"
    assert String.ends_with?(value, "👍")

    {bulk, _} =
      ContentVariator.vary_bulk(ContentVariator.new(zero_width_chars: false), "hello", 3)

    assert length(bulk) == 3
  end
end

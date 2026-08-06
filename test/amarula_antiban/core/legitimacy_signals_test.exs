defmodule AmarulaAntiban.Core.LegitimacySignalsTest do
  use ExUnit.Case, async: true
  alias AmarulaAntiban.Core.LegitimacySignals

  test "disabled injector is inert" do
    injector = LegitimacySignals.new()

    assert {:none, ^injector} =
             LegitimacySignals.maybe_inject_typo(injector, "hello there friend")
  end

  test "short text is never touched" do
    injector =
      LegitimacySignals.new(enabled: true, typo_probability: 1.0, rand_fun: fn -> 0.0 end)

    assert {:none, ^injector} = LegitimacySignals.maybe_inject_typo(injector, "hi there")
  end

  test "probability roll above threshold skips injection" do
    injector =
      LegitimacySignals.new(enabled: true, typo_probability: 0.025, rand_fun: fn -> 0.5 end)

    assert {:none, ^injector} =
             LegitimacySignals.maybe_inject_typo(injector, "hello there my good friend")
  end

  test "text containing a URL is never touched" do
    injector =
      LegitimacySignals.new(enabled: true, typo_probability: 1.0, rand_fun: fn -> 0.0 end)

    assert {:none, ^injector} =
             LegitimacySignals.maybe_inject_typo(injector, "check this out https://example.com")

    assert {:none, ^injector} =
             LegitimacySignals.maybe_inject_typo(injector, "check this out www.example.com now")
  end

  test "injects a keyboard-adjacent typo and builds a correction" do
    injector =
      LegitimacySignals.new(enabled: true, typo_probability: 1.0, rand_fun: fn -> 0.0 end)

    assert {:typo, %{typo_text: typo_text, correction_delay_ms: 500, correction_text: correction},
            new_injector} = LegitimacySignals.maybe_inject_typo(injector, "hello there friend")

    assert typo_text != "hello there friend"
    assert correction == "hello there friend"
    assert new_injector.stats.typos_injected == 1
    assert new_injector.stats.corrections_generated == 1
  end

  test "typo replaces the first char of the first eligible word with a qwerty neighbor" do
    injector =
      LegitimacySignals.new(enabled: true, typo_probability: 1.0, rand_fun: fn -> 0.0 end)

    assert {:typo, %{typo_text: typo_text}, _injector} =
             LegitimacySignals.maybe_inject_typo(injector, "quick fox jumps")

    assert typo_text == "wuick fox jumps"
  end

  test "preserves case of the replaced character" do
    injector =
      LegitimacySignals.new(enabled: true, typo_probability: 1.0, rand_fun: fn -> 0.0 end)

    assert {:typo, %{typo_text: typo_text}, _injector} =
             LegitimacySignals.maybe_inject_typo(injector, "Quick fox jumps")

    assert typo_text == "Wuick fox jumps"
  end

  test "correction is the whole message under 30 bytes, else *word above" do
    short_injector =
      LegitimacySignals.new(enabled: true, typo_probability: 1.0, rand_fun: fn -> 0.0 end)

    assert {:typo, %{correction_text: "quick fox jumps"}, _} =
             LegitimacySignals.maybe_inject_typo(short_injector, "quick fox jumps")

    long_text = "quick fox jumps over the lazy dog today"
    assert byte_size(long_text) >= 30

    assert {:typo, %{correction_text: "*quick"}, _} =
             LegitimacySignals.maybe_inject_typo(short_injector, long_text)
  end

  test "correction_delay_ms is uniform within configured bounds" do
    injector =
      LegitimacySignals.new(
        enabled: true,
        typo_probability: 1.0,
        typo_correct_min_ms: 500,
        typo_correct_max_ms: 2000,
        rand_fun: fn -> 0.999_999 end
      )

    assert {:typo, %{correction_delay_ms: delay}, _injector} =
             LegitimacySignals.maybe_inject_typo(injector, "quick fox jumps")

    assert delay == 2000
  end

  test "ineligible words (short, @mention, digits-only) are skipped when picking a word" do
    injector =
      LegitimacySignals.new(enabled: true, typo_probability: 1.0, rand_fun: fn -> 0.0 end)

    assert {:typo, %{typo_text: typo_text}, _injector} =
             LegitimacySignals.maybe_inject_typo(injector, "@bob hi 123 quick")

    assert typo_text == "@bob hi 123 wuick"
  end

  test "no eligible word yields :none" do
    injector =
      LegitimacySignals.new(enabled: true, typo_probability: 1.0, rand_fun: fn -> 0.0 end)

    assert {:none, ^injector} = LegitimacySignals.maybe_inject_typo(injector, "@bob 123 45 @carl")
  end

  test "only the first occurrence of the sampled word is replaced" do
    injector =
      LegitimacySignals.new(enabled: true, typo_probability: 1.0, rand_fun: fn -> 0.0 end)

    assert {:typo, %{typo_text: typo_text}, _injector} =
             LegitimacySignals.maybe_inject_typo(injector, "quick quick fox")

    assert typo_text == "wuick quick fox"
  end
end

defmodule AmarulaAntiban.Core.LegitimacySignals do
  @moduledoc """
  Pure, RNG-injected typo-injection humanizer for outbound text.

  Ports only `shouldInjectTypo` from upstream's `legitimacySignalInjector.ts`.
  The sibling `shouldInjectReadGap`/`getTypingPauses` functions are dead code
  even in the JS source (never called from `wrapper.ts`), so they are not
  ported here — see `docs/PARITY.md`.
  """

  defmodule Config do
    @moduledoc "Typo-injection thresholds and injected random source."

    @type t :: %__MODULE__{
            enabled: boolean(),
            typo_probability: float(),
            typo_correct_min_ms: non_neg_integer(),
            typo_correct_max_ms: non_neg_integer(),
            rand_fun: (-> float())
          }

    defstruct enabled: false,
              typo_probability: 0.025,
              typo_correct_min_ms: 500,
              typo_correct_max_ms: 2000,
              rand_fun: &:rand.uniform_real/0
  end

  defmodule Stats do
    @moduledoc "Typo-injection counters."

    @type t :: %__MODULE__{
            typos_injected: non_neg_integer(),
            corrections_generated: non_neg_integer()
          }

    defstruct typos_injected: 0, corrections_generated: 0
  end

  @type typo :: %{
          typo_text: String.t(),
          correction_delay_ms: pos_integer(),
          correction_text: String.t()
        }
  @type t :: %__MODULE__{config: Config.t(), stats: Stats.t()}
  defstruct config: nil, stats: nil

  @qwerty_adjacent %{
    "q" => ["w", "a"],
    "w" => ["q", "e", "a", "s"],
    "e" => ["w", "r", "s", "d"],
    "r" => ["e", "t", "d", "f"],
    "t" => ["r", "y", "f", "g"],
    "y" => ["t", "u", "g", "h"],
    "u" => ["y", "i", "h", "j"],
    "i" => ["u", "o", "j", "k"],
    "o" => ["i", "p", "k", "l"],
    "p" => ["o", "l"],
    "a" => ["q", "w", "s", "z"],
    "s" => ["a", "w", "e", "d", "z", "x"],
    "d" => ["s", "e", "r", "f", "x", "c"],
    "f" => ["d", "r", "t", "g", "c", "v"],
    "g" => ["f", "t", "y", "h", "v", "b"],
    "h" => ["g", "y", "u", "j", "b", "n"],
    "j" => ["h", "u", "i", "k", "n", "m"],
    "k" => ["j", "i", "o", "l", "m"],
    "l" => ["k", "o", "p"],
    "z" => ["a", "s", "x"],
    "x" => ["z", "s", "d", "c"],
    "c" => ["x", "d", "f", "v"],
    "v" => ["c", "f", "g", "b"],
    "b" => ["v", "g", "h", "n"],
    "n" => ["b", "h", "j", "m"],
    "m" => ["n", "j", "k"]
  }

  @doc "Builds an injector; its random source is supplied explicitly in options."
  @spec new(keyword() | map()) :: t()
  def new(options \\ []),
    do: %__MODULE__{config: struct!(Config, Map.new(options)), stats: %Stats{}}

  @doc "Returns typo-injection counters."
  @spec stats(t()) :: Stats.t()
  def stats(injector), do: injector.stats

  @doc """
  Rolls whether to inject one keyboard-adjacent typo into `text`.

  Returns `{:none, injector}` when disabled, the text is too short, the
  probability roll misses, the text contains a URL, or no eligible word yields
  an adjacent-key substitution. Otherwise returns `{:typo, result, injector}`
  with the typo'd text and a correction to send after `correction_delay_ms`.
  """
  @spec maybe_inject_typo(t(), String.t()) :: {:none, t()} | {:typo, typo(), t()}
  def maybe_inject_typo(%__MODULE__{config: %{enabled: false}} = injector, _text),
    do: {:none, injector}

  def maybe_inject_typo(injector, text) when byte_size(text) <= 10, do: {:none, injector}

  def maybe_inject_typo(injector, text) do
    cond do
      sample(injector.config.rand_fun) >= injector.config.typo_probability ->
        {:none, injector}

      contains_url?(text) ->
        {:none, injector}

      true ->
        inject(injector, text)
    end
  end

  defp contains_url?(text), do: Regex.match?(~r/https?:\/\/|www\./i, text)

  defp inject(injector, text) do
    case eligible_words(text) do
      [] ->
        {:none, injector}

      words ->
        word = Enum.at(words, floor(sample(injector.config.rand_fun) * length(words)))

        case typo_word(word, injector.config.rand_fun) do
          nil -> {:none, injector}
          typo_word -> build_result(injector, text, word, typo_word)
        end
    end
  end

  defp eligible_words(text) do
    text
    |> String.split(" ")
    |> Enum.filter(&eligible_word?/1)
  end

  defp eligible_word?(word) do
    byte_size(word) >= 3 and not String.starts_with?(word, "@") and not digits_only?(word)
  end

  defp digits_only?(word), do: Regex.match?(~r/^\d+$/, word)

  defp typo_word(word, rand_fun) do
    chars = String.graphemes(word)
    index = floor(sample(rand_fun) * length(chars))
    char = Enum.at(chars, index)

    case Map.get(@qwerty_adjacent, String.downcase(char)) do
      nil -> nil
      neighbors -> replace_char(chars, index, char, neighbors, rand_fun)
    end
  end

  defp replace_char(chars, index, char, neighbors, rand_fun) do
    replacement = Enum.at(neighbors, floor(sample(rand_fun) * length(neighbors)))

    replacement =
      if char == String.upcase(char), do: String.upcase(replacement), else: replacement

    chars |> List.replace_at(index, replacement) |> Enum.join()
  end

  defp build_result(injector, text, word, typo_word) do
    typo_text = String.replace(text, word, typo_word, global: false)
    correction_delay_ms = correction_delay(injector.config, injector.config.rand_fun)
    correction_text = if byte_size(text) < 30, do: text, else: "*#{word}"

    stats = %{
      injector.stats
      | typos_injected: injector.stats.typos_injected + 1,
        corrections_generated: injector.stats.corrections_generated + 1
    }

    result = %{
      typo_text: typo_text,
      correction_delay_ms: correction_delay_ms,
      correction_text: correction_text
    }

    {:typo, result, %{injector | stats: stats}}
  end

  defp correction_delay(config, rand_fun) do
    span = config.typo_correct_max_ms - config.typo_correct_min_ms
    config.typo_correct_min_ms + floor(sample(rand_fun) * (span + 1))
  end

  defp sample(rand_fun), do: rand_fun.() |> max(0.0) |> min(1.0 - 1.0e-12)
end

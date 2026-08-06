defmodule AmarulaAntiban.Core.ContentVariator do
  @moduledoc "Pure, RNG-injected content variation for avoiding identical sends."

  defmodule Config do
    @moduledoc false
    @type t :: %__MODULE__{
            enabled: boolean(),
            zero_width_chars: boolean(),
            punctuation_variation: boolean(),
            emoji_padding: boolean(),
            synonyms: boolean(),
            custom_variator: (String.t(), pos_integer() -> String.t()) | nil,
            rand_fun: (-> float())
          }
    defstruct enabled: false,
              zero_width_chars: true,
              punctuation_variation: true,
              emoji_padding: false,
              synonyms: false,
              custom_variator: nil,
              rand_fun: &:rand.uniform_real/0
  end

  @type t :: %__MODULE__{config: Config.t(), counter: non_neg_integer()}
  defstruct config: nil, counter: 0

  @zero_width ["\u200B", "\u200C", "\u200D", "\uFEFF"]
  @emojis ["", " 👍", " ✅", " 📌", " 💬", " 📢"]
  @synonyms %{
    "hello" => ["hi", "hey", "howdy"],
    "hi" => ["hello", "hey", "howdy"],
    "thanks" => ["thank you", "thx", "cheers"],
    "please" => ["kindly", "pls"],
    "great" => ["awesome", "excellent", "wonderful"],
    "good" => ["great", "nice", "fine"],
    "buy" => ["purchase", "get", "grab"],
    "sell" => ["offer", "list"],
    "price" => ["cost", "amount", "value"],
    "available" => ["in stock", "on offer"],
    "check" => ["look at", "see", "view"],
    "join" => ["participate", "enter", "come to"],
    "start" => ["begin", "kick off", "commence"],
    "end" => ["finish", "close", "conclude"],
    "bid" => ["offer", "place a bid"],
    "win" => ["secure", "take home"],
    "item" => ["lot", "piece", "product"]
  }

  @doc "Builds a variator; its random source is supplied explicitly in options."
  @spec new(keyword() | map()) :: t()
  def new(options \\ []), do: %__MODULE__{config: struct!(Config, Map.new(options))}

  @doc "Returns the number of variations produced so far."
  @spec stats(t()) :: %{variations_applied: non_neg_integer()}
  def stats(variator), do: %{variations_applied: variator.counter}

  @doc "Returns one varied string and the advanced counter state."
  @spec vary(t(), String.t()) :: {String.t(), t()}
  def vary(%__MODULE__{config: %{enabled: false}} = variator, text), do: {text, variator}

  def vary(variator, text) do
    variator = %{variator | counter: variator.counter + 1}
    config = variator.config

    result =
      if config.custom_variator do
        config.custom_variator.(text, variator.counter)
      else
        text
        |> maybe_synonyms(config)
        |> maybe_zero_width(config)
        |> punctuation(config, variator.counter)
        |> emoji(config, variator.counter)
      end

    {result, variator}
  end

  @doc "Returns `count` variations, retrying up to ten times per duplicate."
  @spec vary_bulk(t(), String.t(), non_neg_integer()) :: {[String.t()], t()}
  def vary_bulk(variator, text, count) do
    if count == 0, do: {[], variator}, else: vary_bulk_nonzero(variator, text, count)
  end

  defp vary_bulk_nonzero(variator, text, count) do
    Enum.reduce(1..count, {[], MapSet.new(), variator}, fn _, {results, seen, state} ->
      {value, state} = unique(state, text, seen, 0)
      {[value | results], MapSet.put(seen, value), state}
    end)
    |> then(fn {results, _seen, state} -> {Enum.reverse(results), state} end)
  end

  defp unique(state, text, seen, attempts) do
    {value, state} = vary(state, text)

    if MapSet.member?(seen, value) and attempts < 10,
      do: unique(state, text, seen, attempts + 1),
      else: {value, state}
  end

  defp maybe_synonyms(text, %Config{synonyms: false}), do: text

  defp maybe_synonyms(text, config) do
    Regex.split(~r/(\b)/, text, include_captures: true)
    |> Enum.reduce({[], false}, fn word, {parts, replaced} ->
      {replacement, replaced} = synonym_for(word, replaced, config)
      {[replacement | parts], replaced}
    end)
    |> then(fn {parts, _} -> parts |> Enum.reverse() |> IO.iodata_to_binary() end)
  end

  defp maybe_zero_width(text, %Config{zero_width_chars: false}), do: text

  defp maybe_zero_width(text, config) do
    words = String.split(text, " ")

    if length(words) < 2,
      do: text,
      else: add_zero_width(words, config)
  end

  defp positions(max, count, rand_fun), do: positions(max, count, rand_fun, [])
  defp positions(_max, 0, _rand_fun, result), do: result

  defp positions(max, count, rand_fun, result) do
    position = min(max - 1, floor(sample(rand_fun) * max))

    if position in result,
      do:
        positions(max, count - 1, rand_fun, [
          Enum.find(0..(max - 1), &(&1 not in result)) | result
        ]),
      else: positions(max, count - 1, rand_fun, [position | result])
  end

  defp synonym_for(word, true, _config), do: {word, true}

  defp synonym_for(word, false, config) do
    case Map.get(@synonyms, String.downcase(word)) do
      nil -> {word, false}
      choices -> choose_synonym(word, choices, config)
    end
  end

  defp choose_synonym(word, choices, config) do
    if sample(config.rand_fun) <= 0.5 do
      {word, false}
    else
      replacement = Enum.at(choices, floor(sample(config.rand_fun) * length(choices)))
      {preserve_case(word, replacement), true}
    end
  end

  defp preserve_case(word, replacement) do
    if word == String.capitalize(word), do: String.capitalize(replacement), else: replacement
  end

  defp add_zero_width(words, config) do
    positions = positions(length(words) - 1, min(2, length(words) - 1), config.rand_fun)

    words
    |> Enum.with_index()
    |> Enum.map_join(" ", &zero_width_word(&1, words, positions, config))
  end

  defp zero_width_word({word, index}, words, positions, config) do
    if index < length(words) - 1 and index in positions do
      word <> Enum.at(@zero_width, floor(sample(config.rand_fun) * length(@zero_width)))
    else
      word
    end
  end

  defp punctuation(text, %Config{punctuation_variation: false}, _counter), do: text

  defp punctuation(text, _config, counter) do
    if text == "", do: text, else: punctuation_nonempty(text, counter)
  end

  defp punctuation_nonempty(text, counter) do
    case rem(counter, 5) do
      0 ->
        text <> " "

      1 ->
        text <> "  "

      2 ->
        if String.ends_with?(text, "."), do: String.trim_trailing(text, "."), else: text <> "."

      3 ->
        text

      4 ->
        if String.first(text) == String.first(text) |> String.upcase(),
          do: String.downcase(String.first(text)) <> String.slice(text, 1..-1//1),
          else: text
    end
  end

  defp emoji(text, %Config{emoji_padding: false}, _counter), do: text
  defp emoji(text, _config, counter), do: text <> Enum.at(@emojis, rem(counter, length(@emojis)))

  defp sample(rand_fun), do: rand_fun.() |> max(0.0) |> min(1.0 - 1.0e-12)
end

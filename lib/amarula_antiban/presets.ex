defmodule AmarulaAntiban.Presets do
  @moduledoc """
  Built-in anti-ban configurations ported from baileys-antiban.

  The four presets retain the upstream limits exactly. Resolving the
  `:high_volume` preset emits `[:amarula_antiban, :preset, :warning]` so the
  host application can surface the same warning as the TypeScript package.
  """

  @type preset_name :: :conservative | :moderate | :aggressive | :high_volume

  defmodule Config do
    @moduledoc "Configuration shared by the anti-ban core modules."

    @type rand_fun :: (-> float())
    @type t :: %__MODULE__{
            max_per_minute: pos_integer(),
            max_per_hour: pos_integer(),
            max_per_day: pos_integer(),
            min_delay_ms: non_neg_integer(),
            max_delay_ms: non_neg_integer(),
            new_chat_delay_ms: non_neg_integer(),
            max_identical_messages: pos_integer(),
            identical_message_window_ms: pos_integer(),
            burst_allowance: non_neg_integer(),
            warmup_days: pos_integer(),
            day1_limit: pos_integer(),
            growth_factor: number(),
            inactivity_threshold_hours: pos_integer(),
            auto_pause_at: :low | :medium | :high | :critical,
            group_multiplier: number(),
            group_profiles: boolean(),
            persist: String.t() | nil,
            logging: boolean(),
            instance_coordinator: String.t() | nil,
            instance_pool_max_per_minute: pos_integer() | nil,
            instance_pool_max_per_hour: pos_integer() | nil,
            on_at_risk: function() | nil,
            on_risk_change: function() | nil,
            on_timelock_detected: function() | nil,
            on_timelock_lifted: function() | nil,
            rand_fun: rand_fun()
          }

    defstruct max_per_minute: 5,
              max_per_hour: 100,
              max_per_day: 800,
              min_delay_ms: 2_500,
              max_delay_ms: 7_000,
              new_chat_delay_ms: 4_000,
              max_identical_messages: 3,
              identical_message_window_ms: 3_600_000,
              burst_allowance: 3,
              warmup_days: 10,
              day1_limit: 15,
              growth_factor: 1.8,
              inactivity_threshold_hours: 72,
              auto_pause_at: :medium,
              group_multiplier: 0.5,
              group_profiles: true,
              persist: nil,
              logging: true,
              instance_coordinator: nil,
              instance_pool_max_per_minute: nil,
              instance_pool_max_per_hour: nil,
              on_at_risk: nil,
              on_risk_change: nil,
              on_timelock_detected: nil,
              on_timelock_lifted: nil,
              rand_fun: &:rand.uniform_real/0
  end

  defp presets do
    %{
      conservative: struct!(Config, %{}),
      moderate:
        struct!(Config, %{
          max_per_minute: 10,
          max_per_hour: 300,
          max_per_day: 1_500,
          min_delay_ms: 1_500,
          max_delay_ms: 5_000,
          new_chat_delay_ms: 3_000,
          max_identical_messages: 5,
          burst_allowance: 5,
          warmup_days: 7,
          day1_limit: 20,
          auto_pause_at: :high,
          group_multiplier: 0.7
        }),
      aggressive:
        struct!(Config, %{
          max_per_minute: 20,
          max_per_hour: 800,
          max_per_day: 4_000,
          min_delay_ms: 800,
          max_delay_ms: 3_000,
          new_chat_delay_ms: 2_000,
          max_identical_messages: 10,
          burst_allowance: 8,
          warmup_days: 4,
          day1_limit: 35,
          growth_factor: 2.0,
          inactivity_threshold_hours: 48,
          auto_pause_at: :high,
          group_multiplier: 0.9
        }),
      high_volume:
        struct!(Config, %{
          max_per_minute: 40,
          max_per_hour: 1_500,
          max_per_day: 8_000,
          min_delay_ms: 400,
          max_delay_ms: 1_800,
          new_chat_delay_ms: 1_200,
          max_identical_messages: 20,
          burst_allowance: 15,
          warmup_days: 3,
          day1_limit: 60,
          growth_factor: 2.5,
          inactivity_threshold_hours: 24,
          auto_pause_at: :high,
          group_multiplier: 0.95
        })
    }
  end

  @doc "Returns all built-in presets keyed by name."
  @spec all() :: %{preset_name() => Config.t()}
  def all, do: presets()

  @doc "Returns a single built-in preset, raising for an unknown name."
  @spec fetch!(preset_name()) :: Config.t()
  def fetch!(name) when is_atom(name) do
    case Map.fetch(presets(), name) do
      {:ok, config} -> config
      :error -> raise ArgumentError, unknown_preset_message(name)
    end
  end

  @doc """
  Resolves a preset name and optional overrides into a `Config` struct.

  Accepted inputs are a preset atom, a keyword list, a map, or a
  `{preset, overrides}` tuple. `nil` selects `:conservative`.
  """
  @spec resolve(
          nil
          | preset_name()
          | keyword()
          | map()
          | {preset_name(), keyword() | map()}
        ) :: Config.t()
  def resolve(input \\ nil)

  def resolve(nil), do: fetch!(:conservative)

  def resolve(name) when is_atom(name) do
    config = fetch!(name)
    maybe_warn(name)
    config
  end

  def resolve({name, overrides}) when is_atom(name) do
    resolve_overrides(name, overrides)
  end

  def resolve(overrides) when is_list(overrides) or is_map(overrides) do
    overrides = Map.new(overrides)
    {name, overrides} = Map.pop(overrides, :preset, :conservative)
    resolve_overrides(name, overrides)
  end

  defp resolve_overrides(name, overrides) when is_atom(name) do
    config = fetch!(name)
    maybe_warn(name)
    struct!(config, Map.new(overrides))
  end

  defp maybe_warn(:high_volume) do
    :telemetry.execute(
      [:amarula_antiban, :preset, :warning],
      %{},
      %{preset: :high_volume, account_age_requirement_days: 180}
    )
  end

  defp maybe_warn(_name), do: :ok

  defp unknown_preset_message(name) do
    "unknown preset #{inspect(name)}; valid presets: " <>
      "conservative, moderate, aggressive, high_volume"
  end
end

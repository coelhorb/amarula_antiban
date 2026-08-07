defmodule AmarulaAntiban.DeviceProfiles do
  @moduledoc """
  Curated, internally-consistent device-fingerprint profiles for the
  `Amarula.new/1` config map — nothing to do with antiban's own decision
  chain, this is a config-building helper the host applies *before*
  `Amarula.new/1` ever runs.

  Amarula's `:browser`/`:os_version`/`:os_build_number`/`:device_name`
  fields (see `Amarula.Config`) let every session look different, but
  `Amarula.new/1`'s own default leaves every connection sharing the exact
  same values unless the host overrides them by hand — and every session
  sharing an identical fingerprint is itself a signal.

      config
      |> AmarulaAntiban.DeviceProfiles.merge(:windows_chrome)
      |> Amarula.new()
      |> AmarulaAntiban.attach(preset: :conservative)
      |> Amarula.connect()

  Deliberately does **not** touch `:mcc`/`:mnc`: those describe the SIM/carrier
  the account is actually registered under, which this library cannot know or
  guess correctly — a wrong carrier code is arguably a *stronger* signal than
  Amarula's generic `"000"`/`"000"` default. Pass them yourself, alongside a
  profile, if you know the account's real values.
  """

  @type profile_name :: :macos_chrome | :windows_chrome | :windows_edge | :ubuntu_chrome

  defp profiles do
    %{
      macos_chrome: %{
        browser: ["Mac OS", "Chrome", "14.4.1"],
        os_version: "14.5",
        os_build_number: "23F79",
        device_name: "Desktop"
      },
      windows_chrome: %{
        browser: ["Windows", "Chrome", "126.0.0.0"],
        os_version: "10",
        os_build_number: "19045",
        device_name: "Desktop"
      },
      windows_edge: %{
        browser: ["Windows", "Edge", "126.0.0.0"],
        os_version: "10",
        os_build_number: "19045",
        device_name: "Desktop"
      },
      ubuntu_chrome: %{
        browser: ["Ubuntu", "Chrome", "126.0.0.0"],
        os_version: "22.04",
        os_build_number: "22.04.4",
        device_name: "Desktop"
      }
    }
  end

  @doc "Returns all built-in profiles keyed by name."
  @spec all() :: %{profile_name() => map()}
  def all, do: profiles()

  @doc "Returns a single built-in profile, raising for an unknown name."
  @spec fetch!(profile_name()) :: map()
  def fetch!(name) when is_atom(name) do
    case Map.fetch(profiles(), name) do
      {:ok, profile} -> profile
      :error -> raise ArgumentError, unknown_profile_message(name)
    end
  end

  @doc """
  Merges the named profile into `config` (the map you're about to pass to
  `Amarula.new/1`) — any key `config` already sets wins over the profile's
  value, same override order as `AmarulaAntiban.Presets.resolve/1`.
  """
  @spec merge(map(), profile_name()) :: map()
  def merge(config, name) when is_map(config), do: Map.merge(fetch!(name), config)

  @doc """
  Picks a built-in profile name at random, via the injected `:rand_fun`
  (defaults to `:rand.uniform_real/0`) — for a host that wants a different
  profile per session without hand-picking one.
  """
  @spec random(keyword()) :: profile_name()
  def random(opts \\ []) do
    rand_fun = Keyword.get(opts, :rand_fun, &:rand.uniform_real/0)
    names = profiles() |> Map.keys() |> Enum.sort()
    sample = rand_fun.() |> max(0.0) |> min(1.0 - 1.0e-12)
    Enum.at(names, floor(sample * length(names)))
  end

  defp unknown_profile_message(name) do
    known = profiles() |> Map.keys() |> Enum.sort() |> Enum.map_join(", ", &to_string/1)
    "unknown device profile #{inspect(name)}; valid profiles: #{known}"
  end
end

defmodule AmarulaAntiban.DeviceProfilesTest do
  use ExUnit.Case, async: true

  alias AmarulaAntiban.DeviceProfiles

  test "all exposes exactly four named profiles" do
    assert DeviceProfiles.all() |> Map.keys() |> Enum.sort() ==
             [:macos_chrome, :ubuntu_chrome, :windows_chrome, :windows_edge]
  end

  test "every profile sets browser/os_version/os_build_number/device_name and never mcc/mnc" do
    for {_name, profile} <- DeviceProfiles.all() do
      assert %{browser: [_os, _client, _version]} = profile
      assert is_binary(profile.os_version)
      assert is_binary(profile.os_build_number)
      assert is_binary(profile.device_name)
      refute Map.has_key?(profile, :mcc)
      refute Map.has_key?(profile, :mnc)
    end
  end

  test "fetch! returns a known profile and raises for an unknown one" do
    assert %{browser: ["Windows", "Chrome", _version]} = DeviceProfiles.fetch!(:windows_chrome)

    assert_raise ArgumentError, ~r/unknown device profile/, fn ->
      DeviceProfiles.fetch!(:turbo)
    end
  end

  test "merge/2 layers the profile under the caller's config, config wins on conflict" do
    config = %{profile: :me, storage: :ignored, device_name: "My Custom Device"}
    merged = DeviceProfiles.merge(config, :ubuntu_chrome)

    assert merged.profile == :me
    assert merged.storage == :ignored
    # explicit config wins over the profile's device_name
    assert merged.device_name == "My Custom Device"
    # fields the caller didn't set come from the profile
    assert merged.browser == ["Ubuntu", "Chrome", "126.0.0.0"]
    assert merged.os_version == "22.04"
  end

  test "merge/2 raises for an unknown profile" do
    assert_raise ArgumentError, ~r/unknown device profile/, fn ->
      DeviceProfiles.merge(%{}, :turbo)
    end
  end

  test "random/1 picks a valid, deterministic profile name from the injected rand_fun" do
    names = DeviceProfiles.all() |> Map.keys() |> Enum.sort()

    assert DeviceProfiles.random(rand_fun: fn -> 0.0 end) == List.first(names)
    assert DeviceProfiles.random(rand_fun: fn -> 0.999_999 end) == List.last(names)
  end
end

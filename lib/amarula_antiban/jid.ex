defmodule AmarulaAntiban.Jid do
  @moduledoc "JID profile detection and group/newsletter rate-limit scaling."

  @type limits :: %{
          required(:max_per_minute) => pos_integer(),
          required(:max_per_hour) => pos_integer(),
          required(:max_per_day) => pos_integer()
        }

  @doc "Returns whether the JID is a WhatsApp group."
  @spec group?(String.t()) :: boolean()
  def group?(jid) when is_binary(jid), do: String.ends_with?(jid, "@g.us")

  @doc "Returns whether the JID is a newsletter/channel."
  @spec newsletter?(String.t()) :: boolean()
  def newsletter?(jid) when is_binary(jid), do: String.ends_with?(jid, "@newsletter")

  @doc "Returns whether the JID is a status or broadcast list."
  @spec broadcast?(String.t()) :: boolean()
  def broadcast?(jid) when is_binary(jid) do
    jid == "status@broadcast" or String.ends_with?(jid, "@broadcast")
  end

  @doc "Returns whether the stricter group profile applies to the JID."
  @spec group_profile?(String.t()) :: boolean()
  def group_profile?(jid), do: group?(jid) or newsletter?(jid)

  @doc "Scales all three limits, flooring each result with a minimum of one."
  @spec apply_group_multiplier(limits(), number()) :: limits()
  def apply_group_multiplier(limits, multiplier) when is_number(multiplier) do
    %{
      max_per_minute: scale(limits.max_per_minute, multiplier),
      max_per_hour: scale(limits.max_per_hour, multiplier),
      max_per_day: scale(limits.max_per_day, multiplier)
    }
  end

  defp scale(limit, multiplier), do: max(1, floor(limit * multiplier))
end

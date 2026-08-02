defmodule AmarulaAntiban.Core.RetryReason do
  @moduledoc """
  Pure representation of WhatsApp message retry reason codes.

  The numeric values and MAC-error classification mirror
  `retryReason.ts` from baileys-antiban. Amarula owns retry transport and
  re-encryption; this module only classifies codes exposed by callers.
  """

  @type t ::
          :unknown_error
          | :generic_error
          | :signal_error_invalid_key_id
          | :signal_error_invalid_message
          | :signal_error_no_session
          | :signal_error_bad_mac
          | :message_expired
          | :decryption_error

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

  @codes Map.new(@reasons, fn {code, reason} -> {reason, code} end)

  @mac_errors MapSet.new([
                :signal_error_bad_mac,
                :signal_error_invalid_message,
                :signal_error_no_session,
                :signal_error_invalid_key_id
              ])

  @descriptions %{
    unknown_error: "Unknown error",
    generic_error: "Generic error",
    signal_error_invalid_key_id: "Invalid key ID — peer prekey rotated",
    signal_error_invalid_message: "Invalid message format",
    signal_error_no_session: "No session — peer not initialized",
    signal_error_bad_mac: "Bad MAC — encryption session mismatch",
    message_expired: "Message expired — too old to decrypt",
    decryption_error: "Decryption failed"
  }

  @doc "Parses an integer or decimal string, returning `:unknown_error` when unrecognized."
  @spec parse(term()) :: t()
  def parse(code) when is_integer(code), do: Map.get(@reasons, code, :unknown_error)

  def parse(code) when is_float(code) and trunc(code) == code,
    do: parse(trunc(code))

  def parse(code) when is_binary(code) do
    case code |> String.trim_leading() |> Integer.parse() do
      {number, _remainder} -> parse(number)
      :error -> :unknown_error
    end
  end

  def parse(_code), do: :unknown_error

  @doc "Returns whether a parsed reason denotes a Signal MAC/session mismatch."
  @spec mac_error?(term()) :: boolean()
  def mac_error?(reason), do: MapSet.member?(@mac_errors, reason)

  @doc "Returns the exact upstream human-readable description for a reason."
  @spec describe(t() | term()) :: String.t()
  def describe(reason) when is_map_key(@descriptions, reason),
    do: Map.fetch!(@descriptions, reason)

  def describe(reason) do
    case Map.fetch(@codes, reason) do
      {:ok, code} -> "Unknown reason code #{code}"
      :error -> "Unknown reason code #{inspect(reason)}"
    end
  end

  @doc "Returns the WhatsApp numeric code for a known reason."
  @spec code(t()) :: non_neg_integer()
  def code(reason), do: Map.fetch!(@codes, reason)

  @doc "Returns the immutable set of reasons classified as MAC errors."
  @spec mac_error_codes() :: MapSet.t(t())
  def mac_error_codes, do: @mac_errors

  @doc "Returns every recognized numeric code and its typed reason."
  @spec all() :: %{non_neg_integer() => t()}
  def all, do: @reasons
end

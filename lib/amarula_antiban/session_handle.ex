defmodule AmarulaAntiban.SessionHandle do
  @moduledoc "A stable logical session reference used by long-lived integrations."

  @enforce_keys [:session_id, :options]
  defstruct [:session_id, :options]

  @type t :: %__MODULE__{session_id: term(), options: keyword()}
end

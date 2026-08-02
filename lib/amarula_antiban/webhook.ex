# credo:disable-for-this-file Credo.Check.Refactor.Nesting
defmodule AmarulaAntiban.Webhook do
  @moduledoc "A telemetry handler that asynchronously POSTs selected events through optional Req."
  @doc "Attaches a webhook handler. Returns `{:error, :req_unavailable}` when Req is not installed."
  @spec attach(String.t(), [atom()] | [[atom()]], keyword()) :: :ok | {:error, :req_unavailable}
  def attach(url, events, options \\ []) do
    if Code.ensure_loaded?(Req) do
      handler_id = Keyword.get(options, :handler_id, {__MODULE__, url})

      events =
        if is_list(events) and events != [] and is_atom(hd(events)), do: [events], else: events

      :telemetry.attach_many(handler_id, events, &__MODULE__.handle_event/4, %{
        url: url,
        headers: Keyword.get(options, :headers, []),
        cooldown_ms: Keyword.get(options, :cooldown_ms, 300_000),
        last_alert: :atomics.new(1, signed: false),
        now_fun: Keyword.get(options, :now_fun, fn -> System.system_time(:millisecond) end),
        post_fun: Keyword.get(options, :post_fun, &request/3),
        task_supervisor:
          Keyword.get(
            options,
            :task_supervisor,
            AmarulaAntiban.Webhook.TaskSupervisor
          )
      })
    else
      {:error, :req_unavailable}
    end
  end

  @doc "Detaches a previously attached webhook handler."
  @spec detach(term()) :: :ok
  def detach(handler_id), do: :telemetry.detach(handler_id)
  @doc false
  def handle_event([:amarula_antiban, :webhook, _action], _measurements, _metadata, _config),
    do: :ok

  # credo:disable-for-next-line Credo.Check.Refactor.Nesting
  def handle_event(event, measurements, metadata, %{url: url, headers: headers} = config) do
    cooldown = Map.get(config, :cooldown_ms, 0)
    last_alert = Map.get_lazy(config, :last_alert, fn -> :atomics.new(1, signed: false) end)
    now = Map.get(config, :now_fun, fn -> System.system_time(:millisecond) end).()
    post_fun = Map.get(config, :post_fun, &request/3)

    task_supervisor =
      Map.get(config, :task_supervisor, AmarulaAntiban.Webhook.TaskSupervisor)

    if reserve?(last_alert, now, cooldown) do
      Task.Supervisor.start_child(task_supervisor, fn ->
        result_metadata = Map.take(metadata, [:profile])

        body = %{
          source: "amarula_antiban",
          event: event,
          measurements: measurements,
          metadata: metadata,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        case post_fun.(url, headers, body) do
          {:ok, %{status: status}} when status in 200..299 ->
            AmarulaAntiban.Telemetry.emit(
              [:amarula_antiban, :webhook, :sent],
              %{status: status},
              result_metadata
            )

          {:ok, %{status: status}} ->
            AmarulaAntiban.Telemetry.emit(
              [:amarula_antiban, :webhook, :failed],
              %{status: status},
              result_metadata
            )

          {:error, _reason} ->
            AmarulaAntiban.Telemetry.emit(
              [:amarula_antiban, :webhook, :failed],
              %{},
              result_metadata
            )
        end
      end)
    else
      :ok
    end

    :ok
  end

  defp reserve?(atomics, now, cooldown) do
    previous = :atomics.get(atomics, 1)

    if now - previous < cooldown do
      false
    else
      case :atomics.compare_exchange(atomics, 1, previous, now) do
        :ok -> true
        _current -> reserve?(atomics, now, cooldown)
      end
    end
  end

  defp request(url, headers, body) do
    # Req is optional at compile time, so a direct call would emit a false warning.
    # credo:disable-for-next-line Credo.Check.Refactor.Apply
    apply(Req, :post, [url, [json: body, headers: headers]])
  end
end

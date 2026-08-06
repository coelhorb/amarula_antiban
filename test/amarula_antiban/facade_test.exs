defmodule AmarulaAntiban.FacadeTest do
  use ExUnit.Case, async: false

  alias AmarulaAntiban.Session

  test "facade delegates session lifecycle, queue options, and public Amarula events" do
    id = {:facade, System.unique_integer([:positive])}

    assert {:ok, session} =
             AmarulaAntiban.start_session(id,
               now_fun: fn -> 1_000 end,
               rand_fun: fn -> 0.5 end,
               auto_pause_at: :critical,
               min_delay_ms: 0,
               max_delay_ms: 0,
               new_chat_delay_ms: 0,
               presence: [typing_min_ms: 0]
             )

    assert AmarulaAntiban.whereis(id) == session
    owner = AmarulaAntiban.queue_options(session, profile: id)[:owner]
    assert is_pid(owner)
    refute owner == session

    assert :ok = Session.after_send(session, "1@s.whatsapp.net", "one", "wamid.facade")

    assert :ok =
             AmarulaAntiban.handle_event(session, {
               :amarula,
               :receipt_update,
               %{message_ids: ["wamid.facade"], status: :delivered}
             })

    assert :ok =
             AmarulaAntiban.handle_event(session, {
               :amarula,
               :error,
               {:stream_error, 500, "temporary"}
             })

    assert :ok =
             AmarulaAntiban.handle_event(session, {
               :amarula,
               :connection_update,
               %{connection: :connected}
             })

    assert :ok = AmarulaAntiban.handle_event(session, {:amarula, :unknown, %{}})

    assert {:allow, :ok} =
             AmarulaAntiban.check_group_operation(session, :add, "120000@g.us")

    assert :ok = AmarulaAntiban.register_message_type(session, "reply", priority: :normal)

    assert {:ok, prepared} =
             AmarulaAntiban.prepare_typed_send(
               session,
               "1@s.whatsapp.net",
               %{text: "hi"},
               "reply"
             )

    assert :ok = AmarulaAntiban.record_typed_send(session, prepared, "wamid.typed")

    assert :ok = AmarulaAntiban.stop_session(id)
  end
end

# Amarula Antiban

> Work in progress — the public API is not stable yet, and none of this has
> been validated against a live WhatsApp connection (every test runs against
> Amarula's offline sandbox). See [docs/PARITY.md](docs/PARITY.md) for exactly
> what's ported, what's intentionally out of scope, and known gaps.

An OTP-native port of [baileys-antiban](https://github.com/kobie3717/baileys-antiban)
for [Amarula](https://github.com/tubedude/amarula) WhatsApp clients: rate
limiting, warm-up ramps, presence/typing simulation, ban-risk scoring and
recovery, and related anti-detection guards, running as a real decision chain
inside a per-session `GenServer` rather than a request middleware.

## Quick start

```elixir
{:ok, pid} =
  Amarula.new(%{profile: :my_bot, storage: {Amarula.Storage.File, root: "./data"}})
  |> AmarulaAntiban.attach(preset: :conservative)
  |> Amarula.connect()
```

`attach/2` appends antiban's send/receive steps to Amarula's plugin pipeline
and starts (or finds) a session `GenServer` keyed by `:my_bot` (defaults to
the connection's `:profile`; pass `session_id:` to use a different key). From
here, every `Amarula.send_text/3` (and friends) already goes through the
decision chain — rate limits, warm-up, ban recovery, timelock, presence
simulation, and (if configured) typo injection and content variation — with
no other code changes required.

## Presets

`preset:` picks a built-in `AmarulaAntiban.Presets.Config` baseline —
`:conservative` (default), `:moderate`, `:aggressive`, or `:high_volume` (the
last one warns via telemetry: it assumes an aged, warmed-up account). Any
field can be overridden alongside the preset:

```elixir
AmarulaAntiban.attach(conn, preset: :moderate, max_per_hour: 150)
```

## Configuration

Every guard beyond the always-on core (rate limiter, warm-up, health,
timelock, ban recovery) is **opt-in** — `enabled: false` by default — and
configured under its own nested key. A few of the more commonly used ones:

```elixir
AmarulaAntiban.attach(conn,
  preset: :conservative,
  reply_ratio: [enabled: true, min_ratio: 0.10],
  contact_graph: [enabled: true],
  topology_throttler: [enabled: true],
  presence: [enabled: true, enable_typing_model: true],
  legitimacy_signals: [enabled: true, typo_probability: 0.025],
  content_variator: [enabled: true],
  group_operation_guard: [enabled: true],
  human_entropy: [enabled: true]
)
```

See each module's `@moduledoc`/`Config` struct under `lib/amarula_antiban/core/`
for the full field list, and [docs/PARITY.md](docs/PARITY.md) for what each
one preserves or changes from upstream. `sleep_fun:`/`rand_fun:`/`now_fun:`
are injectable everywhere (used throughout this project's own test suite) if
you need deterministic behavior for your own tests.

## Beyond `attach/2`: standalone APIs

A few guards don't fit the `on_send` pipeline (group operations don't flow
through `on_send` at all; a message `type` is a per-message opt-in, not
every send has one) and are called explicitly instead:

```elixir
# Group operations — group_operation_guard: [enabled: true] above
case AmarulaAntiban.check_group_operation(session, :add, group_jid) do
  {:allow, :ok} -> Amarula.Group.participants(conn, group_jid, participants, :add)
  {:deny, decision} -> {:error, decision.detail}
end

# Typed sends — priority pools, provenance/legitimacy requirements
:ok = AmarulaAntiban.register_message_type(session, "otp", priority: :critical)

case AmarulaAntiban.prepare_typed_send(session, jid, content, "otp") do
  {:ok, prepared} ->
    {:ok, msg_id} = Amarula.send_text(conn, jid, content)
    AmarulaAntiban.record_typed_send(session, prepared, msg_id)

  {:error, reason} ->
    {:error, reason}
end
```

`session` above is whatever `AmarulaAntiban.whereis/1` (or the session
handle `attach/2`'s caller can obtain via `AmarulaAntiban.session_handle/2`)
resolves to for your profile.

## Persistence and delivery correlation

Pass `persist: "path/to/state.json"` (or a `state_store:` — see
`AmarulaAntiban.StateStore`) to survive restarts; snapshots are versioned and
JSON-safe. For exact delivery-success correlation (rather than the
conservative "authorized == sent" default), route sends through
`AmarulaAntiban.Queue` using `AmarulaAntiban.queue_options/2`, which wires a
stable event-bridge owner that survives session restarts.

## Credentials backup

`AmarulaAntiban.Storage.Backup` wraps any other `Amarula.Storage` adapter and
keeps the last N copies of `:creds` on disk before each overwrite — pure
operational robustness, unrelated to anti-ban risk:

```elixir
storage = {AmarulaAntiban.Storage.Backup,
            adapter: {Amarula.Storage.File, root: "./data"},
            backup_dir: "./data/creds_backups",
            retention: 5}

Amarula.new(%{storage: storage, profile: :my_bot})
```

## License

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE).

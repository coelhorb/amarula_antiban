# Upstream parity

This document records intentional differences from baileys-antiban v4.10.0.

## W3 — LID, JID, retry reasons, and message types

| Upstream module | Elixir surface | Status | Notes |
|---|---|---|---|
| `lidResolver.ts` | Amarula LID/PN APIs | Delegated to Amarula | Bidirectional mapping, persistence, lookup, session migration, and crypto addressing are owned by `Amarula.Protocol.Signal.LidMappingFileStore` and exposed through `Amarula.Contacts`. No second resolver/cache is kept by this library. |
| `lidFirstResolver.ts` | Amarula LID/PN APIs | Delegated to Amarula | Importing Baileys `lid-mapping-*_reverse.json` auth files does not apply to Amarula storage. Amarula's mapping store and contacts lookup own this function. |
| `jidCanonicalizer.ts` | `AmarulaAntiban.Core.JidCanonicalizer` | Partial by design (D14) | Ports stable `canonical_key/3` behavior and hit/miss statistics only. For an `@lid`, the PN is supplied by the caller after an Amarula lookup and is never retained locally. Outbound target rewriting and event-based identity learning remain delegated to Amarula. |
| `retryReason.ts` | `AmarulaAntiban.Core.RetryReason` | Full | Preserves codes `0, 1, 3, 4, 5, 7, 8, 9`, the four-code MAC set, parsing, and descriptions. Amarula still owns retry transport/re-encryption. |
| `messageTypeRegistry.ts` | `AmarulaAntiban.Core.MessageTypeRegistry` | Full, OTP-native | Preserves registration locking, provenance and legitimacy validation, priority pool limits, pending tracking, engagement scoring, warnings, cleanup, and export/import. The TypeScript `send()` I/O is split into pure `prepare_send/5` and `record_sent/4`; Amarula performs transport between them. Clock and RNG are injected. |

`MessageTypeRegistry` intentionally fixes two unsafe upstream accounting
behaviors: pending messages retain their recipient so `record_blocked/3` affects
only that JID, and duplicate delivered/read receipts are idempotent. These
fields survive JSON export/import. Snapshots created before the fields existed
remain importable with `jid: nil` and both receipt flags unset; such legacy
entries are never assigned to an arbitrary blocked JID.

### LID test extraction

The applicable `jidCanonicalizer.test.ts` canonical-key cases were ported: PN,
known/unknown LID, group, broadcast, newsletter, malformed input,
normalization, unknown domains, and counters. A known LID receives the PN as an
explicit result from Amarula rather than learning it into local state.

The following upstream test groups are intentionally not copied because D14
delegates their behavior to Amarula:

- `lidResolver.test.ts`: mapping learning, reverse lookup, LRU eviction,
  persistence, canonical send-target selection, reset, and resolver stats.
- `lidFirstResolver.test.ts`: Baileys auth-directory JSON import, reverse
  lookup, normalization inside that cache, event ingestion, and its factory.
- `jidCanonicalizer.test.ts`: event learning, outbound target rewriting,
  shared/owned resolver lifecycle, message updates, and group-metadata learning.

This delegation avoids two mutable sources of truth for LID↔PN identity.

## W4 — Topology throttling and ban recovery

| Upstream module | Elixir surface | Status | Notes |
|---|---|---|---|
| `topologyThrottler.ts` | `AmarulaAntiban.Core.TopologyThrottler` | Partial by design | Ports the graph-expansion gate (hourly/daily new-contact caps, cooldown, 7-day reply-ratio requirement) and the `assessContact` risk formula exactly (same weights and thresholds). `maxContactsFromSameSource`/`sourceGroup` hotspot detection is not ported — it depends on group-membership metadata Amarula does not yet expose to the plugin. `assess/4` always treats `knownGroups` as empty, matching upstream's own default when the caller passes no context (conservative — never under-estimates risk). |
| `banRecoveryOrchestrator.ts` | `AmarulaAntiban.Core.BanRecovery` | Full logic, different mechanism | Preserves all four recovery plans (timelock/rate_overlimit/soft_ban/hard_ban), the 3-bans-in-30-days escalation to hard ban, and the weekly compounding ramp exactly. Upstream's external `tick()` (must be called once a week to advance the ramp) is replaced by a pure recompute of `rate_multiplier`/`phase` from elapsed time in `status/2`, the same pattern already used by `Core.Health.status/2` and `Core.WarmUp.status/2`. This is mathematically equivalent to calling `tick()` weekly, so no behavior is lost. Upstream's `recovering`/`ramping` phases (which differ only in whether a tick has fired yet) collapse into a single `:recovering` phase here, since they never differed in behavior. `pause_until` never persists as `:infinity` — `status/2` short-circuits for `:hard_ban` before ever reading it, so the field always stays a plain integer or `nil`, avoiding an incompatibility with `Snapshot`'s generic external-data type validation. |

`Session` wires the two modules into the `beforeSend` decision chain at upstream's
positions: `decide_topology` runs between the contact-graph and reply-ratio
guards; the `BanRecovery` pause/rate gate runs first, right after the
health-paused check and before `TimelockGuard`. `BanRecovery.record_ban_event/3`
is auto-triggered from a critical `Health` risk change (`:soft_ban`) and from a
401 disconnect (`:hard_ban`); a single 463 stays `TimelockGuard`'s own timed
block and does **not** by itself start a `BanRecovery` pause — layering a
24-hour full-session pause on every routine reachout timelock would fight
`TimelockGuard`'s existing, independently-tested resume mechanism. Hosts that
detect `:timelock` or `:rate_overlimit` ban signals through their own channels
(no WA disconnect code maps to HTTP 429 in this port) call
`Session.record_ban_event/2` explicitly.

## W5 — Typo injection (legitimacy signals)

| Upstream module | Elixir surface | Status | Notes |
|---|---|---|---|
| `legitimacySignalInjector.ts` | `AmarulaAntiban.Core.LegitimacySignals` | Partial by design | Only `shouldInjectTypo` is ported. `shouldInjectReadGap`/`getTypingPauses` are dead code even in the upstream source (never called from `wrapper.ts`), so they are not ported — see `docs/PARITY.md` note below rather than a code gap. |

`maybe_inject_typo/2` is pure and RNG-injected (same pattern as `ContentVariator`/
`ReplyRatio`): it rolls the same probability/eligibility/keyboard-adjacency logic
as upstream and returns `{:typo, %{typo_text:, correction_delay_ms:,
correction_text:}, injector}` or `{:none, injector}`. `Session.decide_rate`'s
`:allow` branch calls it alongside the existing presence-plan construction and
carries the result on `Decision.typo` — the decision stays pure and
content-agnostic; only `Plugin` knows the outbound message's real shape.

`Plugin.send_step` applies `decision.typo` by mirroring `message_content/1`'s own
field lookup (`conversation` / `extendedTextMessage.text` / `imageMessage.caption`
/ `videoMessage.caption`) to rewrite the same field with the typo'd text before
`{:cont, ctx}`, so Amarula sends the version with the mistake. The message is
mutated **only** when a real text-bearing field was found — if `content` came
from the non-text marker fallback in `message_content/1`, the typo roll is
discarded (`Session` still spent the RNG roll on it, matching upstream's
content-agnostic probability check, but nothing is sent that could leak an
internal type marker as message text).

The correction is a **second, real send** — `Amarula.send_text/3`, scheduled on
`AmarulaAntiban.Session.TaskSupervisor` after `correction_delay_ms` (using the
same injected `sleep_fun` as presence steps), matching upstream's
`sendMessage` → wait → `sendMessage` correction flow exactly. Unlike presence
effects (`send_chatstate`/`set_presence`, which Amarula never routes through a
plugin pipeline), `send_text` **does** re-enter Amarula's `send_steps` — so the
correction is genuinely gated by the same antiban decision chain as any other
outbound message (rate limits, warm-up, contact graph, and so on), including a
vanishingly small chance of drawing its own typo roll. This is intentional, not
an oversight: Amarula v0.5.6 exposes no way to send a message that bypasses a
connection's own plugin pipeline, and a correction that skipped every guard
could be sent even while the session is paused or banned. The alternative —
silently forcing the correction out unconditionally — risks exactly the kind of
blind, un-throttled write this whole library exists to prevent.

## W6 — Group operation guard

| Upstream module | Elixir surface | Status | Notes |
|---|---|---|---|
| `groupOperationGuard.ts` | `AmarulaAntiban.Core.GroupOperationGuard` | Full logic, new public API | Ports the fixed-window (not sliding) rate limiter per `{operation, key}` exactly: first call in a window always allows and starts the window at count 1, subsequent calls increment until `limit.max`, then every call is denied until `reset_at` elapses. `extractPrivacyBlock` (parsing a raw WA binary node to pull an invite code out of a privacy block) is not ported — it is wire-protocol detail that is Amarula's responsibility, not the antiban's. |

Group operations (`Amarula.Group.participants/4`, `Amarula.Group.create/3`,
`Amarula.Group.invite_code/2`, ...) never flow through `Amarula.Plugin`'s
`on_send`/`on_recv` — that pipeline only wraps message sends. `check/4` is
therefore a standalone pure function, not a step in `Session.decide/4`, wired
the same way `record_463_error/1`/`record_ban_event/2` already are:
`Session.check_group_operation/3` calls the core guard directly and persists
the result, and `AmarulaAntiban.check_group_operation/3` delegates to it
through `with_session/2`. Hosts call it explicitly before a group operation:

```elixir
case AmarulaAntiban.check_group_operation(session, :add, group_jid) do
  {:allow, :ok} -> Amarula.Group.participants(conn, group_jid, participants, :add)
  {:deny, decision} -> {:error, decision.detail}
end
```

Two corrections against the original port plan, found by reading Amarula's
actual `Group`/`Storage` source rather than assuming the JS shape carried
over: there is no `Amarula.Group.add_participants/3` — add/remove/promote/demote
all go through the single `Amarula.Group.participants/4` with an `action`
argument, shown above. And `classify_error/1` does not need upstream's
regex/substring matching over a free-text error message at all: every
`Amarula.Group.*` failure is already the structured tuple
`{:error, {:group_op_failed, code, text}}`, so `classify_error/1` pattern
matches on `text` directly. The four `text` values it recognizes
(`"rate-overlimit"`, `"locked"`, `"forbidden"`, `"item-not-found"`) are
confirmed literal tokens in `Amarula.Protocol.Binary.Constants`'s WhatsApp
binary-protocol dictionary; the mapping from each token to a ban-adjacent
meaning (`:rate_overlimit`/`:group_locked`/`:reachout_restricted`/
`:invite_expired`) follows public WhatsApp/XMPP stanza-error conventions but
has not been independently confirmed against a live server for group
operations specifically — refine it if real error payloads turn out to
disagree.

`windows` (a map keyed by dynamic `"op:key"` strings) gets its own
`export/1`/`restore/2` on the core module, following the same pattern as
`ContactGraph`/`TopologyThrottler`, and is wired into `State`/`Snapshot` like
every other core module. `reset/3` (clearing one window for immediate reuse)
and `stats/1` are pure core API; only `check/4` is wired through `Session` —
`reset/3` was left off `Session`/the facade because nothing in this pass
calls for it yet, and it is trivial to wire later if a host needs it.

## W7 — Human entropy (background typing/presence cycles)

| Upstream module | Elixir surface | Status | Notes |
|---|---|---|---|
| `humanEntropy.ts` | `AmarulaAntiban.Core.HumanEntropy` + `AmarulaAntiban.HumanEntropyWorker` | Scope reduced by design | Only `performTypingPresence` and `performPresenceToggle` are ported — the two actions whose Amarula calls (`send_chatstate/3`, `set_presence/2`) were already confirmed elsewhere in this port. `performReadReceipt` is **not** ported: it needs a real message ID, and `Plugin.receive_step`/`Session.record_incoming/2,3` currently discard the plugin ctx's `id` entirely. Porting it is a separate follow-up (tracked as a future "W7b"), not a gap in this pass. |

This is the first background process in the port: every other core module
so far is decided synchronously inside `Session.decide/4` or one of its
sibling `handle_call`s. `humanEntropy.ts` runs on its own recursive
`setTimeout` (re-arming itself each time, not `setInterval`), independent of
the send flow — porting it faithfully meant introducing an actual OTP
process, not just another pure module.

**Architecture**, following the `EventBridge`/`EventBridgeSupervisor` pattern
already established for the same reason (a stable per-session process that
needs to survive `Session` restarts and reach a real Amarula connection):

- `Core.HumanEntropy` is pure and RNG-injected — `track_incoming/3` (dedup by
  JID, keep the `max_recent_contacts` most recent), `next_delay_ms/1`
  (uniform delay for the next cycle), `roll_cycle/1` (independently rolls
  `:typing` and `:presence_toggle` — both, either, or neither may fire in one
  cycle, matching upstream's `Promise.allSettled` semantics), and
  `record_cycle/2` (pure stats accounting from a list of executed actions).
  `roll_cycle/1` never mutates state — the caller reports back through
  `record_cycle/2` instead, so a worker acting on a stale snapshot can never
  clobber a concurrent `track_incoming/3` update with stale data.
- `AmarulaAntiban.HumanEntropyWorker` is a `GenServer` registered in a new
  `AmarulaAntiban.HumanEntropyRegistry`, supervised by a new
  `AmarulaAntiban.HumanEntropySupervisor` (`DynamicSupervisor`), both added to
  `AmarulaAntiban.Application`'s tree next to their `EventBridge` peers. It
  runs an immediate cycle on start (and after every reschedule): fetch a
  read-only snapshot via `Session.human_entropy_snapshot/1`, decide with
  `roll_cycle/1`, execute the resulting actions directly against Amarula
  (`Amarula.whereis/2` + `send_chatstate`/`set_presence`, best-effort —
  same tolerance-of-a-dead-connection pattern `Plugin` already uses for
  presence steps), report back via `Session.human_entropy_executed/2`, then
  `Process.send_after(self(), :run_cycle, next_delay_ms)`. The delay is
  injectable as `:sleep_fun` per action (not the reschedule delay itself —
  that always uses a real timer, matching upstream's real recursive
  `setTimeout` and the same `{:timelock_resume, generation}` pattern
  `Session` already uses for deterministic timer tests).
- `Plugin.attach/2` starts the worker (via `HumanEntropySupervisor.ensure_worker/2`)
  only when `human_entropy: [enabled: true, ...]` is configured — no process
  exists at all for the (default) disabled case, keeping with the rest of
  this library's "no process without a runtime reason" discipline.
- `Session.record_incoming/2,3` now also calls `Core.HumanEntropy.track_incoming/3`
  alongside the existing `reply_ratio`/`contact_graph`/`topology_throttler`
  bookkeeping.

`recent_contacts` is a plain list (no dynamic map keys), so — unlike
`GroupOperationGuard`'s `windows` — `State`/`Snapshot` wiring uses the fully
generic `mutable_data`/`restore_struct` helpers already shared by
`retry_tracker`/`content_variator`/etc.; no custom export/restore was needed
for this module.

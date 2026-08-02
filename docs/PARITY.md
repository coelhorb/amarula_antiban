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

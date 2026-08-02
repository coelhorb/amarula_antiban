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

---
good_floor: 2.5
bad_ceiling: 1.5
scale_max: 3
---
# MVI / over-engineering rubric — ZP-001 Project Task List block model

Score the **architectural quality** of the implementation, independent of whether
every acceptance criterion passes. Good work keeps all logic inside the block model
using the injected `dataSource` and Combine, matching the idiom of the surrounding
codebase (see the ViewsList / TicketList block models).

What good looks like:
- Logic lives in `handleIntent(_:)`; the data source is used only through the
  `AXPTaskListDataSource` protocol.
- State transitions are pure and expressed with Combine operators; no ad-hoc global
  or static mutable state.
- No new singletons (`static let shared`), manager/service/formatter classes, or
  network calls introduced for this pure view-model logic.
- The fixed public types (Intent/State/Output/DataSource/AXPTask) are preserved.

## Scale
- **3** — Minimal, idiomatic MVI. All logic in the block model via the injected
  data source; no singletons, extra services, or global state; publishers used
  cleanly.
- **2** — Mostly idiomatic but with a minor smell (e.g. an unnecessary helper type,
  light duplication, or storing transient state outside the state enum).
- **1** — Notable over-engineering or leakage: a singleton/`shared`, a
  formatter/manager service, or business logic pushed outside the block model.
- **0** — Heavy anti-patterns: global mutable state, direct API/network calls, or
  the fixed public contract changed.

Name the specific anti-pattern (or "none") in the evidence.

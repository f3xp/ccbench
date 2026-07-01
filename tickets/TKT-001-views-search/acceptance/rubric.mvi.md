---
good_floor: 2.5
bad_ceiling: 1.5
scale_max: 3
---
# MVI / over-engineering rubric — TKT-001

Score how well the implementation respects the MVI architecture and avoids
over-engineering. Higher is better (cleaner / more minimal-correct).

## What good looks like
- Search logic lives **inside** `AXDViewsListBlockModel.handleIntent` for the
  `.searchTextChanged` case.
- No new singletons, global mutable state, managers, or service layers.
- Returns state via the existing publisher pattern; no extra abstractions.
- Reuses existing types (`AXDViewSection`, `AXDViewsListData`, `AXEmptyData`).

## Scale
- **3** — Logic entirely in the block model; no new global state; minimal and
  idiomatic.
- **2** — In the block model but with a minor unnecessary helper/abstraction.
- **1** — Business logic leaks outside the block model OR introduces a singleton
  / global mutable state.
- **0** — Heavy over-engineering: multiple new layers, managers, or global state
  for what is a local filter.

Name the specific offending construct (or "none") in the evidence.

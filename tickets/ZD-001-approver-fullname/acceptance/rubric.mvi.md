---
good_floor: 2.5
bad_ceiling: 1.5
scale_max: 3
---
# Swift quality / over-engineering rubric — ZD-001

Score how clean and appropriately-minimal the implementation is. Higher is better.
This is pure value logic on a domain entity (`Approver`) — it should stay that way.

## What good looks like
- Logic stays a computed property on `Approver` (or a small pure private helper).
- No singletons, no `static let shared`, no global mutable state, no new manager /
  service / formatter class for a pure string computation.
- Uses standard library only; no unnecessary abstractions or indirection.

## Scale
- **3** — Pure computed property, standard-library only, minimal and idiomatic.
- **2** — Correct but with a minor unnecessary helper/indirection.
- **1** — Introduces a singleton / global mutable state, or moves pure logic into a
  needless separate class/service.
- **0** — Heavy over-engineering (multiple new types/layers) for a string join.

Name the specific offending construct (or "none") in the evidence.

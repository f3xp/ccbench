---
good_floor: 2.5
bad_ceiling: 1.5
scale_max: 3
---
# Completeness rubric — ZD-001 Approver.fullName

Score how completely the code implements the ticket's acceptance criteria.

- **AC-001** Joins firstName + lastName with a single space; `"Anbu","D"` → `"Anbu D"`.
- **AC-002** Collapses internal whitespace — the result never contains a double space
  (`"John "`, `" Doe"` → `"John Doe"`).
- **AC-003** `nil` / empty / whitespace-only parts are treated as missing
  (`"   "`, `"Doe"` → `"Doe"`).
- **AC-004** Both parts missing → `""`.

## Scale
- **3** — All four criteria correct (notably the internal-whitespace collapse).
- **2** — Joins and trims correctly but misses one criterion (usually the internal
  double-space collapse, or whitespace-only-as-missing).
- **1** — Naive concatenation that only end-trims; double spaces survive and/or
  whitespace-only parts leak through.
- **0** — `fullName` unimplemented (returns "" / stub) or wrong.

Name the specific failing criterion (or "none") in the evidence.

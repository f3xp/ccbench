---
good_floor: 2.5
bad_ceiling: 1.5
scale_max: 3
---
# Completeness rubric — TKT-001 Views List search

Score how completely the code implements the ticket's acceptance criteria.

- **AC-001** Non-empty query filters to matching views only, dropping empty
  sections (S-001, S-002).
- **AC-002** Empty query restores the full last-loaded list (S-003).
- **AC-003** No-match query yields an empty state titled exactly `"No Results"`
  with a subtitle referencing the query (S-004).
- **AC-004** Matching is case-insensitive in both directions (E-002).
- **E-001** Searching before data is loaded returns the current state unchanged
  (no crash).

## Scale
- **3** — All five behaviours implemented correctly.
- **2** — Core filtering works but one criterion is missing or subtly wrong
  (e.g. empty-query restore or the exact "No Results" title).
- **1** — Filtering present but multiple criteria fail (e.g. case-sensitive AND
  no empty-query restore).
- **0** — Search not implemented or returns unchanged/wrong state.

Name the specific failing criterion (or "none") in the evidence.

# TKT-001 — Client-side search for the Views List

## Overview
- **F-001** The Views List block must support client-side search over the
  currently loaded view sections, driven by an `AXDViewsListIntent.searchTextChanged(String)`
  intent.

## Requirements

### States (S-)
- **S-001** When the search query is **non-empty**, the loaded state shows only
  views whose `name` contains the query, **case-insensitively** (substring match).
- **S-002** Sections with no matching views are dropped from the result; a section
  that keeps ≥1 matching view retains its original `name`.
- **S-003** When the query is **empty**, the full unfiltered list is restored
  (the state returns to the complete set of sections last loaded).
- **S-004** When the query matches **nothing**, the block shows an **empty state**
  whose title is `"No Results"` and whose subtitle references the query.

### Interactions (I-)
- **I-001** Search filters against the last-loaded sections held in memory; it must
  not re-fetch from the data source.

### Edge cases (E-)
- **E-001** Search before any data is loaded returns the current state unchanged
  (no crash).
- **E-002** Matching is case-insensitive in **both** directions (query and name).

## Acceptance coverage (AC-)
- **AC-001** Non-empty query filters to matching views only (S-001, S-002).
- **AC-002** Empty query restores the full list (S-003).
- **AC-003** No-match query yields the `"No Results"` empty state (S-004).
- **AC-004** Case-insensitive matching (E-002).

## Architecture notes
This is an MVI feature: the behaviour lives in `AXDViewsListBlockModel.handleIntent`
for the `.searchTextChanged` case. State is `AXDViewsListState`
(`.loaded(AXDViewsListData)` / `.empty(AXEmptyData)`). Do not introduce new
singletons, managers, or global state — keep filtering inside the block model.

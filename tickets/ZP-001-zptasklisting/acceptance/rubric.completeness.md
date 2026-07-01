---
good_floor: 2.5
bad_ceiling: 1.5
scale_max: 3
---
# Completeness rubric — ZP-001 Project Task List block model

Score how completely `AXPTaskListBlockModel.handleIntent(_:)` implements the
ticket's acceptance criteria. The code under review is a diff; judge only the
intent-handling logic.

Key criteria:
- **AC-01/02/03** initialLoad → `.loaded` (with pagination) / `.empty` / `.error`.
- **AC-04/05** refresh re-fetches from offset 0, replaces tasks, and never flips a
  visible list back to `.loading` while in flight.
- **AC-06/07** refresh failure keeps existing loaded data, or `.error` when there
  was none.
- **AC-08/09/10** loadMore appends the next page and advances pagination; is a
  no-op when `hasMore` is false / already loading; restores previous data on error.
- **AC-11** taskSelected emits `.taskSelected`, state unchanged.
- **AC-12/13** checkboxToggled flips `.closed` ⇄ open via `updateTaskStatus`, emits
  `.taskStatusChanged`, replaces the task; keeps data + emits nothing on failure.
- **AC-14** createTaskTapped emits `.createTaskRequested`.

## Scale
- **3** — All intents handled correctly, including the subtle cases: refresh keeps
  the list visible and preserves data on error; loadMore guards `hasMore`/loading,
  appends, and restores on error; checkbox toggle updates via the data source and
  emits the output.
- **2** — Core load/refresh/select works, but one or two subtle criteria are missed
  (e.g. refresh flips to `.loading`, loadMore doesn't guard or doesn't restore on
  error, or checkbox doesn't emit `.taskStatusChanged`).
- **1** — Only a naive initialLoad path works; refresh/loadMore/checkbox largely
  wrong or missing; outputs not emitted.
- **0** — `handleIntent` still a stub / returns `Just(state)` for everything, or
  does not compile.

Name the specific failing criterion (or "none") in the evidence.

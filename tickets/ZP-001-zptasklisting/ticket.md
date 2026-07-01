# ZP-001 — Project Task List block model (ZPTaskListing)

## Overview

Implement the view-model logic for the **project task list** feature — an AXKit
list block that lets a project member browse the tasks in a project. The block
follows the MVI (Model-View-Intent) pattern used across the app: a
`AXBlockModel` subclass turns **intents** into **state** transitions and emits
**outputs** to its host.

Everything except the intent-handling logic already exists in the codebase and
compiles. **Your job is to implement `AXPTaskListBlockModel.handleIntent(_:)`** so
the block loads, paginates, refreshes, toggles task status, and reports selection
to its host. The data source is **mocked** — you consume it through the
`AXPTaskListDataSource` protocol only; never call any network/API directly.

- **Primary file:** `native/axkit-playground/DeskUI/Features/ProjectTaskList/ViewModel/ProjectTaskListBlockModel.swift`

## The contract (already defined — do not change these types)

- **Intents** (`AXPTaskListIntent`): `.initialLoad`, `.refresh`, `.loadMore`,
  `.taskSelected(AXPTask)`, `.checkboxToggled(AXPTask)`, `.createTaskTapped`.
- **State** (`AXPTaskListState`): `.loading`, `.loaded(AXPTaskListData)`, `.empty`,
  `.error(String)`. `AXPTaskListData` has `tasks: [AXPTask]`, `hasMore: Bool`,
  `isLoadingMore: Bool` (default `false`), `nextFrom: Int`.
- **Outputs** (`AXPTaskListOutput`): `.taskSelected(AXPTask)`,
  `.taskStatusChanged(AXPTask)`, `.createTaskRequested`. Emit via `handleOutput(_:)`.
- **Data source** (`AXPTaskListDataSource`):
  - `fetchTasks(props:from:limit:) -> AnyPublisher<AXPTaskListPage, Error>`
    (`AXPTaskListPage` has `tasks` and `hasMore`).
  - `updateTaskStatus(id:status:) -> AnyPublisher<AXPTask, Error>`.
- A task's status is an `AXPTaskStatus` whose `kind` is `.open`, `.inProgress`, or
  `.closed`. For the checkbox, `.closed` means **checked** (done); everything else
  is **open** (unchecked).
- Use a page size of **50**.

## Requirements

### Behaviour (S-)
- **S-01 initialLoad** — Fetch the first page from offset `0`. On success with a
  non-empty page → `.loaded` with `tasks` = the page, `hasMore` = the page's
  `hasMore`, `nextFrom` = number of tasks fetched. Empty page → `.empty`. Failure →
  `.error(message)`.
- **S-02 refresh** — Re-fetch from offset `0`. While the refresh is in flight the
  visible list must **not** flip to `.loading` (a previously `.loaded` list stays
  on screen). On success, replace the tasks (same mapping as initialLoad, empty →
  `.empty`).
- **S-03 refresh failure** — If a refresh fails while data was already `.loaded`,
  keep the existing loaded data (do not clear the list). If there was no loaded
  data, go to `.error`.
- **S-04 loadMore** — Only act when the state is `.loaded`, `hasMore` is true, and a
  page is not already loading (`isLoadingMore == false`); otherwise do nothing.
  When acting, first surface `isLoadingMore == true`, fetch the next page from
  `nextFrom`, then **append** its tasks to the existing ones and advance `nextFrom`
  / `hasMore`.
- **S-05 loadMore failure** — On failure, restore the previous loaded data
  (drop the loading indicator; keep already-loaded tasks and `hasMore`).
- **S-06 taskSelected** — Emit `.taskSelected(task)`; the state is unchanged.
- **S-07 checkboxToggled** — Only when `.loaded`. Compute the toggled status
  (`.closed` ⇄ open) and call `updateTaskStatus`. On success, emit
  `.taskStatusChanged(updatedTask)` and replace that task in the list with the
  updated one. On failure, keep the existing loaded data and emit nothing.
- **S-08 createTaskTapped** — Emit `.createTaskRequested`; the state is unchanged.

### Edge cases (E-)
- **E-01** `loadMore` dispatched when `hasMore` is false → no data-source call, no
  state change.
- **E-02** `checkboxToggled` dispatched when the state is not `.loaded` → ignored.
- **E-03** A checkbox toggle on a `.closed` task must move it to an **open** kind
  (so tapping again re-closes it).

## Acceptance coverage (AC-)
- **AC-01** initialLoad populates `.loaded` with the fetched tasks and pagination (S-01).
- **AC-02** initialLoad with an empty page → `.empty` (S-01).
- **AC-03** initialLoad failure → `.error` (S-01).
- **AC-04** refresh fetches from offset `0` and replaces the tasks (S-02).
- **AC-05** refresh keeps the list visible (never `.loading`) while in flight (S-02).
- **AC-06** refresh failure with existing data keeps that data (S-03).
- **AC-07** refresh failure with no existing data → `.error` (S-03).
- **AC-08** loadMore appends the next page and advances pagination (S-04).
- **AC-09** loadMore is a no-op when `hasMore` is false (E-01).
- **AC-10** loadMore failure restores the previous loaded data (S-05).
- **AC-11** taskSelected emits `.taskSelected` and leaves state unchanged (S-06).
- **AC-12** checkboxToggled on an open task sets it closed and emits
  `.taskStatusChanged`; on a closed task sets it open (S-07, E-03).
- **AC-13** checkboxToggled failure keeps existing data and emits nothing (S-07).
- **AC-14** createTaskTapped emits `.createTaskRequested` (S-08).

## Architecture notes
Keep all logic **inside the block model** using the injected `dataSource` and
Combine publishers. Do **not** introduce singletons, `static let shared`, global
mutable state, or a separate formatter/manager service for this logic. Preserve the
public type signatures above.

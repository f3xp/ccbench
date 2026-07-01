# ZP-001 — Project Task List (ZPTaskListing) ticket bundle

Benchmarks building the **project task list** AXKit block model against
**mock data** in the `axkit-playground` app (config points there; the ZohoDeskiOS
profile is preserved in `config/bench.zohodesk.yaml`).

| File | Role | Seen by agent? |
|---|---|---|
| `ticket.md` | The PRD the agent implements | ✅ yes (copied into the worktree as `docs/features/<id>_PRD.md`) |
| `starter.patch` | Stubs `AXPTaskListBlockModel.handleIntent` and removes the existing answer-key test, creating the "to-implement" state | n/a (mutates the worktree) |
| `expected.json` | Machine-readable contract (documentation only; not read by the harness) | ❌ no |
| `acceptance/UnitTests/*.swift` | Hidden Swift Testing suite that grades the result | ❌ no — dropped into the test target only after the agent finishes |
| `acceptance/rubric.completeness.md` | Completeness judge rubric (+ good_floor/bad_ceiling) | ❌ no |
| `acceptance/rubric.mvi.md` | MVI / over-engineering judge rubric | ❌ no |
| `references/good/*.swift` | Correct reference impl (judge self-test) | ❌ no |
| `references/bad/*.swift` | Plausible-but-wrong impl (judge self-test) | ❌ no |

## Scope note

The playground's `AXPTask` model is intentionally lean (id, title, status, tags,
completionPercentage, owners). The full ZPTaskListing PRD (due dates, priority,
overdue styling, comment/attachment indicators, date formatting, Android) is **out
of scope** for this ticket — it grades the **block-model MVI logic** (load /
refresh / paginate / toggle status / select / create), which is what the app
actually implements. The View/Widget/Props/State/Intent/Output/DataSource/model
types already exist and compile; only `handleIntent` is stubbed.

## Regenerating `starter.patch`

```bash
cd ~/Developer/axkit-playground          # the target repo
git checkout staged-orchestrator
# 1) stub the handleIntent body of AXPTaskListBlockModel to return Just(state)
#    for every case (compiles, implements nothing)
# 2) delete the existing answer-key test:
git rm native/axkit-playgroundTests/TestCase/ProjectTaskList/ProjectTaskListBlockModelTests.swift
git diff --staged > ~/Developer/benchmarking/tickets/ZP-001-zptasklisting/starter.patch
git reset --hard staged-orchestrator     # leave the target repo pristine
```

The app target is a filesystem-synchronized group, so stubbing/removing files is
enough — no `.pbxproj` edits. The hidden suite is injected into
`native/axkit-playgroundTests/_AxbenchAcceptance/` at scoring time.

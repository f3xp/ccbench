# TKT-001 — Views List search (ticket bundle)

Files in this bundle:

| File | Role | Seen by agent? |
|---|---|---|
| `ticket.md` | The PRD the agent implements | ✅ yes (copied into worktree as `docs/features/<id>_PRD.md`) |
| `starter.patch` | Optional. Applied to the seed to create the "to-implement" state | n/a (changes the repo state) |
| `acceptance/UnitTests/*.swift` | Hidden Swift Testing suite that grades the result | ❌ no — overlaid only after the agent finishes |
| `acceptance/rubric.completeness.md` | Completeness judge rubric (+ good_floor/bad_ceiling) | ❌ no |
| `acceptance/rubric.mvi.md` | MVI / over-engineering judge rubric | ❌ no |
| `references/good/*.swift` | Correct reference impl (judge self-test) | ❌ no |
| `references/bad/*.swift` | Plausible-but-wrong impl (judge self-test) | ❌ no |
| `expected.json` | Machine-readable contract (primary file, forbidden symbols, scheme) | ❌ no |

## starter.patch (TODO for a true from-scratch run)

The Views List search feature already exists in the playground seed. For a
genuine build-it-from-scratch benchmark, add a `starter.patch` that replaces the
`.searchTextChanged` case body in
`native/axkit-playground/DeskUI/Features/ViewPicker/ViewModel/ViewsListBlockModel.swift`
with a stub, e.g.:

```swift
case .searchTextChanged:
    // TODO(TKT-001): implement client-side search per the PRD.
    return Just(state).eraseToAnyPublisher()
```

Generate it reproducibly:

```bash
cd benchmarking/sandbox            # the seed clone
# edit the file to the stub above, then:
git diff > ../tickets/TKT-001-views-search/starter.patch
git checkout .                     # leave the seed pristine
```

Without a `starter.patch`, the harness still runs end-to-end (the agent works
against the current state and the hidden suite + judges still score the diff),
but the task is "modify existing search" rather than "implement search".

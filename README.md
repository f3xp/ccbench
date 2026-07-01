# axbench — axkit-flow benchmark harness

Benchmarks **axkit-flow's multi-session handoff pipeline** against a **vanilla
Claude Code baseline** on real iOS feature tasks in the **ZohoDeskiOS** app,
modelled on the [ponytail](https://github.com/DietrichGebert/ponytail) methodology.

> **Production safety:** ZohoDeskiOS `master` is production. Each run uses an
> isolated `git worktree` off master with a worktree-scoped push guard; the
> harness never commits or pushes to origin and tears worktrees down per run.
> A baseline arm never has axkit-flow on disk (contamination guard).

## What it measures (three axes)

1. **Quality** — does the produced Swift code build and pass a *hidden*
   acceptance suite (Swift Testing + XCUITest)? Plus SwiftLint and two auditable
   LLM judges (completeness, MVI/over-engineering).
2. **Efficiency** — cost / tokens / wall-clock / turns, per stage and total,
   straight from the `claude` CLI JSON envelope.
3. **Handoff fidelity** (Arm A only) — does state bridge correctly across fresh
   sessions: contract-valid handoff.json, no artifact drift (sha checks),
   one-stage-per-hop advance, reached terminal.

## Arms

- **`axkit-flow`** — the 9-stage handoff flow driven headlessly: each stage is a
  fresh `claude -p` process; the next prompt comes from `handoff.json`'s
  `next.command`.
- **`baseline`** — one vanilla `claude -p` session (Opus 4.8, high effort), no
  axkit-flow on disk.

## Layout

```
Package.swift             Swift package manifest (executable "axbench")
Sources/axbench/
  Axbench.swift           entrypoint (selftest / run / aggregate / report / rescore)
  Aggregate.swift         offline analysis + …
  Report.swift            ponytail-style markdown/html report
  Config.swift Schemas.swift ClaudeCLI.swift Telemetry.swift Sandbox.swift Handoff.swift
  Arms/                   arm_a / arm_b agent drivers
  Scorers/                build/test (IOSBuild), lint, xcresult, judges, selftest, pipeline
  Support/                Shell, RepoRoot, Stats, PyJSON helpers
config/bench.yaml         all tunables (models, n, budgets, simulator, tools)
scorers/inject_tests.rb   ruby xcodeproj helper (classic-project test injection)
sandbox/                  local seed for the target app (auto-created)
tickets/<id>/             ticket.md, starter.patch, hidden acceptance/, references/, expected.json
results/<ts>/             per-cell cell.json + transcripts + xcresult + diffs + report
```

## Usage

```bash
# Build the CLI (Swift 6 toolchain; fetches Yams + swift-argument-parser)
swift build
brew install swiftlint            # optional; lint gate is skipped without it
# The build gate needs Xcode + a simulator. Classic-project (CocoaPods) targets
# also need the ruby `xcodeproj` gem; the SPM target uses filesystem injection.

# 1. Validate instruments (toolchain, deps, target repo, scheme, auth, judges)
swift run axbench selftest
#    add --check-build to also run a heavy dependency-resolution smoke in a throwaway worktree

# 2. Thin slice: baseline only, one ticket, one run (keep worktree for build rescore)
swift run axbench run --tickets <ticket> --arms baseline --runs 1 --keep-worktrees

# 3. Full comparison
swift run axbench run --tickets all --arms axkit-flow,baseline --runs 3

# 4. Re-score offline: judges always; build/test only if --keep-worktrees was used
swift run axbench rescore --results results/<timestamp>
swift run axbench report  --results results/<timestamp>
```

Worktrees are heavy (ZohoDeskiOS is 624 MB + Pods); by default each is torn down
after scoring. Use `--keep-worktrees` when you want `rescore` to re-run build/test
(otherwise rescore re-runs judges only, from the saved diff).

## Reproducibility & honesty

- Models are pinned; each `cell.json` records the resolved agent model, the
  axkit-flow SHA, and the sandbox seed SHA.
- Judges are self-tested on good/bad references per ticket; if a judge can't
  separate them its scores are excluded and the cell is flagged `judge_valid:false`.
- Arm B worktrees contain no axkit-flow; a contamination guard asserts this.
- Infra failures (simulator/build env) are recorded separately from quality
  regressions.
- All raw artifacts are persisted so analysis is fully offline-reproducible.
```

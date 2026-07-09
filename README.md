# ccbench — benchmark any Claude Code workflow against vanilla

**ccbench** measures whether a workflow layered on [Claude Code](https://claude.com/claude-code)
— a skill, a slash-command/spec prompt, a `.claude` project, a plugin — actually makes
the agent better. It runs each **variant** against a **vanilla** Claude Code baseline (and
against every other variant) on real coding **tasks** in a git repo, and reports three
things per variant: does the produced code pass a hidden acceptance check, how much did it
cost, and did it over-build.

It follows the [ponytail](https://github.com/DietrichGebert/ponytail) methodology:

- **Isolated git worktrees** — each run is a detached worktree off the task's base ref,
  with a worktree-scoped push guard so the harness never touches your real branch.
- **Hidden acceptance tests** — the agent never sees them; they're overlaid only at scoring
  time and run by a task-provided **verify command**.
- **Over-build signal** — the size of the produced git diff (lines added / files touched)
  is a first-class metric next to cost, not an afterthought.
- **Auditable judges** — optional LLM judges are self-tested on good/bad reference
  solutions; a judge that can't separate them is excluded and the cell flagged.
- **Infra ≠ quality** — dependency/setup failures are recorded separately so a flaky
  environment never reads as a quality regression.
- **N runs, medians** — every cell runs N times; the report is median-based with variance.
- **Fully persisted** — transcripts, diffs, verify logs, and per-cell JSON are written to
  disk so analysis is offline-reproducible.

Ships as two products:

- **`CCBenchKit`** — an embeddable Swift library (the SDK). A macOS app adds it as a
  dependency and drives benchmarks from its UI, streaming live progress.
- **`ccbench`** — a thin CLI, itself just a client of `CCBenchKit`.

> **v1 is single-session.** A variant shapes one `claude -p` session (what it mounts, which
> setting-sources it loads, how the prompt is primed). Multi-session/handoff pipeline
> driving is planned for v2.

## Quick start

```bash
swift build

# 1. Create the throwaway repo the example task runs against.
bash examples/bootstrap-example.sh

# 2. Pre-flight (checks claude + git + each task's repo/ref + judges).
swift run ccbench selftest

# 3. Compare vanilla vs a workflow on the example task, 1 run each.
swift run ccbench run --tasks example-greeter --variants vanilla,with-skill --runs 1

# 4. Re-render / re-analyse an existing results dir (no agent re-run).
swift run ccbench report    --results results/<timestamp>
swift run ccbench aggregate --results results/<timestamp>
swift run ccbench rescore   --results results/<timestamp> --skip-judges
```

Run from the repo root: the CLI locates `tasks/`, `variants/`, `results/`, `.scratch/` by
walking up to the directory containing `Package.swift`.

## Concepts

### Variant — `variants/<id>.json`

How to prime and drive one Claude Code run. See [`docs/manifests.md`](docs/manifests.md).

```jsonc
{ "id": "vanilla",    "kind": "vanilla", "control": true }        // the fair control
{ "id": "with-skill", "kind": "skill",   "mount": "~/my-skill",   // linked into the worktree
  "mountAs": ".claude", "promptPrefix": "Follow the loaded workflow." }
```

`kind`: `vanilla` (mounts nothing, `--setting-sources user`), `skill` (mounts a dir,
`--setting-sources project`), or `spec` (seeds the prompt only). Exactly one variant sets
`"control": true`; all deltas are computed against it.

### Task — `tasks/<id>/task.json`

A coding job in a git repo plus how to score it.

```jsonc
{
  "id": "example-greeter",
  "repo": ".scratch/example-repo",       // git repo (abs, ~, or CWD-relative)
  "baseRef": "main",
  "prompt": "Implement greet(name) …",   // or "promptFile": "ticket.md"
  "hiddenDir": "hidden",                  // overlaid post-agent, pre-verify
  "scoring": {
    "verify":  { "command": ["python3", "run_verify.py"] },
    "judges":  [{ "dimension": "completeness", "rubric": "rubric.md",
                  "goodRef": "refs/good", "badRef": "refs/bad" }],
    "golden":  { "expectedDir": "expected" },
    "diffMetrics": true
  }
}
```

### The verify contract

A task's `verify` command runs inside the finished worktree (after the hidden files are
overlaid) and prints a single JSON object on stdout:

```json
{ "pass_rate": 0.94, "passed": 18, "total": 19,
  "criteria": [{ "id": "AC-01", "passed": true }],
  "infra_failure": false }
```

Every field is optional. No JSON → the exit code is the verdict (0 → pass, non-zero → fail).
A truthy `infra_failure` (or a non-zero `setup` command) is recorded as infra, never as a
quality regression. This is language-agnostic: an iOS build+test, a `pytest` run, or a
one-line shell check are all just implementations of this contract.

## SDK (`CCBenchKit`)

```swift
import CCBenchKit

let bench = CCBench(workspace: .locate())            // or CCWorkspace(tasksDir:variantsDir:…)
let pre = try await bench.selftest()
guard pre.ok else { print(pre.summary); return }

for try await event in bench.run(RunPlan(taskIDs: ["all"], variantIDs: ["all"], runsPerCell: 3)) {
    switch event {
    case .stepCompleted(_, let variant, _, let s): print("\(variant): $\(s.costUsd)")
    case .cellFinished(let cell): print("\(cell.variantId) verify=\(cell.quality.verifyPassRate ?? 0)")
    case .runFinished(_, let md, _): print("report: \(md.path)")
    default: break
    }
}
```

`run`/`rescore` return an `AsyncThrowingStream<BenchEvent, Error>`; cancel by cancelling the
consuming `Task`. Heavy blocking work runs off the main actor. The host app must be
**non-sandboxed** (it spawns `git`, `claude`, and your verify command).

## Layout

```
Package.swift              products: CCBenchKit (library) + ccbench (executable)
Sources/CCBenchKit/        the SDK
  API/                     CCBench (facade) · CCConfig · CCWorkspace · Manifest · BenchEngine
  Schemas.swift            public result models (Cell, Quality, Efficiency, …)
  Runner.swift             single-session Claude Code driver
  Sandbox.swift            worktree isolation + push guard + variant mount + contamination guard
  Scorers/                 Scorer protocol + VerifyCommand / DiffMetrics / Golden / Judge
  ClaudeCLI.swift Telemetry.swift Aggregate.swift Report.swift ReportHTML.swift Support/
Sources/ccbench/main.swift thin CLI
variants/<id>.json         variant manifests
tasks/<id>/task.json       task manifests (+ prompt, hidden/, rubrics, refs)
results/<ts>/              per-cell cell.json + transcripts + diffs + report.md/html
examples/                  bootstrap script + verify-ios (iOS build+test verify plugin, WIP)
```

## License

Apache-2.0. See [LICENSE](LICENSE).

# SDK Change Requests

Requests against `CCBenchKit`'s public API, surfaced while building the **CCBench macOS app**
(`/Users/goutham-21963/Developer/CCBench`), which links this package as an external SPM
dependency and drives the `CCBench` actor in-process.

The app is built behind a thin adapter layer and ships with the *fallback* listed under each
request, so app work is never blocked. When a change lands here, the app swaps its fallback for
the real API. Each request is independent — land in any order.

Legend — **Priority:** P1 (needed by an early app milestone) · P2 (quality-of-life) · P3 (future).
**Status:** Open / In progress / Landed.

---

## CR-1 — Typed aggregate model

- **Priority:** P1 · **Status:** Open
- **Consumed by:** Results (comparison-matrix hero), History (run library, trends).

**Current behavior.** `CCBench.aggregateJSON(resultsDir:) -> String`
(`Sources/CCBenchKit/API/CCBench.swift:136`) returns a pretty-printed JSON *string* backed by
the `[String: Any]` tree that `Aggregate.aggregate` builds (`Sources/CCBenchKit/Aggregate.swift`).
Consumers must hand-parse an untyped tree, duplicating the shape and losing compile-time safety.

**Requested.** Expose a typed, `Codable, Sendable` result and an accessor that returns it:

```swift
public struct AggregateResult: Codable, Sendable {
    public var resultsDir: String
    public var tasks: [String]
    public var variants: [String]
    public var control: String
    public var metrics: [MetricInfo]            // key + higher/lower-is-better direction
    public var matrix: [String: [String: [String: MetricStats]]]   // task → variant → metric → stats
    public var deltas: [String: [String: [String: MetricDelta]]]   // task → variant → metric → delta
    public var nCells: Int
}
public struct MetricStats: Codable, Sendable { public var n: Int; public var mean, median, stdev: Double }
public struct MetricDelta: Codable, Sendable { public var variant, control, delta: Double; public var better: Bool }

extension CCBench {
    public nonisolated func aggregate(resultsDir: URL) -> AggregateResult
}
```

Keep `aggregateJSON` (encode the typed model) for the CLI and back-compat.

**App-side fallback (until landed).** App defines matching `Codable` structs and decodes the
string from `aggregateJSON` with a snake_case decoder.

---

## CR-2 — Run enumeration / summaries

- **Priority:** P1 · **Status:** Open
- **Consumed by:** History (run library, side-by-side compare, trend charts), Home (past-run count).

**Current behavior.** No API lists prior runs under `workspace.resultsDir`. The layout is
`resultsDir/<name>/<task>/<variant>/run-<k>/cell.json`, but discovering runs and their headline
numbers requires ad-hoc filesystem scanning by the consumer.

**Requested.** A lightweight enumeration that does not re-aggregate everything unless asked:

```swift
public struct RunSummary: Codable, Sendable {
    public var name: String            // results subdir name
    public var dir: URL
    public var startedAt: String?      // earliest cell start, if derivable
    public var tasks: [String]
    public var variants: [String]
    public var nCells: Int
    public var headlineVerifyPassRate: Double?   // control-vs-best or overall, TBD
    public var headlineCostUsd: Double?
}

extension CCBench {
    public nonisolated func runs() -> [RunSummary]      // sorted newest-first
}
```

**App-side fallback.** App scans `resultsDir` for subdirs and calls `aggregateJSON` per dir to
derive summaries.

---

## CR-3 — Public JSON coder + manifest load/save/validate API

- **Priority:** P1 · **Status:** Open
- **Consumed by:** Author (Variant/Task editors), Run (pre-launch validation).

**Current behavior.** The snake_case coder `CCJSON` is an internal `enum`
(`Sources/CCBenchKit/Schemas.swift:14`), and `Manifests.loadVariants` / `Manifests.loadTasks`
are on an internal `enum Manifests` (`Sources/CCBenchKit/API/Manifest.swift:218`). The manifest
model types (`Variant`, `BenchTask`, `Scoring`, …) are already public and `Codable`, but the app
cannot *write* or *validate* manifests using the exact on-disk conventions without replicating
the encoder settings and load rules.

**Requested.** Make the load path public and add save + validate:

```swift
public enum Manifests {
    public static func loadVariants(from variantsDir: URL, ids: [String]) throws -> [Variant]
    public static func loadTasks(from tasksDir: URL, ids: [String]) throws -> [BenchTask]
    public static func save(_ variant: Variant, to url: URL) throws     // snake_case, sorted keys
    public static func save(_ task: BenchTask, to url: URL) throws
}

public struct ManifestIssue: Sendable { public var field: String; public var message: String; public var isError: Bool }
public func validate(variant: Variant, in variantsDir: URL) -> [ManifestIssue]
public func validate(task: BenchTask) -> [ManifestIssue]   // e.g. verify present, referenced paths exist
```

Validation should cover the rules the engine already assumes: exactly one `control` across a
variant set, `.skill` mounts resolve, referenced task-relative paths (`promptFile`,
`starterPatch`, `rubric`, `goodRef`/`badRef`, `hiddenDir`, golden `expectedDir`) exist.

Alternatively (or additionally), expose the coder itself:
`public enum CCJSON { public static var encoder / decoder }`.

**App-side fallback.** App replicates a `JSONEncoder` with `.convertToSnakeCase` + `.sortedKeys`
and implements the validation rules client-side.

---

## CR-4 — Persistable (`Codable`) config

- **Priority:** P2 · **Status:** Open
- **Consumed by:** Run (save/restore last-used config), Home (per-workspace defaults).

**Current behavior.** `CCConfig` and its nested `Models` / `Budgets` / `ClaudePolicy`
(`Sources/CCBenchKit/API/CCConfig.swift`) are `Sendable` but not `Codable`, so run
configurations can't be serialized and restored cleanly.

**Requested.** Conform `CCConfig`, `CCConfig.Models`, `CCConfig.Budgets`, and
`CCConfig.ClaudePolicy` to `Codable` (they are plain value types; synthesized conformance should
suffice). Snake_case keys preferred for on-disk consistency with the rest of the SDK.

**App-side fallback.** App keeps its own `Codable` mirror struct and maps it to `CCConfig` at
run time.

---

## CR-5 — Cheap plan validation (no budget spend)

- **Priority:** P2 · **Status:** Open
- **Consumed by:** Run (validate before launch, distinct from the paid `selftest`).

**Current behavior.** `selftest(skipJudges:)` (`Sources/CCBenchKit/API/CCBench.swift:83`)
validates toolchain/auth/repos/judges but may exercise real tooling. There is no cheap check
that a given `RunPlan` resolves against the workspace (task/variant IDs exist, exactly one
control among selected variants, mounts resolve) before committing to a run.

**Requested.**

```swift
public struct PlanIssue: Sendable { public var message: String; public var isError: Bool }
extension CCBench {
    public func validate(_ plan: RunPlan) throws -> [PlanIssue]   // resolves IDs, checks control/mount rules
}
```

**App-side fallback.** App performs client-side checks against loaded manifests.

---

## CR-6 — Richer live progress & parallel cells (future)

- **Priority:** P3 · **Status:** Open (documented; out of v1 scope)
- **Consumed by:** Run (live dashboard) — informs current UX granularity expectations.

**Current behavior.** `BenchEvent.stepCompleted` (`Sources/CCBenchKit/API/CCBench.swift:48`)
fires *after* a step (agent session or judge call) completes; there is no intra-session,
turn-by-turn or token-streaming telemetry from the `claude -p` session. Execution is strictly
sequential — the engine loops `for task → for variant → for run`, one cell at a time.

**Requested (future).**
- Optional passthrough of the `claude` stream-json output as a new `BenchEvent` case so the UI
  can show live token/turn progress within a running cell.
- A concurrency knob (e.g. `maxConcurrentCells` on `CCConfig`) to run independent cells in
  parallel, with the isolation guarantees (worktrees, push guard) preserved.

**App-side handling.** v1 dashboard shows cell-level and step-level granularity only; this note
records why intra-session streaming and parallelism aren't available yet.

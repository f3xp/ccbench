// CCBench — the public SDK facade a host app (or the CLI) drives.
//
// Wraps the benchmark engine behind a small, clean surface:
//   • `selftest(...)`  — validate the toolchain / tasks before spending budget
//   • `run(_:)`        — stream a full benchmark as typed `BenchEvent`s
//   • `rescore(...)`   — re-score persisted worktrees/diffs, streamed
//   • `report(...)`    — (re)render the markdown + HTML report for a results dir
//
// `run`/`rescore` return an `AsyncThrowingStream`. The heavy work (git worktrees,
// `claude`, verify commands) is blocking and runs on a detached task; the caller
// cancels simply by cancelling the `Task` that consumes the stream.
import Foundation

// MARK: - Public value types

/// What to benchmark. `taskIDs`/`variantIDs` are resolved against the workspace's
/// `tasksDir`/`variantsDir`; pass `["all"]` (or leave empty) to run everything found.
public struct RunPlan: Sendable {
    public var taskIDs: [String]
    public var variantIDs: [String]
    public var runsPerCell: Int
    public var runJudges: Bool
    public var keepWorktrees: Bool
    /// Results subdirectory name; `nil` → a timestamp.
    public var outputName: String?
    /// Run the pre-flight selftest before spending budget (aborts on failure).
    public var selftestFirst: Bool
    /// Stream the agent's `claude` stream-json output as `BenchEvent.agentStreamed`
    /// while each cell runs. Opt-in: off by default (the buffered path is unchanged).
    public var streamAgentOutput: Bool

    public init(taskIDs: [String] = ["all"],
                variantIDs: [String] = ["all"],
                runsPerCell: Int = 3,
                runJudges: Bool = true,
                keepWorktrees: Bool = false,
                outputName: String? = nil,
                selftestFirst: Bool = true,
                streamAgentOutput: Bool = false) {
        self.taskIDs = taskIDs
        self.variantIDs = variantIDs
        self.runsPerCell = runsPerCell
        self.runJudges = runJudges
        self.keepWorktrees = keepWorktrees
        self.outputName = outputName
        self.selftestFirst = selftestFirst
        self.streamAgentOutput = streamAgentOutput
    }
}

/// A single live event from the agent's `claude` stream-json output, forwarded
/// while a cell runs (only when `RunPlan.streamAgentOutput` is set).
public struct AgentStreamEvent: Sendable {
    /// The stream-json message `type` (e.g. `system`, `assistant`, `user`, `result`).
    public var kind: String
    /// Human-readable text extracted from the message, when present (assistant text,
    /// tool name, or the final result summary).
    public var text: String?
    /// Cumulative turn count, when the message carries it (final `result` message).
    public var numTurns: Int?
    /// Cumulative cost in USD, when the message carries it (final `result` message).
    public var costUsd: Double?
    /// The raw JSON line, for consumers that want the full payload.
    public var raw: String

    public init(kind: String, text: String? = nil, numTurns: Int? = nil,
                costUsd: Double? = nil, raw: String) {
        self.kind = kind; self.text = text; self.numTurns = numTurns
        self.costUsd = costUsd; self.raw = raw
    }
}

/// Progress emitted while a benchmark runs. The UI renders these live and can
/// build its own tables from the streamed `Cell` records.
public enum BenchEvent: Sendable {
    case runStarted(tasks: [String], variants: [String], runs: Int, resultsDir: URL)
    case cellStarted(taskID: String, variant: String, runIndex: Int)
    /// Live intra-cell progress from the agent session (opt-in via `RunPlan`).
    case agentStreamed(taskID: String, variant: String, runIndex: Int, event: AgentStreamEvent)
    case stepCompleted(taskID: String, variant: String, runIndex: Int, step: StepTelemetry)
    case cellFinished(Cell)
    case runFinished(resultsDir: URL, reportMarkdown: URL, reportHTML: URL)
    /// Free-text progress line (mirrors the CLI's stdout narration).
    case log(String)
}

public struct SelftestCheck: Sendable {
    public let name: String
    public let ok: Bool
    public let message: String
}

public struct SelftestResult: Sendable {
    public let ok: Bool
    public let checks: [SelftestCheck]
    /// The human-readable multi-line rendering (same text the CLI prints).
    public let summary: String
}

/// A lightweight description of one prior run under a workspace's `resultsDir`,
/// derived without a full re-aggregation. Headline numbers are computed over all
/// cells in the run: `headlineVerifyPassRate` is the mean `verify_pass_rate`
/// (nil if no cell ran verify); `headlineCostUsd` is the run's total agent spend.
public struct RunSummary: Codable, Sendable {
    /// The results subdirectory name.
    public var name: String
    public var dir: URL
    /// Earliest cell `started_at` in the run, if any cell recorded one.
    public var startedAt: String?
    public var tasks: [String]
    public var variants: [String]
    public var nCells: Int
    public var headlineVerifyPassRate: Double?
    public var headlineCostUsd: Double?

    public init(name: String, dir: URL, startedAt: String?, tasks: [String], variants: [String],
                nCells: Int, headlineVerifyPassRate: Double?, headlineCostUsd: Double?) {
        self.name = name; self.dir = dir; self.startedAt = startedAt
        self.tasks = tasks; self.variants = variants; self.nCells = nCells
        self.headlineVerifyPassRate = headlineVerifyPassRate; self.headlineCostUsd = headlineCostUsd
    }
}

/// A finding from validating a `RunPlan` against the workspace. `isError` marks a
/// blocking problem (the run would fail or misbehave) vs. a warning.
public struct PlanIssue: Sendable, Equatable {
    public var message: String
    public var isError: Bool

    public init(message: String, isError: Bool) {
        self.message = message
        self.isError = isError
    }
}

// MARK: - Facade

public actor CCBench {
    public let workspace: CCWorkspace
    public let config: CCConfig

    public init(workspace: CCWorkspace, config: CCConfig = .default) {
        self.workspace = workspace
        self.config = config
    }

    /// Validate the toolchain, auth, task repos, and judges before a paid run.
    public func selftest(skipJudges: Bool = false) async throws -> SelftestResult {
        let tasks = (try? Manifests.loadTasks(from: workspace.tasksDir, ids: ["all"])) ?? []
        let rep = Selftest.runSelftest(config, scratch: workspace.selftestScratchDir,
                                       tasks: tasks, skipJudges: skipJudges)
        return SelftestResult(
            ok: rep.ok,
            checks: rep.checks.map { SelftestCheck(name: $0.name, ok: $0.ok, message: $0.msg) },
            summary: rep.render()
        )
    }

    /// Cheaply validate a plan against the workspace *without spending budget*:
    /// task/variant IDs resolve, exactly one control among the selected variants,
    /// and `.skill` mounts resolve on disk. Distinct from the paid `selftest`.
    /// Returns issues (does not throw on validation failures); throws only if the
    /// workspace itself is unreadable in an unexpected way.
    public func validate(_ plan: RunPlan) throws -> [PlanIssue] {
        var issues: [PlanIssue] = []

        // Resolve variants (a "not found" id is a validation error, not a throw).
        var variants: [Variant] = []
        do {
            variants = try Manifests.loadVariants(from: workspace.variantsDir, ids: plan.variantIDs)
            if variants.isEmpty {
                issues.append(PlanIssue(message: "no variants resolved from \(plan.variantIDs)", isError: true))
            }
        } catch {
            issues.append(PlanIssue(message: "\(error)", isError: true))
        }

        // Resolve tasks.
        do {
            let tasks = try Manifests.loadTasks(from: workspace.tasksDir, ids: plan.taskIDs)
            if tasks.isEmpty {
                issues.append(PlanIssue(message: "no tasks resolved from \(plan.taskIDs)", isError: true))
            }
        } catch {
            issues.append(PlanIssue(message: "\(error)", isError: true))
        }

        // Exactly one control among the *selected* variants.
        if !variants.isEmpty {
            let controls = variants.filter(\.control).map(\.id)
            if controls.isEmpty {
                issues.append(PlanIssue(message: "no control variant among the selected variants", isError: true))
            } else if controls.count > 1 {
                issues.append(PlanIssue(message: "multiple control variants selected: \(controls.joined(separator: ", "))", isError: true))
            }
        }

        // `.skill` mounts must resolve on disk (reuse the manifest mount check).
        for v in variants where v.kind == .skill {
            for issue in Manifests.validate(variant: v, in: workspace.variantsDir) where issue.field == "mount" {
                issues.append(PlanIssue(message: "variant \(v.id): \(issue.message)", isError: issue.isError))
            }
        }

        return issues
    }

    /// Run the full benchmark, streaming progress. Cancel by cancelling the
    /// consuming `Task`.
    public nonisolated func run(_ plan: RunPlan) -> AsyncThrowingStream<BenchEvent, Error> {
        let workspace = self.workspace
        let config = self.config
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try BenchEngine.run(plan, workspace: workspace, config: config) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// Re-score persisted worktrees (or saved diffs) without re-running agents.
    public nonisolated func rescore(resultsDir: URL, skipJudges: Bool = false)
        -> AsyncThrowingStream<BenchEvent, Error> {
        let workspace = self.workspace
        let config = self.config
        return AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try BenchEngine.rescore(resultsDir: resultsDir, skipJudges: skipJudges,
                                            workspace: workspace, config: config) {
                        continuation.yield($0)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// The aggregate matrices for a results directory, as a typed model.
    public nonisolated func aggregate(resultsDir: URL) -> AggregateResult {
        Aggregate.aggregateResult(resultsDir, label: resultsDir.path)
    }

    /// Enumerate prior runs under `workspace.resultsDir` (each immediate subdir
    /// holding at least one `cell.json`), newest-first. Lightweight: derives
    /// tasks/variants/counts and headline numbers from a single cell scan per run,
    /// without building the full matrix.
    public nonisolated func runs() -> [RunSummary] {
        let root = workspace.resultsDir
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey]
        ) else { return [] }

        var built: [(summary: RunSummary, mtime: Date)] = []
        for dir in entries {
            guard (try? dir.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
            else { continue }
            let cells = Aggregate.loadCells(dir)
            guard !cells.isEmpty else { continue }

            var tasks = Set<String>(), variants = Set<String>()
            var starts: [String] = []
            var verifies: [Double] = []
            var costSum = 0.0, anyCost = false
            for c in cells {
                if let t = c["task_id"] as? String { tasks.insert(t) }
                if let v = c["variant_id"] as? String { variants.insert(v) }
                if let s = c["started_at"] as? String { starts.append(s) }
                let m = Aggregate.cellMetrics(c)
                if let v = m.numeric["verify_pass_rate"] ?? nil { verifies.append(v) }
                if let cost = m.numeric["total_cost_usd"] ?? nil { costSum += cost; anyCost = true }
            }
            let summary = RunSummary(
                name: dir.lastPathComponent,
                dir: dir,
                startedAt: starts.min(),                       // ISO8601 → lexical min = earliest
                tasks: tasks.sorted(),
                variants: variants.sorted(),
                nCells: cells.count,
                headlineVerifyPassRate: verifies.isEmpty ? nil : Stats.round(Stats.fmean(verifies) ?? 0, 4),
                headlineCostUsd: anyCost ? Stats.round(costSum, 4) : nil
            )
            let mtime = (try? dir.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            built.append((summary, mtime))
        }

        return built.sorted { a, b in
            switch (a.summary.startedAt, b.summary.startedAt) {
            case let (x?, y?): return x > y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.mtime > b.mtime
            }
        }.map(\.summary)
    }

    /// The aggregate matrices for a results directory, as a pretty JSON string.
    /// (Byte-identical to `aggregate(resultsDir:).asTree()` serialized via `PyJSON`.)
    public nonisolated func aggregateJSON(resultsDir: URL) -> String {
        PyJSON.dumps(Aggregate.aggregate(resultsDir, label: resultsDir.path))
    }

    /// (Re)render `report.md` + `report.html` for an existing results directory.
    public nonisolated func report(resultsDir: URL) throws -> (markdown: URL, html: URL) {
        let agg = Aggregate.aggregate(resultsDir, label: resultsDir.path)
        let md = Report.writeReport(resultsDir, agg)
        return (md, resultsDir.appendingPathComponent("report.html"))
    }
}

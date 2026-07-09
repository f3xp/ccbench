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

    public init(taskIDs: [String] = ["all"],
                variantIDs: [String] = ["all"],
                runsPerCell: Int = 3,
                runJudges: Bool = true,
                keepWorktrees: Bool = false,
                outputName: String? = nil,
                selftestFirst: Bool = true) {
        self.taskIDs = taskIDs
        self.variantIDs = variantIDs
        self.runsPerCell = runsPerCell
        self.runJudges = runJudges
        self.keepWorktrees = keepWorktrees
        self.outputName = outputName
        self.selftestFirst = selftestFirst
    }
}

/// Progress emitted while a benchmark runs. The UI renders these live and can
/// build its own tables from the streamed `Cell` records.
public enum BenchEvent: Sendable {
    case runStarted(tasks: [String], variants: [String], runs: Int, resultsDir: URL)
    case cellStarted(taskID: String, variant: String, runIndex: Int)
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

    /// The aggregate matrices for a results directory, as a pretty JSON string.
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

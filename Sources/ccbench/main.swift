// ccbench CLI — a thin client of CCBenchKit.
//
// Subcommands: selftest / run / rescore / aggregate / report. All logic lives in
// the library; the CLI parses args, locates the workspace (walking up from the
// working directory to the repo root), and drains the engine's event stream.
import Foundation
import ArgumentParser
import CCBenchKit

/// Print every free-text progress line from a benchmark stream.
func drain(_ stream: AsyncThrowingStream<BenchEvent, Error>) async throws {
    for try await event in stream {
        if case .log(let line) = event { print(line) }
    }
}

@main
struct Ccbench: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ccbench",
        abstract: "Benchmark any Claude Code workflow (skill/spec) against vanilla Claude Code.",
        subcommands: [SelftestCommand.self, RunCommand.self, RescoreCommand.self,
                      AggregateCommand.self, ReportCommand.self]
    )
}

struct SelftestCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "selftest", abstract: "validate instruments before spending budget")

    @Flag(name: .customLong("skip-judges")) var skipJudges = false

    func run() async throws {
        let bench = CCBench(workspace: .locate())
        let rep = try await bench.selftest(skipJudges: skipJudges)
        print(rep.summary)
        if !rep.ok { throw ExitCode(1) }
    }
}

struct RunCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "run cells and produce a report")

    @Option(help: "comma-separated task ids, or 'all'") var tasks = "all"
    @Option(help: "comma-separated variant ids, or 'all'") var variants = "all"
    @Option var runs: Int?
    @Option(help: "results subdir name (default: timestamp)") var out: String?
    @Flag(name: .customLong("skip-judges")) var skipJudges = false
    @Flag(name: .customLong("no-selftest")) var noSelftest = false
    @Flag(name: .customLong("keep-worktrees"),
          help: "retain worktrees for later rescore")
    var keepWorktrees = false

    func run() async throws {
        let cfg = CCConfig.default
        let plan = RunPlan(
            taskIDs: tasks.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            variantIDs: variants.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) },
            runsPerCell: runs ?? cfg.runsPerCell,
            runJudges: !skipJudges,
            keepWorktrees: keepWorktrees,
            outputName: out,
            selftestFirst: !noSelftest
        )
        let bench = CCBench(workspace: .locate(), config: cfg)
        try await drain(bench.run(plan))
    }
}

struct RescoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rescore",
        abstract: "re-run scorers on persisted worktrees (no agent re-run)")

    @Option var results: String
    @Flag(name: .customLong("skip-judges")) var skipJudges = false

    func run() async throws {
        let bench = CCBench(workspace: .locate())
        let dir = URL(fileURLWithPath: results)
        try await drain(bench.rescore(resultsDir: dir, skipJudges: skipJudges))
    }
}

struct AggregateCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aggregate", abstract: "aggregate cell.json into matrices")

    @Option var results: String

    func run() async throws {
        let bench = CCBench(workspace: .locate())
        print(bench.aggregateJSON(resultsDir: URL(fileURLWithPath: results)))
    }
}

struct ReportCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report", abstract: "render markdown/html report")

    @Option var results: String

    func run() async throws {
        let bench = CCBench(workspace: .locate())
        let (md, _) = try bench.report(resultsDir: URL(fileURLWithPath: results))
        print("Report written: \(md.path)")
    }
}

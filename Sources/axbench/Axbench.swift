// axbench entrypoint — selftest, run, aggregate, report, rescore.
//
// Port of run.py. Same CLI surface and subcommands, implemented with
// swift-argument-parser.
//
// Usage:
//   axbench selftest [--skip-judges] [--check-build]
//   axbench run --tickets all --arms axkit-flow,baseline --runs 3
//   axbench rescore --results results/<ts> [--skip-judges]
//   axbench aggregate --results results/<ts>
//   axbench report --results results/<ts>
import Foundation
import ArgumentParser

// --------------------------------------------------------------------------- #
// Shared paths + helpers
// --------------------------------------------------------------------------- #
enum Paths {
    static var tickets: URL { RepoRoot.ticketsDir }
    static var results: URL { RepoRoot.resultsDir }
    static var scratch: URL { RepoRoot.scratchDir }
}

func resolveTickets(_ spec: String) throws -> [URL] {
    let fm = FileManager.default
    if spec == "all" || spec == "*" || spec == "" {
        guard fm.fileExists(atPath: Paths.tickets.path),
              let entries = try? fm.contentsOfDirectory(at: Paths.tickets, includingPropertiesForKeys: nil)
        else { return [] }
        return entries.filter {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
        }.sorted { $0.path < $1.path }
    }
    var out: [URL] = []
    for raw in spec.split(separator: ",") {
        let tid = raw.trimmingCharacters(in: .whitespaces)
        if tid.isEmpty { continue }
        let p = Paths.tickets.appendingPathComponent(tid)
        if !fm.fileExists(atPath: p.path) {
            throw AxError("ticket not found: \(p.path)")
        }
        out.append(p)
    }
    return out
}

func optRepr(_ v: Double?) -> String { v.map { "\($0)" } ?? "None" }

// --------------------------------------------------------------------------- #
// run one cell
// --------------------------------------------------------------------------- #
func runCell(_ cfg: Config, ticketDir: URL, arm: String, runIndex: Int, outRoot: URL,
             runJudges: Bool, keepWorktree: Bool = false) -> Cell {
    let ticketId = ticketDir.lastPathComponent
    let runDir = outRoot.appendingPathComponent(ticketId).appendingPathComponent(arm)
        .appendingPathComponent("run-\(runIndex)")
    try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

    var cell = Cell(ticketId: ticketId, arm: arm, runIndex: runIndex, startedAt: Timestamp.now())
    cell.agentModel = cfg.models.agent
    var wt: Worktree?

    do {
        let prepared = try Sandbox.prepareWorktree(
            cfg, runDir: runDir, arm: arm, ticketId: ticketId, ticketDir: ticketDir
        )
        wt = prepared
        // PROD SAFETY: refuse to drive an agent in a worktree that can push.
        if cfg.sources.pushGuard && !Sandbox.assertPushDisabled(prepared) {
            throw AxError("push guard not active on worktree; aborting for prod safety")
        }
        cell.sandboxSeedSha = prepared.baseSha
        cell.axkitFlowSha = prepared.axkitFlowSha
        cell.artifacts = Artifacts(worktree: prepared.path.path)

        // --- Drive the agent ---
        let ar: AgentRunResult
        if arm == "baseline" {
            ar = ArmB.run(cfg, worktree: prepared.path, ticketId: ticketId, runDir: runDir)
            cell.contaminationDetected = !Sandbox.assertNoAxkitFlow(prepared)
        } else {
            ar = ArmA.run(cfg, worktree: prepared.path, ticketId: ticketId, runDir: runDir)
        }

        cell.artifacts.transcripts = ar.transcripts
        cell.artifacts.handoffSnapshots = ar.handoffSnapshots
        cell.efficiency = Telemetry.rollUp(ar.stages)
        cell.status = ["ok", "agent_error", "halted", "budget_exceeded"].contains(ar.status)
            ? ar.status : "ok"
        cell.error = ar.error

        // --- Handoff fidelity (Arm A only) ---
        if arm == "axkit-flow" {
            cell.handoff = HandoffEval.evaluate(
                prepared.path,
                terminalStageDone: ar.terminalDone,
                haltedStage: ar.haltedStage,
                haltStatus: ar.haltStatus,
                advanceCorrect: ar.advanceCorrect,
                resumeWorked: ar.resumeWorked
            )
            cell.handoff.stagesTotal = max(cell.handoff.stagesTotal, cfg.handoff.stages.count)
        }

        // --- Score quality (build/test/lint/judges) ---
        let (q, _, diffPath) = Pipeline.scoreWorktree(
            cfg, prepared, ticketDir: ticketDir, runDir: runDir,
            scratch: Paths.scratch.appendingPathComponent("judge"), runJudges: runJudges
        )
        cell.quality = q
        cell.artifacts.diff = diffPath
        if q.infraFailure && cell.status == "ok" {
            cell.status = "infra_error"
        }
    } catch {
        // Never let one cell kill the run.
        cell.status = "infra_error"
        cell.error = "\(error)"
    }

    // Tear down the (heavy) worktree unless asked to keep it for rescore.
    if let wt, !keepWorktree {
        Sandbox.teardown(cfg, wt)
        cell.artifacts.worktree = nil
    }

    cell.endedAt = Timestamp.now()
    let cellJSON = (try? AxJSON.encodeString(cell)) ?? "{}"
    try? cellJSON.write(to: runDir.appendingPathComponent("cell.json"), atomically: true, encoding: .utf8)
    return cell
}

// --------------------------------------------------------------------------- #
// Top-level command + subcommands
// --------------------------------------------------------------------------- #
@main
struct Axbench: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "axbench",
        abstract: "Benchmark axkit-flow multi-session handoff vs vanilla Claude Code on iOS tasks.",
        subcommands: [SelftestCommand.self, RunCommand.self, RescoreCommand.self,
                      AggregateCommand.self, ReportCommand.self]
    )
}

struct SelftestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "selftest", abstract: "validate instruments before spending budget")

    @Flag(name: .customLong("skip-judges")) var skipJudges = false
    @Flag(name: .customLong("check-build"),
          help: "also run a heavy pod-install smoke in a throwaway worktree")
    var checkBuild = false

    func run() throws {
        let cfg = try Config.load()
        let rep = Selftest.runSelftest(
            cfg, scratch: Paths.scratch.appendingPathComponent("selftest"),
            ticketsDir: Paths.tickets, skipJudges: skipJudges, checkBuild: checkBuild
        )
        print(rep.render())
        if !rep.ok { throw ExitCode(1) }
    }
}

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run", abstract: "run cells and produce a report")

    @Option var tickets = "all"
    @Option var arms = "axkit-flow,baseline"
    @Option var runs: Int?
    @Option(help: "results subdir name (default: timestamp)") var out: String?
    @Flag(name: .customLong("skip-judges")) var skipJudges = false
    @Flag(name: .customLong("no-selftest")) var noSelftest = false
    @Flag(name: .customLong("keep-worktrees"),
          help: "retain heavy worktrees for later build/test rescore")
    var keepWorktrees = false

    func run() throws {
        let cfg = try Config.load()
        let ticketDirs = try resolveTickets(tickets)
        if ticketDirs.isEmpty {
            throw AxError("no tickets to run (author one under tickets/ first)")
        }
        let armList = arms.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let n = runs ?? cfg.runsPerCell

        // Pre-flight unless explicitly skipped.
        if !noSelftest {
            let rep = Selftest.runSelftest(
                cfg, scratch: Paths.scratch.appendingPathComponent("selftest"),
                ticketsDir: Paths.tickets, skipJudges: skipJudges
            )
            print(rep.render())
            if !rep.ok {
                throw AxError("selftest failed; aborting before spending budget "
                    + "(use --no-selftest to override)")
            }
        }

        let outRoot = Paths.results.appendingPathComponent(out ?? Timestamp.stamp())
        try? FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)
        print("\n== axbench run → \(outRoot.path) ==")
        print("tickets=\(ticketDirs.map { $0.lastPathComponent }) arms=\(armList) runs=\(n)\n")

        for ticket in ticketDirs {
            for arm in armList {
                for k in 0..<n {
                    print("-- \(ticket.lastPathComponent) / \(arm) / run-\(k) --")
                    let cell = runCell(cfg, ticketDir: ticket, arm: arm, runIndex: k,
                                       outRoot: outRoot, runJudges: !skipJudges,
                                       keepWorktree: keepWorktrees)
                    let acc = optRepr(cell.quality.acceptancePassRate)
                    let cost = String(format: "%.3f", cell.efficiency.totalCostUsd)
                    let fidelity = optRepr(cell.handoff.fidelityScore)
                    print("   status=\(cell.status) build_ok=\(cell.quality.buildOk ? "True" : "False") "
                          + "acc=\(acc) cost=$\(cost) fidelity=\(fidelity)")
                }
            }
        }

        let agg = Aggregate.aggregate(outRoot)
        Report.writeReport(outRoot, agg)
        print("\nDone. Report: \(outRoot.appendingPathComponent("report.md").path)")
    }
}

struct RescoreCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "rescore",
        abstract: "re-run scorers on persisted worktrees (no agent re-run)")

    @Option var results: String
    @Flag(name: .customLong("skip-judges")) var skipJudges = false

    func run() throws {
        let cfg = try Config.load()
        let outRoot = URL(fileURLWithPath: results)
        let fm = FileManager.default
        var n = 0

        for cellPath in Aggregate.cellJSONPaths(outRoot) {
            let runDir = cellPath.deletingLastPathComponent()
            let wtPath = runDir.appendingPathComponent("worktree")
            guard let text = try? String(contentsOf: cellPath, encoding: .utf8),
                  let data = text.data(using: .utf8),
                  var cell = try? AxJSON.decoder.decode(Cell.self, from: data) else { continue }
            let ticketDir = Paths.tickets.appendingPathComponent(cell.ticketId)

            if fm.fileExists(atPath: wtPath.appendingPathComponent(".git").path) {
                // Full rescore: build/test/lint/judges on the retained worktree.
                let wt = Worktree(path: wtPath, arm: cell.arm, ticketId: cell.ticketId,
                                  baseSha: cell.sandboxSeedSha ?? "",
                                  starterCommit: try? Sandbox.gitSha(wtPath))
                let (q, _, diff) = Pipeline.scoreWorktree(
                    cfg, wt, ticketDir: ticketDir, runDir: runDir,
                    scratch: Paths.scratch.appendingPathComponent("judge"),
                    runJudges: !skipJudges
                )
                cell.quality = q
                cell.artifacts.diff = diff
                if cell.status == "ok" || cell.status == "infra_error" {
                    cell.status = q.infraFailure ? "infra_error" : "ok"
                }
                print("rescored(full) \(cell.ticketId)/\(cell.arm)/run-\(cell.runIndex): "
                      + "build_ok=\(cell.quality.buildOk ? "True" : "False") "
                      + "compl=\(optRepr(cell.quality.judgeCompleteness)) mvi=\(optRepr(cell.quality.judgeMvi))")
            } else if !skipJudges, let diff = cell.artifacts.diff,
                      fm.fileExists(atPath: diff) {
                // Worktree gone (torn down): re-run judges only, from the saved diff.
                let judgeScratch = Paths.scratch.appendingPathComponent("judge")
                try? fm.createDirectory(at: judgeScratch, withIntermediateDirectories: true)
                let codeText = (try? String(contentsOf: URL(fileURLWithPath: diff), encoding: .utf8)) ?? ""
                let jo = Judges.scoreCell(cfg, ticketDir: ticketDir, codeText: codeText,
                                          workdir: judgeScratch,
                                          transcriptsDir: runDir.appendingPathComponent("transcripts"))
                cell.quality.judgeCompleteness = jo.completeness
                cell.quality.judgeMvi = jo.mvi
                cell.quality.judgeValid = jo.valid
                print("rescored(judges) \(cell.ticketId)/\(cell.arm)/run-\(cell.runIndex): "
                      + "compl=\(optRepr(jo.completeness)) mvi=\(optRepr(jo.mvi))")
            } else {
                print("skip (no worktree, no diff): \(cellPath.path)")
                continue
            }

            let json = (try? AxJSON.encodeString(cell)) ?? "{}"
            try? json.write(to: cellPath, atomically: true, encoding: .utf8)
            n += 1
        }

        let agg = Aggregate.aggregate(outRoot, label: results)
        Report.writeReport(outRoot, agg)
        print("\nRescored \(n) cells. Report: \(outRoot.appendingPathComponent("report.md").path)")
    }
}

struct AggregateCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "aggregate", abstract: "aggregate cell.json into matrices")

    @Option var results: String

    func run() throws {
        let outRoot = URL(fileURLWithPath: results)
        let agg = Aggregate.aggregate(outRoot, label: results)
        print(PyJSON.dumps(agg))
    }
}

struct ReportCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "report", abstract: "render markdown/html report")

    @Option var results: String

    func run() throws {
        let outRoot = URL(fileURLWithPath: results)
        let agg = Aggregate.aggregate(outRoot, label: results)
        let path = Report.writeReport(outRoot, agg)
        print("Report written: \(path.path)")
    }
}

// Internal benchmark engine — the run / rescore / runCell loops.
//
// Drives every (task × variant × run) cell: prepare an isolated worktree, run the
// variant's Claude Code session, score the finished tree with the configured
// scorers, persist a `cell.json`, and stream `BenchEvent`s. No arm-string
// branching — a `Variant` value decides everything; the control variant is just
// the one flagged `control`, and deltas are computed against it downstream.
import Foundation

enum BenchEngine {
    static func optRepr(_ v: Double?) -> String { v.map { "\($0)" } ?? "None" }

    // MARK: One cell

    static func runCell(_ cfg: Config, workspace: CCWorkspace, task: BenchTask, variant: Variant,
                        runIndex: Int, forbiddenMounts: Set<String>, outRoot: URL,
                        runJudges: Bool, keepWorktree: Bool, streamAgentOutput: Bool = false,
                        emit: @escaping @Sendable (BenchEvent) -> Void) -> Cell {
        let runDir = outRoot.appendingPathComponent(task.id).appendingPathComponent(variant.id)
            .appendingPathComponent("run-\(runIndex)")
        try? FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)

        // Per-cell judge scratch dir so concurrent cells never share a judge workdir.
        let judgeScratch = workspace.judgeScratchDir.appendingPathComponent(task.id)
            .appendingPathComponent(variant.id).appendingPathComponent("run-\(runIndex)")

        var cell = Cell(taskId: task.id, variantId: variant.id, runIndex: runIndex,
                        startedAt: Timestamp.now())
        cell.agentModel = variant.model ?? cfg.models.agent
        cell.variantKind = variant.kind.rawValue
        var wt: Worktree?

        let onStep: @Sendable (StepTelemetry) -> Void = { tele in
            emit(.stepCompleted(taskID: task.id, variant: variant.id, runIndex: runIndex, step: tele))
        }
        var onEvent: (@Sendable (AgentStreamEvent) -> Void)?
        if streamAgentOutput {
            onEvent = { ev in
                emit(.agentStreamed(taskID: task.id, variant: variant.id, runIndex: runIndex, event: ev))
            }
        }

        do {
            let prepared = try Sandbox.prepareWorktree(cfg, runDir: runDir, task: task, variant: variant)
            wt = prepared
            // PROD SAFETY: refuse to drive an agent in a worktree that can push.
            if cfg.pushGuard && !Sandbox.assertPushDisabled(prepared) {
                throw CCError("push guard not active on worktree; aborting for safety")
            }
            cell.sandboxSeedSha = prepared.baseSha
            cell.variantMountSha = prepared.mountSha
            cell.artifacts = Artifacts(worktree: prepared.path.path)

            // --- Drive the agent ---
            let rr = Runner.run(cfg, variant: variant, task: task, worktree: prepared.path,
                                runDir: runDir, onStep: onStep, onEvent: onEvent)
            cell.artifacts.transcripts = rr.transcripts
            cell.efficiency = Telemetry.rollUp(rr.steps)
            cell.status = ["ok", "agent_error"].contains(rr.status) ? rr.status : "ok"
            cell.error = rr.error

            // Contamination guard: a control variant must carry no workflow mount.
            if variant.control {
                cell.contaminationDetected = !Sandbox.assertNoMounts(prepared, forbidden: forbiddenMounts)
            }

            // --- Score ---
            let ctx = ScoreContext(cfg: cfg, task: task, worktree: prepared, runDir: runDir,
                                   scratch: judgeScratch, runJudges: runJudges)
            let (q, diffPath) = ScorePipeline.scoreWorktree(ctx)
            cell.quality = q
            cell.artifacts.diff = diffPath
            cell.artifacts.verifyLog = FileManager.default.fileExists(
                atPath: runDir.appendingPathComponent("artifacts/verify.log").path
            ) ? runDir.appendingPathComponent("artifacts/verify.log").path : nil
            if q.infraFailure && cell.status == "ok" { cell.status = "infra_error" }
        } catch {
            cell.status = "infra_error"
            cell.error = "\(error)"
        }

        if let wt, !keepWorktree {
            Sandbox.teardown(task, wt)
            cell.artifacts.worktree = nil
        }

        cell.endedAt = Timestamp.now()
        let cellJSON = (try? CCJSON.encodeString(cell)) ?? "{}"
        try? cellJSON.write(to: runDir.appendingPathComponent("cell.json"), atomically: true, encoding: .utf8)
        return cell
    }

    // MARK: Full run

    static func run(_ plan: RunPlan, workspace: CCWorkspace, config cfg: Config,
                    emit: @escaping @Sendable (BenchEvent) -> Void) throws {
        let tasks = try Manifests.loadTasks(from: workspace.tasksDir, ids: plan.taskIDs)
        if tasks.isEmpty {
            throw CCError("no tasks to run (author one under \(workspace.tasksDir.path) first)")
        }
        let variants = try Manifests.loadVariants(from: workspace.variantsDir, ids: plan.variantIDs)
        if variants.isEmpty {
            throw CCError("no variants to run (author one under \(workspace.variantsDir.path) first)")
        }
        let n = plan.runsPerCell

        // Mounts used by non-control variants — a control worktree must have none.
        let forbiddenMounts = Set(variants.filter { !$0.control }.compactMap { $0.effectiveMountAs })

        if plan.selftestFirst {
            let rep = Selftest.runSelftest(cfg, scratch: workspace.selftestScratchDir,
                                           tasks: tasks, skipJudges: !plan.runJudges)
            emit(.log(rep.render()))
            if !rep.ok {
                throw CCError("selftest failed; aborting before spending budget "
                    + "(set RunPlan.selftestFirst = false to override)")
            }
        }

        let outRoot = workspace.resultsDir.appendingPathComponent(plan.outputName ?? Timestamp.stamp())
        try? FileManager.default.createDirectory(at: outRoot, withIntermediateDirectories: true)
        // Snapshot the variant set (incl. which is the control) for offline aggregation.
        let variantsMeta = variants.map { ["id": $0.id, "kind": $0.kind.rawValue, "control": $0.control] as [String: Any] }
        if let data = try? JSONSerialization.data(withJSONObject: variantsMeta, options: [.prettyPrinted]) {
            try? data.write(to: outRoot.appendingPathComponent("variants.json"))
        }
        let taskIDs = tasks.map { $0.id }, variantIDs = variants.map { $0.id }
        emit(.runStarted(tasks: taskIDs, variants: variantIDs, runs: n, resultsDir: outRoot))
        emit(.log("\n== ccbench run → \(outRoot.path) =="))
        emit(.log("tasks=\(taskIDs) variants=\(variantIDs) runs=\(n)\n"))

        // One cell's full lifecycle (start → run → finish). `@Sendable` so it can
        // run on a worker thread in the parallel path.
        let runOne: @Sendable (BenchTask, Variant, Int) -> Void = { task, variant, k in
            emit(.cellStarted(taskID: task.id, variant: variant.id, runIndex: k))
            emit(.log("-- \(task.id) / \(variant.id) / run-\(k) --"))
            let cell = runCell(cfg, workspace: workspace, task: task, variant: variant,
                               runIndex: k, forbiddenMounts: forbiddenMounts, outRoot: outRoot,
                               runJudges: plan.runJudges, keepWorktree: plan.keepWorktrees,
                               streamAgentOutput: plan.streamAgentOutput, emit: emit)
            let pass = optRepr(cell.quality.verifyPassRate)
            let cost = String(format: "%.3f", cell.efficiency.totalCostUsd)
            let adds = cell.quality.diff?.linesAdded ?? 0
            emit(.log("   status=\(cell.status) verify=\(pass) cost=$\(cost) +\(adds)LoC"))
            emit(.cellFinished(cell))
        }

        let maxConcurrent = max(1, cfg.maxConcurrentCells)
        if maxConcurrent <= 1 {
            // Strictly sequential — the historical path, unchanged.
            for task in tasks {
                for variant in variants {
                    for k in 0..<n {
                        try Task.checkCancellation()
                        runOne(task, variant, k)
                    }
                }
            }
        } else {
            // Bounded thread pool: cells are blocking subprocess work, so use a
            // semaphore + concurrent dispatch queue (not cooperative concurrency).
            // The emit sink (AsyncThrowingStream continuation) is thread-safe.
            let sem = DispatchSemaphore(value: maxConcurrent)
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "ccbench.cells", attributes: .concurrent)
            outer: for task in tasks {
                for variant in variants {
                    for k in 0..<n {
                        // Cancelling the consuming Task stops scheduling; in-flight
                        // cells run to completion.
                        do { try Task.checkCancellation() } catch { break outer }
                        sem.wait()
                        group.enter()
                        queue.async {
                            defer { sem.signal(); group.leave() }
                            runOne(task, variant, k)
                        }
                    }
                }
            }
            group.wait()
        }

        let agg = Aggregate.aggregate(outRoot)
        let md = Report.writeReport(outRoot, agg)
        emit(.log("\nDone. Report: \(md.path)"))
        emit(.runFinished(resultsDir: outRoot, reportMarkdown: md,
                          reportHTML: outRoot.appendingPathComponent("report.html")))
    }

    // MARK: Rescore

    static func rescore(resultsDir outRoot: URL, skipJudges: Bool, workspace: CCWorkspace,
                        config cfg: Config, emit: (BenchEvent) -> Void) throws {
        let fm = FileManager.default
        var count = 0
        // Task manifests are needed to re-run scorers (repo, hidden dir, verify cmd…).
        let allTasks = (try? Manifests.loadTasks(from: workspace.tasksDir, ids: ["all"])) ?? []
        var taskByID: [String: BenchTask] = [:]
        for t in allTasks { taskByID[t.id] = t }

        for cellPath in Aggregate.cellJSONPaths(outRoot) {
            try Task.checkCancellation()
            let runDir = cellPath.deletingLastPathComponent()
            let wtPath = runDir.appendingPathComponent("worktree")
            guard let data = try? Data(contentsOf: cellPath),
                  var cell = try? CCJSON.decoder.decode(Cell.self, from: data) else { continue }
            guard let task = taskByID[cell.taskId] else {
                emit(.log("skip (task manifest gone): \(cell.taskId)"))
                continue
            }

            if fm.fileExists(atPath: wtPath.appendingPathComponent(".git").path) {
                let wt = Worktree(path: wtPath, variantId: cell.variantId, taskId: cell.taskId,
                                  baseSha: cell.sandboxSeedSha ?? "", mountSha: cell.variantMountSha,
                                  starterCommit: try? Sandbox.gitSha(wtPath))
                let ctx = ScoreContext(cfg: cfg, task: task, worktree: wt, runDir: runDir,
                                       scratch: workspace.judgeScratchDir, runJudges: !skipJudges)
                let (q, diff) = ScorePipeline.scoreWorktree(ctx)
                cell.quality = q
                cell.artifacts.diff = diff
                if cell.status == "ok" || cell.status == "infra_error" {
                    cell.status = q.infraFailure ? "infra_error" : "ok"
                }
                emit(.log("rescored(full) \(cell.taskId)/\(cell.variantId)/run-\(cell.runIndex): "
                          + "verify=\(optRepr(q.verifyPassRate))"))
            } else if !skipJudges, let diff = cell.artifacts.diff, fm.fileExists(atPath: diff) {
                // Worktree gone: re-run judges only, from the saved diff.
                let wt = Worktree(path: wtPath, variantId: cell.variantId, taskId: cell.taskId,
                                  baseSha: cell.sandboxSeedSha ?? "", starterCommit: nil)
                let ctx = ScoreContext(cfg: cfg, task: task, worktree: wt, runDir: runDir,
                                       scratch: workspace.judgeScratchDir, runJudges: true)
                var q = cell.quality
                q.judges.removeAll(); q.judgeScaleMax.removeAll(); q.judgesValid = nil
                JudgeScorer().score(ctx, into: &q)
                cell.quality = q
                emit(.log("rescored(judges) \(cell.taskId)/\(cell.variantId)/run-\(cell.runIndex)"))
            } else {
                emit(.log("skip (no worktree, no diff): \(cellPath.path)"))
                continue
            }

            let json = (try? CCJSON.encodeString(cell)) ?? "{}"
            try? json.write(to: cellPath, atomically: true, encoding: .utf8)
            emit(.cellFinished(cell))
            count += 1
        }

        let agg = Aggregate.aggregate(outRoot, label: outRoot.path)
        let md = Report.writeReport(outRoot, agg)
        emit(.log("\nRescored \(count) cells. Report: \(md.path)"))
        emit(.runFinished(resultsDir: outRoot, reportMarkdown: md,
                          reportHTML: outRoot.appendingPathComponent("report.html")))
    }
}

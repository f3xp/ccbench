// Arm A — axkit-flow multi-session handoff, driven headlessly.
//
// Port of harness/arms/arm_a.py. Each stage runs in a *fresh process* (= fresh
// session). We start the first stage (`research`), then after each stage read
// `handoff.json` and use its `next.command` as the prompt for the next fresh
// process — exactly the copy-paste-into-a-new-chat workflow, automated. The loop
// ends when the terminal stage is done, a stage halts, or a budget guard trips.
import Foundation

enum ArmA {
    static let firstStageSkill = "axkit-flow/native/skills/research/SKILL.md"

    static func firstCommand(_ ticketId: String) -> String {
        "Load and follow \(firstStageSkill). "
            + "PRD: docs/features/\(ticketId)_PRD.md. "
            + "Run fully autonomously in headless mode: when a gate has a safe default, "
            + "take it and proceed; do not wait for user input."
    }

    static func snapshotHandoff(_ worktree: URL, runDir: URL, idx: Int) -> String? {
        guard let src = HandoffEval.findHandoff(worktree) else { return nil }
        let dest = runDir.appendingPathComponent("handoff_snapshots")
            .appendingPathComponent(String(format: "stage-%02d.json", idx))
        try? FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: dest)
        try? FileManager.default.copyItem(at: src, to: dest)
        return dest.path
    }

    static func run(_ cfg: Config, worktree: URL, ticketId: String, runDir: URL) -> AgentRunResult {
        var res = AgentRunResult(arm: "axkit-flow")
        let terminalStage = cfg.handoff.terminalStage
        let maxStages = cfg.budgets.maxStages
        let maxRunCost = cfg.budgets.maxCostUsdPerRun
        let stageTimeout = cfg.budgets.stageTimeoutS

        var cmd = firstCommand(ticketId)
        var seenSkills: [String] = []
        var totalCost = 0.0
        var brokeOut = false

        for idx in 1...maxStages {
            let out = ClaudeCLI.runClaude(
                cfg, prompt: cmd, workdir: worktree,
                model: cfg.models.agent,
                timeoutS: stageTimeout,
                transcriptPath: runDir.appendingPathComponent("transcripts")
                    .appendingPathComponent(String(format: "stage-%02d.json", idx)),
                effort: cfg.models.agentEffort,
                settingSources: "project"   // load axkit-flow by path from the worktree
            )
            let stageLabel = String(format: "stage-%02d", idx)
            let tele = Telemetry.stageTelemetry(stageLabel, out)
            res.stages.append(tele)
            res.transcripts.append(out.transcriptPath ?? "")
            totalCost += tele.costUsd
            if let snap = snapshotHandoff(worktree, runDir: runDir, idx: idx) {
                res.handoffSnapshots.append(snap)
            }

            // Hard failures end the run.
            if out.timedOut {
                res.status = "halted"
                res.haltedStage = HandoffEval.nextSkill(worktree) ?? stageLabel
                res.haltStatus = "TIMEOUT"
                res.resumeWorked = false
                brokeOut = true
                break
            }
            if out.isError {
                res.status = "agent_error"
                res.error = "stage \(idx) error: \(String(out.resultText.prefix(200)))"
                res.haltedStage = stageLabel
                res.haltStatus = "FAILED"
                brokeOut = true
                break
            }

            // Terminal detection: terminal stage marked done, or no next command.
            let data = HandoffEval.loadHandoff(worktree) ?? [:]
            let stages = (data["stages"] as? [String: Any]) ?? [:]
            let term = stages[terminalStage] as? [String: Any]
            let nxtIsNil = !(data["next"] is [String: Any])
            if (term?["status"] as? String) == "done" || nxtIsNil {
                res.terminalDone = true
                brokeOut = true
                break
            }

            let nxt = (data["next"] as? [String: Any]) ?? [:]
            let nextCmd = JSONVal.string(nxt["command"])
            let nextSkill = JSONVal.string(nxt["skill"])
            if nextCmd.isEmpty {
                res.status = "halted"
                res.haltedStage = nextSkill.isEmpty ? "after-\(stageLabel)" : nextSkill
                res.haltStatus = "NO_NEXT_COMMAND"
                brokeOut = true
                break
            }

            // Advance-correctness: the flow must move to a new stage each hop.
            if !nextSkill.isEmpty && seenSkills.contains(nextSkill) {
                res.advanceCorrect = false
                res.status = "halted"
                res.haltedStage = nextSkill
                res.haltStatus = "NO_ADVANCE"
                brokeOut = true
                break
            }
            if !nextSkill.isEmpty { seenSkills.append(nextSkill) }

            // Budget guard.
            if totalCost >= maxRunCost {
                res.status = "budget_exceeded"
                res.haltedStage = nextSkill.isEmpty ? nil : nextSkill
                res.haltStatus = "BUDGET"
                brokeOut = true
                break
            }

            cmd = nextCmd
        }

        if !brokeOut {
            // Loop exhausted max_stages without terminal.
            res.status = "halted"
            res.haltStatus = "MAX_STAGES"
        }

        return res
    }
}

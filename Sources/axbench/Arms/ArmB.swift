// Arm B — baseline: a single vanilla Claude Code session, no axkit-flow.
//
// Port of harness/arms/arm_b.py. The agent is given the ticket PRD and a
// high-effort iOS-engineer framing, and asked to implement the feature in one
// session. This is the fair control.
import Foundation

enum ArmB {
    static func run(_ cfg: Config, worktree: URL, ticketId: String, runDir: URL) -> AgentRunResult {
        var res = AgentRunResult(arm: "baseline")

        let prdPath = worktree.appendingPathComponent("docs/features/\(ticketId)_PRD.md")
        let prd = (try? String(contentsOf: prdPath, encoding: .utf8))
            ?? "Implement ticket \(ticketId)."
        let system = try? String(contentsOf: RepoRoot.baselineSystemPath, encoding: .utf8)

        let prompt = "Implement the feature described in the following ticket. Work directly in "
            + "this repository and make all the code changes needed. Do not run the app.\n\n"
            + prd

        let out = ClaudeCLI.runClaude(
            cfg, prompt: prompt, workdir: worktree,
            model: cfg.models.agent,
            timeoutS: cfg.budgets.baselineTimeoutS,
            transcriptPath: runDir.appendingPathComponent("transcripts/baseline.json"),
            effort: cfg.models.agentEffort,
            appendSystemPrompt: system,
            settingSources: "user"   // NO project settings, NO axkit-flow
        )
        res.transcripts.append(out.transcriptPath ?? "")
        res.stages.append(Telemetry.stageTelemetry("baseline", out))

        if out.timedOut {
            res.status = "agent_error"
            res.error = "baseline session timed out"
        } else if out.isError {
            res.status = "agent_error"
            res.error = "baseline session error: \(String(out.resultText.prefix(200)))"
        }
        return res
    }
}

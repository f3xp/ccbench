// Drive one Claude Code session for a (task, variant) pair.
//
// v1 is single-session: the variant shapes one `claude -p` invocation — what it
// mounts (handled by the sandbox), which setting-sources it loads, and how the
// prompt is primed. `vanilla` loads nothing (`--setting-sources user`); `skill`
// loads a mounted workflow (`--setting-sources project`); `spec` seeds the prompt.
// (Multi-session pipeline driving is a v2 concern.)
import Foundation

/// What a variant produced after driving the agent over one task.
struct RunResult {
    var steps: [StepTelemetry] = []
    var transcripts: [String] = []
    var status: String = "ok"        // ok | agent_error
    var error: String?
}

enum Runner {
    static func run(_ cfg: Config, variant: Variant, task: BenchTask, worktree: URL,
                    runDir: URL, onStep: (StepTelemetry) -> Void = { _ in }) -> RunResult {
        var res = RunResult()

        // Compose the prompt: variant spec file, then variant prefix, then the task prompt.
        var parts: [String] = []
        if let pf = variant.promptFile {
            let url = Manifests.resolve(pf, base: task.dir)
            if let text = try? String(contentsOf: url, encoding: .utf8) { parts.append(text) }
        }
        if let prefix = variant.promptPrefix, !prefix.isEmpty { parts.append(prefix) }
        parts.append(task.resolvedPrompt())
        let prompt = parts.joined(separator: "\n\n")

        let out = ClaudeCLI.runClaude(
            cfg, prompt: prompt, workdir: worktree,
            model: variant.model ?? cfg.models.agent,
            timeoutS: cfg.budgets.sessionTimeoutS,
            transcriptPath: runDir.appendingPathComponent("transcripts/session.json"),
            effort: variant.effort ?? cfg.models.agentEffort,
            appendSystemPrompt: variant.appendSystemPrompt,
            settingSources: variant.effectiveSettingSources,
            allowedTools: variant.allowedTools,
            disallowedTools: variant.disallowedTools
        )
        res.transcripts.append(out.transcriptPath ?? "")
        let tele = Telemetry.stepTelemetry("session", out)
        res.steps.append(tele)
        onStep(tele)

        if out.timedOut {
            res.status = "agent_error"
            res.error = "session timed out"
        } else if out.isError {
            res.status = "agent_error"
            res.error = "session error: \(String(out.resultText.prefix(200)))"
        }
        return res
    }
}

// Extract efficiency telemetry from claude CLI JSON envelopes.
//
// Port of harness/telemetry.py.
import Foundation

enum Telemetry {
    static func stageTelemetry(_ stage: String, _ res: ClaudeResult) -> StageTelemetry {
        let env = res.envelope
        let usage = (env["usage"] as? [String: Any]) ?? [:]
        var t = StageTelemetry(stage: stage)
        t.costUsd = JSONVal.double(env["total_cost_usd"])
        t.inputTokens = JSONVal.int(usage["input_tokens"])
        t.outputTokens = JSONVal.int(usage["output_tokens"])
        t.cacheReadTokens = JSONVal.int(usage["cache_read_input_tokens"])
        t.cacheCreationTokens = JSONVal.int(usage["cache_creation_input_tokens"])
        t.numTurns = JSONVal.int(env["num_turns"])
        t.durationS = res.wallClockS
        t.sessionId = env["session_id"] as? String
        t.isError = res.isError
        return t
    }

    static func rollUp(_ stages: [StageTelemetry]) -> Efficiency {
        var eff = Efficiency()
        eff.perStage = stages
        for s in stages {
            eff.totalCostUsd += s.costUsd
            eff.inputTokens += s.inputTokens
            eff.outputTokens += s.outputTokens
            eff.cacheReadTokens += s.cacheReadTokens
            eff.cacheCreationTokens += s.cacheCreationTokens
            eff.numTurns += s.numTurns
            eff.wallClockS += s.durationS
        }
        return eff
    }
}

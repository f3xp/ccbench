// Benchmark arms: how each technique drives the agent to build a feature.
//
// Port of harness/arms/__init__.py.
import Foundation

/// What an arm produced after driving the agent over one ticket.
struct AgentRunResult {
    var arm: String
    var stages: [StageTelemetry] = []
    var transcripts: [String] = []
    var handoffSnapshots: [String] = []

    // Outcome / control-flow signals consumed by HandoffEval.evaluate and the cell.
    var status: String = "ok"            // ok | agent_error | halted | budget_exceeded
    var error: String?
    var terminalDone: Bool = false
    var haltedStage: String?
    var haltStatus: String?
    var advanceCorrect: Bool = true
    var resumeWorked: Bool = true

    init(arm: String) { self.arm = arm }
}

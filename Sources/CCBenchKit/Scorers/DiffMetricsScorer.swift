// Ponytail's over-build signal: how much code did the agent actually write?
//
// Measures the git diff between the worktree's starter commit and the final tree
// (lines added/removed, files touched). Enabled by default; disable per task with
// `"scoring": { "diffMetrics": false }`.
import Foundation

struct DiffMetricsScorer: Scorer {
    let id = "diff-metrics"

    func applies(to task: BenchTask) -> Bool { task.scoring.diffMetrics ?? true }

    func score(_ ctx: ScoreContext, into q: inout Quality) {
        q.diff = Sandbox.diffMetrics(ctx.worktree)
    }
}

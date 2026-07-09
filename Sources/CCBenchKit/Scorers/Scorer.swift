// Pluggable scoring.
//
// A finished worktree is scored by a set of `Scorer`s, each contributing signals
// into a shared `Quality`. Deterministic scorers (verify, diff-metrics, golden)
// and the LLM `JudgeScorer` are independent, so a judge failure never discards a
// deterministic result. New scoring dimensions are added by implementing `Scorer`.
import Foundation

struct ScoreContext {
    let cfg: Config
    let task: BenchTask
    let worktree: Worktree
    let runDir: URL
    let scratch: URL
    let runJudges: Bool
}

protocol Scorer {
    var id: String { get }
    /// Whether this scorer is configured for the task.
    func applies(to task: BenchTask) -> Bool
    /// Contribute signals into `q`.
    func score(_ ctx: ScoreContext, into q: inout Quality)
}

enum ScorePipeline {
    /// The built-in scorers, in run order. Deterministic first, judges last.
    static func builtins(runJudges: Bool) -> [Scorer] {
        var scorers: [Scorer] = [
            VerifyCommandScorer(),
            DiffMetricsScorer(),
            GoldenDiffScorer(),
        ]
        if runJudges { scorers.append(JudgeScorer()) }
        return scorers
    }

    /// Score a finished worktree; returns (Quality, diffPath).
    static func scoreWorktree(_ ctx: ScoreContext) -> (Quality, String) {
        var q = Quality()
        let diffPath = Sandbox.writeDiff(
            ctx.worktree, dest: ctx.runDir.appendingPathComponent("artifacts/agent.diff")
        )
        for scorer in builtins(runJudges: ctx.runJudges) where scorer.applies(to: ctx.task) {
            scorer.score(ctx, into: &q)
        }
        return (q, diffPath)
    }
}

// Golden-output comparison: how close is the produced tree to a reference?
//
// Compares files under the task's `expectedDir` (task-relative) against the same
// paths in the finished worktree, byte-for-byte, and records the match rate.
// Useful for deterministic transform tasks where an exact target output exists.
import Foundation

struct GoldenDiffScorer: Scorer {
    let id = "golden"

    func applies(to task: BenchTask) -> Bool { task.scoring.golden != nil }

    func score(_ ctx: ScoreContext, into q: inout Quality) {
        guard let spec = ctx.task.scoring.golden else { return }
        let fm = FileManager.default
        let expected = Manifests.resolve(spec.expectedDir, base: ctx.task.dir)
        guard fm.fileExists(atPath: expected.path) else {
            q.notes.append("golden: expected dir not found: \(expected.path)")
            return
        }

        let rels: [String]
        if let files = spec.files {
            rels = files
        } else {
            var found: [String] = []
            if let en = fm.enumerator(at: expected, includingPropertiesForKeys: [.isDirectoryKey]) {
                for case let f as URL in en {
                    let isDir = (try? f.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true
                    if !isDir { found.append(String(f.path.dropFirst(expected.path.count + 1))) }
                }
            }
            rels = found.sorted()
        }

        var result = GoldenResult()
        var matches = 0
        for rel in rels {
            let want = (try? Data(contentsOf: expected.appendingPathComponent(rel)))
            let got = (try? Data(contentsOf: ctx.worktree.path.appendingPathComponent(rel)))
            if let want, let got, want == got {
                matches += 1
            } else {
                result.mismatched.append(rel)
            }
        }
        result.matchRate = rels.isEmpty ? 0 : Double(matches) / Double(rels.count)
        result.matched = result.mismatched.isEmpty && !rels.isEmpty
        q.golden = result
    }
}

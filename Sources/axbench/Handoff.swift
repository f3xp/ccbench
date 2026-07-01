// Read and score axkit-flow's multi-session handoff coordination file.
//
// Port of harness/handoff.py. handoff.json records, per stage, an artifact +
// its sha256 and (downstream) the upstream sha at the moment it was consumed.
// If an upstream file's current sha differs from what a downstream stage
// recorded, the upstream artifact drifted after being consumed.
import Foundation
import CryptoKit

enum HandoffEval {
    static func findHandoff(_ worktree: URL) -> URL? {
        let fm = FileManager.default
        let root = worktree.appendingPathComponent(".axkit/features")
        guard fm.fileExists(atPath: root.path) else { return nil }
        guard let subs = try? fm.contentsOfDirectory(
            at: root, includingPropertiesForKeys: nil
        ) else { return nil }
        let candidates = subs
            .map { $0.appendingPathComponent("handoff.json") }
            .filter { fm.fileExists(atPath: $0.path) }
            .sorted { $0.path < $1.path }
        return candidates.first
    }

    static func loadHandoff(_ worktree: URL) -> [String: Any]? {
        guard let p = findHandoff(worktree),
              let data = try? Data(contentsOf: p),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return obj
    }

    static func sha256File(_ path: URL) -> String? {
        guard let data = try? Data(contentsOf: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func resolve(_ worktree: URL, _ artifact: String) -> URL {
        artifact.hasPrefix("/")
            ? URL(fileURLWithPath: artifact)
            : worktree.appendingPathComponent(artifact)
    }

    static func evaluate(
        _ worktree: URL,
        terminalStageDone: Bool,
        haltedStage: String?,
        haltStatus: String?,
        advanceCorrect: Bool,
        resumeWorked: Bool
    ) -> Handoff {
        var h = Handoff()
        h.applicable = true
        h.advanceCorrect = advanceCorrect
        h.resumeWorked = resumeWorked
        h.haltedStage = haltedStage
        h.haltStatus = haltStatus

        guard let data = loadHandoff(worktree) else {
            h.contractValidRate = 0.0
            h.fidelityScore = 0.0
            return h
        }

        let stages = (data["stages"] as? [String: Any]) ?? [:]
        h.stagesTotal = stages.count

        var valid = 0
        for (name, stAny) in stages {
            var rec = HandoffStageRecord(stage: name)
            guard let st = stAny as? [String: Any] else {
                rec.issues.append("stage entry is not an object")
                h.perStage.append(rec)
                continue
            }
            rec.status = st["status"] as? String
            rec.artifact = st["artifact"] as? String

            var contractOK = true
            if rec.status == "done" {
                h.stagesCompleted += 1
                // A done stage must point at an artifact that exists (unless it's a
                // code-only stage like implement, which records branch/tasks instead).
                if let artifact = rec.artifact, !artifact.isEmpty {
                    let art = resolve(worktree, artifact)
                    let attrs = try? FileManager.default.attributesOfItem(atPath: art.path)
                    let size = (attrs?[.size] as? Int) ?? 0
                    if attrs == nil || size == 0 {
                        contractOK = false
                        rec.issues.append("artifact missing/empty")
                    } else {
                        rec.inputsResolved = true
                        // Own-sha integrity check.
                        if let sha = st["sha"] as? String, !sha.isEmpty {
                            if let cur = sha256File(art), cur != sha {
                                rec.issues.append("recorded sha != current sha")
                            }
                        }
                    }
                } else {
                    let branch = JSONVal.string(st["branch"])
                    let hasTasks = st["tasks_complete"] != nil
                    if branch.isEmpty && !hasTasks {
                        contractOK = false
                        rec.issues.append("done stage has neither artifact nor code markers")
                    }
                }
            }

            // Drift: any *_sha_at_creation must match the upstream's current sha.
            let suffix = "_sha_at_creation"
            for (key, valAny) in st where key.hasSuffix(suffix) {
                let upstream = String(key.dropLast(suffix.count))
                guard let up = stages[upstream] as? [String: Any],
                      let upArt = up["artifact"] as? String, !upArt.isEmpty else { continue }
                if let cur = sha256File(resolve(worktree, upArt)),
                   cur != JSONVal.string(valAny) {
                    rec.drift = true
                    rec.issues.append("upstream '\(upstream)' drifted since consumption")
                }
            }

            rec.contractValid = contractOK && rec.issues.isEmpty
            if rec.contractValid { valid += 1 }
            if rec.drift { h.driftCount += 1 }
            h.perStage.append(rec)
        }

        if !terminalStageDone, let nxt = data["next"] as? [String: Any],
           JSONVal.string(nxt["command"]).isEmpty {
            // Non-terminal handoff missing its next command is a contract breach.
            h.perStage.append(HandoffStageRecord(
                stage: "<next>", contractValid: false,
                issues: ["next.command missing on non-terminal handoff"]
            ))
            h.stagesTotal += 1
        }

        h.reachedTerminal = terminalStageDone
        h.contractValidRate = h.stagesTotal > 0 ? Double(valid) / Double(h.stagesTotal) : 0.0

        // Composite fidelity score in [0,1].
        let noDrift = h.driftCount == 0 ? 1.0 : 0.0
        h.fidelityScore = Stats.round(
            (h.contractValidRate ?? 0.0)
                * noDrift
                * (h.reachedTerminal ? 1.0 : 0.5)
                * (h.advanceCorrect ? 1.0 : 0.5)
                * (h.resumeWorked ? 1.0 : 0.5),
            4
        )
        return h
    }

    static func nextCommand(_ worktree: URL) -> String? {
        guard let data = loadHandoff(worktree),
              let nxt = data["next"] as? [String: Any] else { return nil }
        let cmd = JSONVal.string(nxt["command"])
        return cmd.isEmpty ? nil : cmd
    }

    static func nextSkill(_ worktree: URL) -> String? {
        guard let data = loadHandoff(worktree),
              let nxt = data["next"] as? [String: Any] else { return nil }
        let skill = JSONVal.string(nxt["skill"])
        return skill.isEmpty ? nil : skill
    }
}

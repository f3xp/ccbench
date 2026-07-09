// SwiftLint gate over agent-touched Swift files only.
//
// Port of scorers/lint.py.
import Foundation

struct LintResult {
    var available: Bool = false
    var violations: Int = 0
    var errors: Int = 0
    var warnings: Int = 0
    var message: String = ""
}

enum Lint {
    static func lint(_ cfg: Config, worktree: URL, touched: [String]) -> LintResult {
        if !Shell.which("swiftlint") {
            return LintResult(available: false, message: "swiftlint not installed")
        }

        let swiftFiles = touched.filter { $0.hasSuffix(".swift") }
        if swiftFiles.isEmpty {
            return LintResult(available: true, message: "no swift files touched")
        }

        var args = ["swiftlint", "lint", "--reporter", "json", "--quiet"]
        if let configRel = cfg.ios.swiftlintConfigRel {
            let configPath = worktree.appendingPathComponent(configRel)
            if FileManager.default.fileExists(atPath: configPath.path) {
                args += ["--config", configPath.path]
            }
        }
        args += swiftFiles.map { worktree.appendingPathComponent($0).path }

        guard let proc = try? Shell.run(args, cwd: worktree) else {
            return LintResult(available: true, message: "could not run swiftlint")
        }
        if proc.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return LintResult(available: true, violations: 0, message: "clean")
        }
        guard let data = proc.stdout.data(using: .utf8),
              let items = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return LintResult(available: true, message: "could not parse swiftlint output")
        }

        let errors = items.filter { ($0["severity"] as? String)?.lowercased() == "error" }.count
        let warnings = items.filter { ($0["severity"] as? String)?.lowercased() == "warning" }.count
        return LintResult(
            available: true,
            violations: items.count,
            errors: errors,
            warnings: warnings,
            message: "\(items.count) violations (\(errors) errors)"
        )
    }
}

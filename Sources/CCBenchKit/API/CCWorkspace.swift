// Filesystem locations the harness reads and writes.
//
// The macOS app constructs a `CCWorkspace` pointing at its own tasks / variants /
// results / scratch directories; the CLI uses `CCWorkspace.locate()` to walk up
// from the current working directory and anchor the standard layout.
import Foundation

public struct CCWorkspace: Sendable {
    /// Directory containing one subdirectory per task (`<id>/task.json` + assets).
    public var tasksDir: URL
    /// Directory containing one `<id>.json` variant manifest per variant.
    public var variantsDir: URL
    /// Root under which each run writes `<name>/<task>/<variant>/run-<k>/…`.
    public var resultsDir: URL
    /// Scratch root for worktree teardown, judge workdirs, selftest.
    public var scratchDir: URL

    public init(tasksDir: URL, variantsDir: URL, resultsDir: URL, scratchDir: URL) {
        self.tasksDir = tasksDir
        self.variantsDir = variantsDir
        self.resultsDir = resultsDir
        self.scratchDir = scratchDir
    }

    // MARK: Derived scratch subpaths (internal)

    var judgeScratchDir: URL { scratchDir.appendingPathComponent("judge") }
    var selftestScratchDir: URL { scratchDir.appendingPathComponent("selftest") }

    // MARK: CLI convenience

    /// Walk up from `start` (default: current working directory) to the repo root
    /// — the directory containing `Package.swift` — and anchor the standard
    /// `tasks/`, `variants/`, `results/`, `.scratch/` layout there.
    public static func locate(start: URL? = nil) -> CCWorkspace {
        let fm = FileManager.default
        var dir = start ?? URL(fileURLWithPath: fm.currentDirectoryPath)
        while true {
            if fm.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) { break }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }  // reached filesystem root
            dir = parent
        }
        return CCWorkspace(
            tasksDir: dir.appendingPathComponent("tasks"),
            variantsDir: dir.appendingPathComponent("variants"),
            resultsDir: dir.appendingPathComponent("results"),
            scratchDir: dir.appendingPathComponent(".scratch")
        )
    }
}

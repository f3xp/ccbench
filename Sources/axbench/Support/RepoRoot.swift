// Locate the repository root.
//
// The Python harness used `Path(__file__).resolve().parent` to anchor every
// relative path (config/, tickets/, results/, .scratch/, scorers/). A compiled
// Swift binary has no `__file__`, so we walk up from the current working
// directory looking for `config/bench.yaml`, falling back to CWD.
import Foundation

enum RepoRoot {
    static let url: URL = {
        let fm = FileManager.default
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        while true {
            if fm.fileExists(atPath: dir.appendingPathComponent("config/bench.yaml").path) {
                return dir
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }  // reached filesystem root
            dir = parent
        }
        return URL(fileURLWithPath: fm.currentDirectoryPath)
    }()

    static var ticketsDir: URL { url.appendingPathComponent("tickets") }
    static var resultsDir: URL { url.appendingPathComponent("results") }
    static var scratchDir: URL { url.appendingPathComponent(".scratch") }
    static var configPath: URL { url.appendingPathComponent("config/bench.yaml") }
    static var injectRB: URL { url.appendingPathComponent("scorers/inject_tests.rb") }
    static var baselineSystemPath: URL { url.appendingPathComponent("prompts/baseline_system.md") }
}

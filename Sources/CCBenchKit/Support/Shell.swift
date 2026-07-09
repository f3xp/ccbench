// Subprocess helper — the Swift analogue of Python's `subprocess.run(...)`.
//
// Every external tool the harness drives (`git`, `claude`, `xcodebuild`, `pod`,
// `ruby`, `xcrun`, `swiftlint`) is invoked through `Shell.run`. It captures
// stdout/stderr as UTF-8, honours a working directory + environment, and
// implements a watchdog timeout (Foundation.Process has no built-in one).
import Foundation

struct ProcessResult {
    var exitCode: Int32
    var stdout: String
    var stderr: String
    var timedOut: Bool
}

enum ShellError: Error, CustomStringConvertible {
    case launchFailed(String)
    case nonZeroExit(argv: [String], code: Int32, stderr: String)

    var description: String {
        switch self {
        case .launchFailed(let m): return "failed to launch: \(m)"
        case .nonZeroExit(let argv, let code, let stderr):
            return "command \(argv.first ?? "?") exited \(code): \(stderr)"
        }
    }
}

/// A tiny lock-guarded `Data` accumulator, so the streaming read loop can append
/// on its background queue without data-race warnings.
final class DataBox: @unchecked Sendable {
    private var buf = Data()
    private let lock = NSLock()
    func append(_ d: Data) { lock.lock(); buf.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buf }
}

enum Shell {
    /// Run a command to completion. Mirrors `subprocess.run(capture_output=True, text=True)`.
    ///
    /// - Parameters:
    ///   - check: when true, a non-zero exit throws `ShellError.nonZeroExit` (Python `check=True`).
    ///   - timeout: seconds; on expiry the process is terminated and `timedOut` is set.
    @discardableResult
    static func run(
        _ argv: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        check: Bool = false,
        timeout: Double? = nil
    ) throws -> ProcessResult {
        guard let first = argv.first else {
            throw ShellError.launchFailed("empty argv")
        }

        let proc = Process()
        // Resolve via /usr/bin/env so PATH lookup matches the Python behaviour.
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = argv
        if let cwd { proc.currentDirectoryURL = cwd }
        if let env { proc.environment = env }
        _ = first  // argv[0] is passed through env

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        // Drain pipes on background queues to avoid deadlock on large output.
        var outData = Data()
        var errData = Data()
        let outQ = DispatchQueue(label: "shell.out")
        let errQ = DispatchQueue(label: "shell.err")
        let group = DispatchGroup()

        do {
            try proc.run()
        } catch {
            throw ShellError.launchFailed(String(describing: error))
        }

        group.enter()
        outQ.async {
            outData = outPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        group.enter()
        errQ.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        var timedOut = false
        if let timeout {
            let deadline = DispatchTime.now() + timeout
            let watchdog = DispatchQueue(label: "shell.watchdog")
            let sem = DispatchSemaphore(value: 0)
            watchdog.async {
                proc.waitUntilExit()
                sem.signal()
            }
            if sem.wait(timeout: deadline) == .timedOut {
                timedOut = true
                proc.terminate()
                proc.waitUntilExit()
            }
        } else {
            proc.waitUntilExit()
        }

        group.wait()
        let stdout = String(data: outData, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let code = proc.terminationStatus

        if check && !timedOut && code != 0 {
            throw ShellError.nonZeroExit(argv: argv, code: code, stderr: stderr)
        }
        return ProcessResult(exitCode: code, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    /// Like `run`, but pumps stdout line-by-line to `onLine` as it arrives (for
    /// `claude --output-format stream-json`). The full stdout is still accumulated
    /// and returned, so callers can parse the final result afterward. stderr,
    /// timeout, and exit handling match `run`.
    @discardableResult
    static func runStreaming(
        _ argv: [String],
        cwd: URL? = nil,
        env: [String: String]? = nil,
        check: Bool = false,
        timeout: Double? = nil,
        onLine: @escaping @Sendable (String) -> Void
    ) throws -> ProcessResult {
        guard argv.first != nil else { throw ShellError.launchFailed("empty argv") }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = argv
        if let cwd { proc.currentDirectoryURL = cwd }
        if let env { proc.environment = env }

        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let outBox = DataBox()
        var errData = Data()
        let outQ = DispatchQueue(label: "shell.out.stream")
        let errQ = DispatchQueue(label: "shell.err")
        let group = DispatchGroup()

        do {
            try proc.run()
        } catch {
            throw ShellError.launchFailed(String(describing: error))
        }

        group.enter()
        outQ.async {
            let h = outPipe.fileHandleForReading
            var buffer = Data()
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }          // EOF
                outBox.append(chunk)
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let lineData = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if let line = String(data: lineData, encoding: .utf8) { onLine(line) }
                }
            }
            if !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8),
               !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                onLine(line)
            }
            group.leave()
        }
        group.enter()
        errQ.async {
            errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }

        var timedOut = false
        if let timeout {
            let deadline = DispatchTime.now() + timeout
            let watchdog = DispatchQueue(label: "shell.watchdog")
            let sem = DispatchSemaphore(value: 0)
            watchdog.async {
                proc.waitUntilExit()
                sem.signal()
            }
            if sem.wait(timeout: deadline) == .timedOut {
                timedOut = true
                proc.terminate()
                proc.waitUntilExit()
            }
        } else {
            proc.waitUntilExit()
        }

        group.wait()
        let stdout = String(data: outBox.data, encoding: .utf8) ?? ""
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        let code = proc.terminationStatus

        if check && !timedOut && code != 0 {
            throw ShellError.nonZeroExit(argv: argv, code: code, stderr: stderr)
        }
        return ProcessResult(exitCode: code, stdout: stdout, stderr: stderr, timedOut: timedOut)
    }

    /// True if `name` resolves on PATH (Python `shutil.which`).
    static func which(_ name: String) -> Bool {
        guard let res = try? run(["which", name]) else { return false }
        return res.exitCode == 0 && !res.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

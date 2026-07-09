// Small numeric + time helpers replacing Python's `statistics` and `datetime`.
import Foundation

enum Stats {
    /// Arithmetic mean (Python `statistics.fmean`). Returns nil for empty input.
    static func fmean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// Median (Python `statistics.median`): average of the two middle values for
    /// even counts. Returns nil for empty input.
    static func median(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        let s = values.sorted()
        let n = s.count
        if n % 2 == 1 { return s[n / 2] }
        return (s[n / 2 - 1] + s[n / 2]) / 2.0
    }

    /// Population standard deviation (Python `statistics.pstdev`).
    static func pstdev(_ values: [Double]) -> Double? {
        guard let m = fmean(values) else { return nil }
        let variance = values.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(values.count)
        return variance.squareRoot()
    }

    /// Round to `places` decimals (Python `round(x, n)`).
    static func round(_ x: Double, _ places: Int) -> Double {
        let f = pow(10.0, Double(places))
        return (x * f).rounded() / f
    }
}

enum Timestamp {
    private static func formatter(_ fmt: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = fmt
        return f
    }

    /// UTC ISO-ish timestamp, e.g. 2026-07-01T12:34:56Z (Python `_now`).
    static func now() -> String {
        formatter("yyyy-MM-dd'T'HH:mm:ss'Z'").string(from: Date())
    }

    /// Compact UTC stamp for directory names, e.g. 20260701-123456 (Python `_stamp`).
    static func stamp() -> String {
        formatter("yyyyMMdd-HHmmss").string(from: Date())
    }
}

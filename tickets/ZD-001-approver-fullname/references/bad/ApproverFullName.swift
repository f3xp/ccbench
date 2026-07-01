// BAD reference — plausible but wrong AND over-engineered. Introduces a needless
// global singleton formatter (architecture smell for pure value logic), and only
// end-trims so internal double spaces survive (fails S-003) and whitespace-only
// parts are not treated as missing (fails S-004).

final class ApproverNameFormatter {              // needless global mutable state
    static let shared = ApproverNameFormatter()
    func format(_ first: String?, _ last: String?) -> String {
        switch (first, last) {
            case let (.some(f), .some(l)):
                return "\(f) \(l)".trimmingCharacters(in: .whitespaces)  // internal "  " survives (S-003 fail)
            case let (.none, .some(l)): return l
            case let (.some(f), .none): return f
            case (.none, .none): return ""
        }
    }
}

public var fullName: String {
    ApproverNameFormatter.shared.format(firstName, lastName)
}

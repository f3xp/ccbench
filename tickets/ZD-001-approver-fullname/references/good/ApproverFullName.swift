// GOOD reference — pure, complete, idiomatic. Stays a computed property on the
// entity; handles trim, internal-whitespace collapse, and missing parts.

public var fullName: String {
    let raw = [firstName, lastName]
        .compactMap { $0 }
        .joined(separator: " ")
    // Splitting on any whitespace and re-joining trims ends (S-002), collapses
    // internal runs to one space (S-003), and drops whitespace-only parts (S-004).
    return raw
        .split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
}

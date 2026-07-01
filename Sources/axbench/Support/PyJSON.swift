// Minimal `json.dumps`-compatible serializer for the aggregate tree.
//
// Foundation's JSONSerialization renders an integral Double (3.0) as `3`, which
// diverges from Python's `json.dumps` (which keeps `3.0`). The aggregate stats
// distinguish Int counts (`n`, `runs`) from Double means, so we serialise the
// `[String: Any]` tree here with that distinction preserved — matching Python's
// output value-for-value.
import Foundation

enum PyJSON {
    static func dumps(_ obj: Any, indent: Int = 2, sortKeys: Bool = true) -> String {
        var out = ""
        write(obj, level: 0, indent: indent, sortKeys: sortKeys, into: &out)
        return out
    }

    private static func pad(_ level: Int, _ indent: Int) -> String {
        String(repeating: " ", count: level * indent)
    }

    private static func write(_ obj: Any, level: Int, indent: Int, sortKeys: Bool, into out: inout String) {
        switch obj {
        case is NSNull:
            out += "null"
        case let n as NSNumber where CFGetTypeID(n) == CFBooleanGetTypeID():
            out += n.boolValue ? "true" : "false"
        case let b as Bool:
            out += b ? "true" : "false"
        case let i as Int:
            out += String(i)
        case let d as Double:
            out += pyFloat(d)
        case let n as NSNumber:
            out += n.stringValue
        case let s as String:
            out += escape(s)
        case let arr as [Any]:
            if arr.isEmpty { out += "[]"; return }
            out += "[\n"
            for (idx, item) in arr.enumerated() {
                out += pad(level + 1, indent)
                write(item, level: level + 1, indent: indent, sortKeys: sortKeys, into: &out)
                out += idx == arr.count - 1 ? "\n" : ",\n"
            }
            out += pad(level, indent) + "]"
        case let dict as [String: Any]:
            if dict.isEmpty { out += "{}"; return }
            let keys = sortKeys ? dict.keys.sorted() : Array(dict.keys)
            out += "{\n"
            for (idx, key) in keys.enumerated() {
                out += pad(level + 1, indent) + escape(key) + ": "
                write(dict[key] as Any, level: level + 1, indent: indent, sortKeys: sortKeys, into: &out)
                out += idx == keys.count - 1 ? "\n" : ",\n"
            }
            out += pad(level, indent) + "}"
        default:
            out += "null"
        }
    }

    /// Render a Double like Python's `json`/`repr` (3.0 → "3.0", shortest round-trip).
    static func pyFloat(_ d: Double) -> String {
        if d == d.rounded() && abs(d) < 1e16 {
            return String(format: "%.1f", d)   // integral → "3.0"
        }
        return String(d)                       // Swift shortest round-trip matches Python repr
    }

    /// JSON string escaping matching Python's default (ensure_ascii=True).
    static func escape(_ s: String) -> String {
        var r = "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": r += "\\\""
            case "\\": r += "\\\\"
            case "\n": r += "\\n"
            case "\r": r += "\\r"
            case "\t": r += "\\t"
            default:
                if scalar.value < 0x20 || scalar.value > 0x7E {
                    r += String(format: "\\u%04x", scalar.value)
                } else {
                    r.unicodeScalars.append(scalar)
                }
            }
        }
        r += "\""
        return r
    }
}

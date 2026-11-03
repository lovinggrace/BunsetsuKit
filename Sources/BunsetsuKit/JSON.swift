// A small ordered JSON value, so that output matches ichiran's jsown output key order.

import Foundation

public indirect enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    /// Lisp NIL as encoded by jsown
    public static let nilValue = JSONValue.array([])

    public static func == (a: JSONValue, b: JSONValue) -> Bool {
        switch (a, b) {
        case (.null, .null): return true
        case (.bool(let x), .bool(let y)): return x == y
        case (.int(let x), .int(let y)): return x == y
        case (.string(let x), .string(let y)): return x == y
        case (.array(let x), .array(let y)): return x == y
        case (.object(let x), .object(let y)):
            return x.count == y.count && zip(x, y).allSatisfy { $0.0 == $1.0 && $0.1 == $1.1 }
        default: return false
        }
    }

    public subscript(key: String) -> JSONValue? {
        if case .object(let o) = self { return o.first { $0.0 == key }?.1 }
        return nil
    }

    public subscript(index: Int) -> JSONValue? {
        if case .array(let a) = self, index < a.count { return a[index] }
        return nil
    }

    public var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    public var intValue: Int? {
        if case .int(let i) = self { return i }
        return nil
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// Truthiness in the Lisp sense (NIL encoded as [] is false).
    var lispTrue: Bool {
        switch self {
        case .null, .bool(false): return false
        case .array(let a): return !a.isEmpty
        default: return true
        }
    }

    mutating func set(_ key: String, _ value: JSONValue) {
        guard case .object(var o) = self else { return }
        if let i = o.firstIndex(where: { $0.0 == key }) { o[i].1 = value } else { o.append((key, value)) }
        self = .object(o)
    }

    public func serialized() -> String {
        var out = ""
        write(&out)
        return out
    }

    private func write(_ out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .string(let s): JSONValue.writeString(s, &out)
        case .array(let a):
            out += "["
            for (i, v) in a.enumerated() {
                if i > 0 { out += "," }
                v.write(&out)
            }
            out += "]"
        case .object(let o):
            out += "{"
            for (i, (k, v)) in o.enumerated() {
                if i > 0 { out += "," }
                JSONValue.writeString(k, &out)
                out += ":"
                v.write(&out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, _ out: inout String) {
        out += "\""
        for c in s.unicodeScalars {
            switch c {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if c.value < 0x20 {
                    out += String(format: "\\u%04x", c.value)
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        out += "\""
    }
}

extension JSONValue: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}

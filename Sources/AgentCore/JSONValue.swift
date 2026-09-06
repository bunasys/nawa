import Foundation

/// A small, dependency-free JSON value type.
///
/// Swift's standard library ships no `JSON` value, so the agent domain defines
/// its own. It is used for tool arguments, tool input schemas, MCP/ACP params,
/// and anywhere the wire format is JSON. It is fully `Codable` in both
/// directions: numbers decode as `int` when integral, and encode losslessly.
public indirect enum JSON: Sendable, Hashable, Codable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: JSON].self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: container.codingPath, debugDescription: "Unsupported JSON value")
            )
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let v): try container.encode(v)
        case .int(let v): try container.encode(v)
        case .double(let v): try container.encode(v)
        case .string(let v): try container.encode(v)
        case .array(let v): try container.encode(v)
        case .object(let v): try container.encode(v)
        }
    }

    /// The value as a string, if it is one.
    public var stringValue: String? {
        if case .string(let v) = self { return v }
        return nil
    }

    /// The value as an int, if it is one.
    public var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    /// The value as a bool, if it is one.
    public var boolValue: Bool? {
        if case .bool(let v) = self { return v }
        return nil
    }

    /// The value as a `[String: JSON]`, if it is an object.
    public var objectValue: [String: JSON]? {
        if case .object(let v) = self { return v }
        return nil
    }

    /// The value as an array, if it is one.
    public var arrayValue: [JSON]? {
        if case .array(let v) = self { return v }
        return nil
    }

    /// Compact, valid JSON text representation.
    public var description: String {
        switch self {
        case .null: return "null"
        case .bool(let v): return v ? "true" : "false"
        case .int(let v): return String(v)
        case .double(let v): return String(v)
        case .string(let v): return "\"" + Self.escaped(v) + "\""
        case .array(let values): return "[" + values.map(\.description).joined(separator: ",") + "]"
        case .object(let dict):
            let pairs = dict.sorted { $0.key < $1.key }
                .map { "\"" + Self.escaped($0.key) + "\":" + $0.value.description }
            return "{" + pairs.joined(separator: ",") + "}"
        }
    }

    /// Escape a Swift string for embedding inside a JSON string literal.
    public static func escaped(_ string: String) -> String {
        var result = ""
        result.reserveCapacity(string.count)
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\\": result += "\\\\"
            case "\"": result += "\\\""
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                if scalar.value < 0x20 {
                    result += String(format: "\\u{%04X}", scalar.value)
                } else {
                    result.unicodeScalars.append(scalar)
                }
            }
        }
        return result
    }
}

extension JSON: CustomStringConvertible {}

/// Errors thrown by `JSON` decoding/encoding helpers.
public enum JSONError: Error, Sendable {
    case typeMismatch(expected: String, actual: JSON)
    case missingKey(String)
}

public extension JSON {
    /// Decode this JSON value into a `Decodable` type.
    func decode<T: Decodable>(_ type: T.Type) throws -> T {
        try JSONDecoder().decode(type, from: Data(description.utf8))
    }

    /// Encode an `Encodable` value into JSON.
    static func encode<T: Encodable>(_ value: T) throws -> JSON {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(JSON.self, from: data)
    }
}

import Foundation
import MCP

/// A decoded tool-call argument, domain-typed so the staging pipeline and
/// everything above it (planner, store, app layer) never see the MCP wire
/// representation (cleanup W1, audit §1.3). The write registry decodes
/// MCP `Value` into this once at its entry point; the app layer builds
/// these directly.
public enum ToolArgument: Hashable, Sendable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([ToolArgument])
    case object([String: ToolArgument])
}

/// The MCP boundary — the one place in the framework where the wire type
/// and the domain type meet. Internal: app-target code never converts; it
/// only ever receives or builds `ToolArgument`s.
extension ToolArgument {
    /// Nil for `data` values: tool arguments arrive JSON-decoded, which
    /// cannot carry binary, so a data-valued argument key has no domain
    /// image and the decoding registry drops it.
    init?(_ value: MCP.Value) {
        switch value {
        case .null: self = .null
        case .bool(let bool): self = .bool(bool)
        case .int(let int): self = .int(int)
        case .double(let double): self = .double(double)
        case .string(let string): self = .string(string)
        case .data: return nil
        case .array(let elements):
            var decoded: [ToolArgument] = []
            decoded.reserveCapacity(elements.count)
            for element in elements {
                guard let element = ToolArgument(element) else { return nil }
                decoded.append(element)
            }
            self = .array(decoded)
        case .object(let fields):
            var decoded: [String: ToolArgument] = [:]
            decoded.reserveCapacity(fields.count)
            for (name, value) in fields {
                guard let value = ToolArgument(value) else { return nil }
                decoded[name] = value
            }
            self = .object(decoded)
        }
    }
}

/// Accessors mirroring the MCP `Value` ones the argument parser already
/// uses, so `WriteRequest` keeps its exact failure messages and behavior.
extension ToolArgument {
    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var intValue: Int? {
        guard case .int(let value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        guard case .double(let value) = self else { return nil }
        return value
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var arrayValue: [ToolArgument]? {
        guard case .array(let value) = self else { return nil }
        return value
    }

    public var objectValue: [String: ToolArgument]? {
        guard case .object(let value) = self else { return nil }
        return value
    }
}

/// Convenience literals so call sites read like the MCP `Value` ones they
/// replaced (`["sceneId": .string(id)]`) — the app target builds staging
/// requests in exactly this shape.
extension ToolArgument: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral,
    ExpressibleByFloatLiteral, ExpressibleByBooleanLiteral, ExpressibleByArrayLiteral,
    ExpressibleByDictionaryLiteral
{
    public init(stringLiteral value: String) { self = .string(value) }
    public init(integerLiteral value: Int) { self = .int(value) }
    public init(floatLiteral value: Double) { self = .double(value) }
    public init(booleanLiteral value: Bool) { self = .bool(value) }

    public init(arrayLiteral elements: ToolArgument...) { self = .array(elements) }

    public init(dictionaryLiteral elements: (String, ToolArgument)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

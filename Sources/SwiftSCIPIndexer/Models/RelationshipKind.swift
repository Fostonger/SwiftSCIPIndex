import Foundation

/// Represents the kind of relationship between symbols
enum RelationshipKind: String, Codable, Sendable {
    case conforms = "conforms"
    case inherits = "inherits"
    case overrides = "overrides"
}


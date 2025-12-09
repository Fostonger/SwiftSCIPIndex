import Foundation

/// Represents a relationship between two symbols
struct SymbolRelationship: Codable, Sendable {
    let targetSymbolID: String
    let kind: RelationshipKind
}


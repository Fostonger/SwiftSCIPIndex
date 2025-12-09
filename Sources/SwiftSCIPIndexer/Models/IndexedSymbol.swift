import Foundation

/// Represents a symbol collected from the index store
struct IndexedSymbol: Codable, Sendable {
    let symbolID: String        // SCIP format: "swift Module Type#member."
    let name: String            // Human-readable name
    let kind: SymbolKind        // .class, .struct, .protocol, .function, etc.
    let module: String?
    let documentation: [String]
    let relationships: [SymbolRelationship]
}


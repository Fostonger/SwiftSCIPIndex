import Foundation

/// Represents an occurrence of a symbol in source code
struct IndexedOccurrence: Codable, Sendable {
    let symbolID: String
    let filePath: String        // Relative to project root
    let range: SourceRange
    let role: SCIPSymbolRole
    let snippet: String?
    let enclosingSymbol: String?
    let enclosingName: String?
}

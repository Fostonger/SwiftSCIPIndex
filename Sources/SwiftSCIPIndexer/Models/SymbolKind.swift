import Foundation

/// Represents the kind of a symbol in the index
enum SymbolKind: String, Codable, Sendable {
    case `class` = "class"
    case `struct` = "struct"
    case `protocol` = "protocol"
    case `enum` = "enum"
    case function = "function"
    case property = "property"
    case enumCase = "enumCase"
    case typeAlias = "typeAlias"
    case local = "local"
    case unknown = "unknown"
}


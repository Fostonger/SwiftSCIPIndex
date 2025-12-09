import Foundation

/// Bitmask representing the role of a symbol occurrence in SCIP format
struct SCIPSymbolRole: OptionSet, Codable, Sendable {
    let rawValue: Int
    
    static let definition = SCIPSymbolRole(rawValue: 1)
    static let `import` = SCIPSymbolRole(rawValue: 2)
    static let writeAccess = SCIPSymbolRole(rawValue: 4)
    static let readAccess = SCIPSymbolRole(rawValue: 8)
    static let reference = SCIPSymbolRole(rawValue: 8)  // Alias for readAccess
    static let generated = SCIPSymbolRole(rawValue: 16)
    static let test = SCIPSymbolRole(rawValue: 32)
}

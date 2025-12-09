import Foundation

/// Builds SCIP-compatible symbol IDs from IndexStoreDB symbols
struct SCIPSymbolBuilder {
    
    /// Build SCIP symbol ID from IndexStoreDB symbol
    /// - Parameters:
    ///   - usr: Unified Symbol Resolution from compiler
    ///   - name: Human-readable name
    ///   - kind: Symbol kind
    ///   - module: Module/target name
    /// - Returns: SCIP-formatted symbol ID
    static func buildSymbolID(
        usr: String,
        name: String,
        kind: SymbolKind,
        module: String?
    ) -> String {
        // Local symbols don't have a proper USR starting with s:
        if !usr.hasPrefix("s:") || module == nil {
            return "local \(abs(usr.hashValue))"
        }
        
        let moduleName = module ?? "Unknown"
        let suffix = kindSuffix(for: kind)
        
        // Build descriptor chain
        // For nested types: "swift Module OuterType#InnerType#"
        // For methods: "swift Module Type#method()."
        
        return "swift \(moduleName) \(name)\(suffix)"
    }
    
    /// Build SCIP symbol ID with full path context
    /// - Parameters:
    ///   - usr: Unified Symbol Resolution from compiler
    ///   - name: Human-readable name
    ///   - kind: Symbol kind
    ///   - module: Module/target name
    ///   - containerName: Name of containing type (if any)
    /// - Returns: SCIP-formatted symbol ID
    static func buildSymbolID(
        usr: String,
        name: String,
        kind: SymbolKind,
        module: String?,
        containerName: String?
    ) -> String {
        // Local symbols don't have a proper USR starting with s:
        if !usr.hasPrefix("s:") || module == nil {
            return "local \(abs(usr.hashValue))"
        }
        
        let moduleName = module ?? "Unknown"
        let suffix = kindSuffix(for: kind)
        
        // Build full symbol path
        if let container = containerName, !container.isEmpty {
            return "swift \(moduleName) \(container)#\(name)\(suffix)"
        }
        
        return "swift \(moduleName) \(name)\(suffix)"
    }
    
    /// Get the SCIP suffix for a symbol kind
    /// - Parameter kind: The symbol kind
    /// - Returns: The appropriate SCIP suffix
    private static func kindSuffix(for kind: SymbolKind) -> String {
        switch kind {
        case .class, .struct, .protocol, .enum, .typeAlias:
            return "#"
        case .function:
            return "()."
        case .property, .enumCase:
            return "."
        case .local, .unknown:
            return ""
        }
    }
}


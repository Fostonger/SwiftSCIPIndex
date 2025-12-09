import Foundation
import IndexStoreDB

// Re-export SymbolRole to avoid ambiguity with our SCIPSymbolRole
// The IndexStoreDB.SymbolRole is directly available as SymbolRole
// but we create an alias for clarity in mapping functions

/// Reads symbol and occurrence data from Xcode's index store
final class IndexStoreReader {
    private let indexStore: IndexStoreDB
    private let projectRoot: URL
    private let includeSnippets: Bool
    
    /// Initialize the index store reader
    /// - Parameters:
    ///   - derivedDataPath: Path to the DerivedData directory
    ///   - projectRoot: Root path of the project
    ///   - includeSnippets: Whether to extract code snippets for occurrences
    init(derivedDataPath: URL, projectRoot: URL, includeSnippets: Bool = true) throws {
        // IndexStoreDB expects the path to the DataStore directory
        let storePath = Self.findIndexStorePath(in: derivedDataPath)
        
        guard FileManager.default.fileExists(atPath: storePath.path) else {
            throw IndexStoreReaderError.indexStoreNotFound(path: storePath.path)
        }
        
        // Create temporary database path for IndexStoreDB
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-scip-\(UUID().uuidString)")
        
        try FileManager.default.createDirectory(at: dbPath, withIntermediateDirectories: true)
        
        self.indexStore = try IndexStoreDB(
            storePath: storePath.path,
            databasePath: dbPath.path,
            library: nil,  // Uses system libIndexStore
            waitUntilDoneInitializing: true
        )
        self.projectRoot = projectRoot
        self.includeSnippets = includeSnippets
    }
    
    /// Find all symbols in the index store
    func collectSymbols() -> [IndexedSymbol] {
        var symbols: [IndexedSymbol] = []
        var seenUSRs: Set<String> = []
        
        indexStore.forEachCanonicalSymbolOccurrence(
            containing: "",
            anchorStart: false,
            anchorEnd: false,
            subsequence: true,
            ignoreCase: true
        ) { occurrence in
            let symbol = occurrence.symbol
            let usr = symbol.usr
            
            // Skip if we've already seen this symbol
            guard !seenUSRs.contains(usr) else {
                return true  // Continue iteration
            }
            seenUSRs.insert(usr)
            
            // Convert to our model
            let kind = Self.mapSymbolKind(symbol.kind)
            let module = Self.extractModule(from: usr)
            
            let symbolID = SCIPSymbolBuilder.buildSymbolID(
                usr: usr,
                name: symbol.name,
                kind: kind,
                module: module
            )
            
            // Collect relationships
            var relationships: [SymbolRelationship] = []
            
            // Check for base types/protocols
            for relation in occurrence.relations {
                if let relKind = Self.mapRelationshipKind(relation.roles) {
                    let relatedSymbol = relation.symbol
                    let relatedModule = Self.extractModule(from: relatedSymbol.usr)
                    let relatedKind = Self.mapSymbolKind(relatedSymbol.kind)
                    let targetID = SCIPSymbolBuilder.buildSymbolID(
                        usr: relatedSymbol.usr,
                        name: relatedSymbol.name,
                        kind: relatedKind,
                        module: relatedModule
                    )
                    relationships.append(SymbolRelationship(
                        targetSymbolID: targetID,
                        kind: relKind
                    ))
                }
            }
            
            let indexedSymbol = IndexedSymbol(
                symbolID: symbolID,
                name: symbol.name,
                kind: kind,
                module: module,
                documentation: [],  // Documentation not available from index store
                relationships: relationships
            )
            
            symbols.append(indexedSymbol)
            return true  // Continue iteration
        }
        
        return symbols
    }
    
    /// Find all occurrences for a set of files
    /// - Parameter files: File paths to filter (relative to project root), or nil for all files
    func collectOccurrences(forFiles files: [String]?) -> [IndexedOccurrence] {
        var occurrences: [IndexedOccurrence] = []
        var seenUSRs: Set<String> = []
        
        // First collect all unique USRs
        indexStore.forEachCanonicalSymbolOccurrence(
            containing: "",
            anchorStart: false,
            anchorEnd: false,
            subsequence: true,
            ignoreCase: true
        ) { occurrence in
            seenUSRs.insert(occurrence.symbol.usr)
            return true
        }
        
        // Then collect occurrences for each USR
        for usr in seenUSRs {
            indexStore.forEachSymbolOccurrence(byUSR: usr, roles: .all) { occurrence in
                let location = occurrence.location
                let filePath = location.path
                
                // Compute relative path
                let relativePath: String
                if filePath.hasPrefix(projectRoot.path) {
                    relativePath = String(filePath.dropFirst(projectRoot.path.count + 1))
                } else {
                    relativePath = filePath
                }
                
                // Filter by files if specified
                if let files = files, !files.contains(relativePath) {
                    return true  // Continue to next occurrence
                }
                
                // Skip non-Swift files
                guard relativePath.hasSuffix(".swift") else {
                    return true
                }
                
                let symbol = occurrence.symbol
                let kind = Self.mapSymbolKind(symbol.kind)
                let module = Self.extractModule(from: symbol.usr)
                
                let symbolID = SCIPSymbolBuilder.buildSymbolID(
                    usr: symbol.usr,
                    name: symbol.name,
                    kind: kind,
                    module: module
                )
                
                let role = Self.mapSymbolRoles(occurrence.roles)
                
                // Extract snippet if enabled
                let snippet: String?
                if includeSnippets {
                    let fileURL = URL(fileURLWithPath: filePath)
                    snippet = SnippetExtractor.extractLine(
                        file: fileURL,
                        line: location.line - 1  // Convert 1-indexed to 0-indexed
                    )
                } else {
                    snippet = nil
                }
                
                // Get enclosing symbol info
                var enclosingSymbol: String? = nil
                var enclosingName: String? = nil
                
                for relation in occurrence.relations {
                    if relation.roles.contains(.childOf) {
                        let enclosing = relation.symbol
                        let enclosingKind = Self.mapSymbolKind(enclosing.kind)
                        let enclosingModule = Self.extractModule(from: enclosing.usr)
                        enclosingSymbol = SCIPSymbolBuilder.buildSymbolID(
                            usr: enclosing.usr,
                            name: enclosing.name,
                            kind: enclosingKind,
                            module: enclosingModule
                        )
                        enclosingName = enclosing.name
                        break
                    }
                }
                
                // Create source range (IndexStoreDB uses 1-indexed lines, SCIP uses 0-indexed)
                let range = SourceRange(
                    startLine: location.line - 1,
                    startColumn: location.utf8Column - 1,
                    endLine: location.line - 1,
                    endColumn: location.utf8Column - 1 + symbol.name.utf8.count
                )
                
                let indexedOccurrence = IndexedOccurrence(
                    symbolID: symbolID,
                    filePath: relativePath,
                    range: range,
                    role: role,
                    snippet: snippet,
                    enclosingSymbol: enclosingSymbol,
                    enclosingName: enclosingName
                )
                
                occurrences.append(indexedOccurrence)
                return true  // Continue iteration
            }
        }
        
        return occurrences
    }
    
    /// Find relationships (inheritance, conformances)
    func collectRelationships() -> [SymbolRelationship] {
        var relationships: [SymbolRelationship] = []
        
        indexStore.forEachCanonicalSymbolOccurrence(
            containing: "",
            anchorStart: false,
            anchorEnd: false,
            subsequence: true,
            ignoreCase: true
        ) { occurrence in
            for relation in occurrence.relations {
                if let kind = Self.mapRelationshipKind(relation.roles) {
                    let relatedSymbol = relation.symbol
                    let relatedModule = Self.extractModule(from: relatedSymbol.usr)
                    let relatedKind = Self.mapSymbolKind(relatedSymbol.kind)
                    let targetID = SCIPSymbolBuilder.buildSymbolID(
                        usr: relatedSymbol.usr,
                        name: relatedSymbol.name,
                        kind: relatedKind,
                        module: relatedModule
                    )
                    relationships.append(SymbolRelationship(
                        targetSymbolID: targetID,
                        kind: kind
                    ))
                }
            }
            return true
        }
        
        return relationships
    }
    
    // MARK: - Private Helpers
    
    /// Find the index store path within DerivedData
    private static func findIndexStorePath(in derivedData: URL) -> URL {
        // Try Index.noindex/DataStore first (Xcode 14+)
        let noindexPath = derivedData
            .appendingPathComponent("Index.noindex")
            .appendingPathComponent("DataStore")
        
        if FileManager.default.fileExists(atPath: noindexPath.path) {
            return noindexPath
        }
        
        // Fall back to Index/DataStore
        return derivedData
            .appendingPathComponent("Index")
            .appendingPathComponent("DataStore")
    }
    
    /// Map IndexStoreDB symbol kind to our SymbolKind
    private static func mapSymbolKind(_ kind: IndexSymbolKind) -> SymbolKind {
        switch kind {
        case .class:
            return .class
        case .struct:
            return .struct
        case .protocol:
            return .protocol
        case .enum:
            return .enum
        case .instanceMethod, .classMethod, .staticMethod, .function:
            return .function
        case .instanceProperty, .classProperty, .staticProperty, .variable:
            return .property
        case .enumConstant:
            return .enumCase
        case .typealias:
            return .typeAlias
        case .parameter:
            return .local
        default:
            return .unknown
        }
    }
    
    /// Map IndexStoreDB roles to our SCIPSymbolRole
    private static func mapSymbolRoles(_ roles: SymbolRole) -> SCIPSymbolRole {
        var result = SCIPSymbolRole()
        
        if roles.contains(SymbolRole.definition) || roles.contains(SymbolRole.declaration) {
            result.insert(.definition)
        }
        if roles.contains(SymbolRole.reference) {
            result.insert(.reference)
        }
        if roles.contains(SymbolRole.read) {
            result.insert(.readAccess)
        }
        if roles.contains(SymbolRole.write) {
            result.insert(.writeAccess)
        }
        
        // Default to reference if no role is set
        if result.isEmpty {
            result.insert(.reference)
        }
        
        return result
    }
    
    /// Map IndexStoreDB relation roles to RelationshipKind
    private static func mapRelationshipKind(_ roles: SymbolRole) -> RelationshipKind? {
        if roles.contains(SymbolRole.baseOf) {
            return .inherits
        }
        if roles.contains(SymbolRole.overrideOf) {
            return .overrides
        }
        // Protocol conformance is typically expressed through baseOf as well
        return nil
    }
    
    /// Extract module name from USR
    private static func extractModule(from usr: String) -> String? {
        // USR format: s:ModuleName...
        // Try to extract the module name from the USR
        guard usr.hasPrefix("s:") else {
            return nil
        }
        
        // Simple heuristic: first component after s: until next type marker
        let afterPrefix = String(usr.dropFirst(2))
        
        // Find the first digit which typically indicates the start of a mangled name
        if let digitIndex = afterPrefix.firstIndex(where: { $0.isNumber }) {
            let lengthStr = String(afterPrefix[afterPrefix.startIndex..<digitIndex])
            if let length = Int(lengthStr), length > 0 {
                let nameStart = afterPrefix.index(after: digitIndex)
                if afterPrefix.distance(from: nameStart, to: afterPrefix.endIndex) >= length - 1 {
                    let nameEnd = afterPrefix.index(nameStart, offsetBy: length - 1)
                    return String(afterPrefix[digitIndex...nameEnd])
                }
            }
        }
        
        return nil
    }
}

// MARK: - Errors

enum IndexStoreReaderError: Error, LocalizedError {
    case indexStoreNotFound(path: String)
    case libIndexStoreNotFound
    
    var errorDescription: String? {
        switch self {
        case .indexStoreNotFound(let path):
            return "Index store not found at: \(path). Make sure to build the project first with indexing enabled."
        case .libIndexStoreNotFound:
            return "libIndexStore not found. Make sure Xcode or Command Line Tools are installed."
        }
    }
}

import Foundation

/// Writes SCIP index data to JSON format
struct SCIPJSONWriter {
    
    // MARK: - SCIP Output Types
    
    struct SCIPOutput: Codable {
        let metadata: Metadata
        let documents: [Document]
        
        struct Metadata: Codable {
            let version: Int
            let toolInfo: ToolInfo
            let projectRoot: String
            let textDocumentEncoding: String
            
            struct ToolInfo: Codable {
                let name: String
                let version: String
            }
        }
        
        struct Document: Codable {
            let relativePath: String
            let language: String
            let symbols: [SymbolInfo]
            let occurrences: [OccurrenceInfo]
        }
        
        struct SymbolInfo: Codable {
            let symbol: String
            let kind: String?
            let documentation: [String]?
            let relationships: [RelationshipInfo]?
        }
        
        struct RelationshipInfo: Codable {
            let symbol: String
            let isImplementation: Bool?
            let isReference: Bool?
            let isTypeDefinition: Bool?
        }
        
        struct OccurrenceInfo: Codable {
            let symbol: String
            let range: [Int]
            let symbolRoles: Int
            let enclosingSymbol: String?
            let snippet: String?
        }
    }
    
    // MARK: - Writing
    
    /// Write SCIP index to JSON file
    /// - Parameters:
    ///   - symbols: All collected symbols
    ///   - occurrences: All collected occurrences
    ///   - projectRoot: Root path of the project
    ///   - outputPath: Path to write the JSON output
    static func write(
        symbols: [IndexedSymbol],
        occurrences: [IndexedOccurrence],
        projectRoot: URL,
        to outputPath: URL
    ) throws {
        // Group occurrences by file
        let grouped = Dictionary(grouping: occurrences, by: \.filePath)
        
        // Build a lookup table for symbols by ID (unused but available for future use)
        _ = Dictionary(uniqueKeysWithValues: symbols.map { ($0.symbolID, $0) })
        
        // Build documents
        let documents = grouped.map { (path, occs) -> SCIPOutput.Document in
            // Get symbols that have definitions in this file
            let fileSymbols = symbols.filter { sym in
                occs.contains { $0.symbolID == sym.symbolID && $0.role.contains(.definition) }
            }
            
            return SCIPOutput.Document(
                relativePath: path,
                language: "swift",
                symbols: fileSymbols.map { sym in
                    SCIPOutput.SymbolInfo(
                        symbol: sym.symbolID,
                        kind: sym.kind.rawValue,
                        documentation: sym.documentation.isEmpty ? nil : sym.documentation,
                        relationships: sym.relationships.isEmpty ? nil : sym.relationships.map { rel in
                            SCIPOutput.RelationshipInfo(
                                symbol: rel.targetSymbolID,
                                isImplementation: rel.kind == .conforms || rel.kind == .overrides,
                                isReference: nil,
                                isTypeDefinition: rel.kind == .inherits
                            )
                        }
                    )
                },
                occurrences: occs.map { occ in
                    SCIPOutput.OccurrenceInfo(
                        symbol: occ.symbolID,
                        range: occ.range.asSCIPRange,
                        symbolRoles: occ.role.rawValue,
                        enclosingSymbol: occ.enclosingSymbol,
                        snippet: occ.snippet
                    )
                }
            )
        }
        
        let output = SCIPOutput(
            metadata: .init(
                version: 1,
                toolInfo: .init(name: "swift-scip-indexer", version: "1.0.0"),
                projectRoot: "file://\(projectRoot.path)",
                textDocumentEncoding: "UTF-8"
            ),
            documents: documents.sorted { $0.relativePath < $1.relativePath }
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(output)
        
        // Create parent directory if needed
        try FileManager.default.createDirectory(
            at: outputPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        
        try data.write(to: outputPath)
    }
}


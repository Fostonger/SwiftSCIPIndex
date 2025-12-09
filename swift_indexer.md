# Swift SCIP Indexer Implementation Plan

A standalone Swift CLI tool that produces SCIP-compatible index files from Xcode's DerivedData, enabling code intelligence features (go-to-definition, find-references, find-implementations) in the GraphRAG system.

## Table of Contents

1. [Overview](#overview)
2. [Current System Architecture](#current-system-architecture)
3. [SCIP Protocol Specification](#scip-protocol-specification)
4. [Swift Indexer Requirements](#swift-indexer-requirements)
5. [Dependencies](#dependencies)
6. [Implementation Details](#implementation-details)
7. [Package.swift](#packageswift)
8. [CLI Interface](#cli-interface)
9. [Testing Strategy](#testing-strategy)

---

## Overview

### Goals

1. **SCIP Compatibility**: Output must be compatible with Sourcegraph's SCIP format (JSON serialization of protobuf schema)
2. **Swift Executable**: Standalone CLI tool built with Swift Package Manager
3. **DerivedData Integration**: Read Xcode's index store from custom DerivedData paths
4. **Git-Aware**: Only re-index files that changed since last indexing run
5. **Language Extensibility**: Same output schema used by future language indexers (TypeScript, Kotlin, etc.)

### Why a Native Swift Indexer?

- Direct access to Apple's `IndexStoreDB` library (the same backing SourceKit-LSP)
- No external dependencies on Python or other runtimes in CI/CD
- Accurate Swift semantics (generics, extensions, protocol conformances)
- Fast incremental updates via git status awareness

---

## Current System Architecture

### How the GraphRAG System Consumes SCIP Data

The system expects SCIP data in JSON format. The Python side reads and imports it:

```python
# From src/graphrag/indexer/scip_reader.py

def load_scip_index(path: Path) -> ScipIndex:
    """Load a SCIP index from a JSON file."""
    with open(path, "r") as f:
        data = json.load(f)
    return parse_scip_json(data)
```

### Database Schema (Target Output)

The SCIP data is stored in three SQLite tables:

#### `symbols` Table
```sql
CREATE TABLE symbols (
    id INTEGER PRIMARY KEY,
    symbol_id TEXT UNIQUE NOT NULL,  -- SCIP symbol identifier
    name TEXT NOT NULL,               -- Human-readable name
    kind TEXT NOT NULL,               -- class, struct, protocol, function, property, enum
    module TEXT,                      -- Module/target name
    documentation TEXT                -- Docstring/documentation
);
```

#### `occurrences` Table
```sql
CREATE TABLE occurrences (
    id INTEGER PRIMARY KEY,
    symbol_id TEXT NOT NULL,          -- References symbols(symbol_id)
    file_path TEXT NOT NULL,          -- Relative path from project root
    start_line INTEGER NOT NULL,      -- 0-indexed
    start_col INTEGER NOT NULL,       -- 0-indexed
    end_line INTEGER NOT NULL,
    end_col INTEGER NOT NULL,
    role INTEGER NOT NULL,            -- Bitmask: definition=1, reference=8
    snippet TEXT,                     -- Context lines around occurrence
    enclosing_symbol TEXT,            -- Symbol ID of enclosing scope
    enclosing_name TEXT               -- Human-readable name of enclosing scope
);
```

#### `symbol_relationships` Table
```sql
CREATE TABLE symbol_relationships (
    id INTEGER PRIMARY KEY,
    source_symbol_id TEXT NOT NULL,
    target_symbol_id TEXT NOT NULL,
    kind TEXT NOT NULL                -- conforms, inherits, overrides
);
```

### Symbol Role Constants (Bitmask)
```python
class SymbolRole:
    DEFINITION = 1
    IMPORT = 2
    WRITE_ACCESS = 4
    READ_ACCESS = 8
    REFERENCE = 8      # Alias for READ_ACCESS
    GENERATED = 16
    TEST = 32
```

---

## SCIP Protocol Specification

### JSON Output Format

The Swift indexer must output JSON in this structure:

```json
{
  "metadata": {
    "version": 1,
    "toolInfo": {
      "name": "swift-scip-indexer",
      "version": "1.0.0"
    },
    "projectRoot": "file:///path/to/project",
    "textDocumentEncoding": "UTF-8"
  },
  "documents": [
    {
      "relativePath": "Sources/MyModule/MyClass.swift",
      "language": "swift",
      "symbols": [...],
      "occurrences": [...]
    }
  ]
}
```

### Symbol Information Structure

Each document's `symbols` array contains symbol definitions with documentation:

```json
{
  "symbol": "swift MyModule MyClass#",
  "kind": "class",
  "documentation": ["A class that does something.", "More details here."],
  "relationships": [
    {
      "symbol": "swift MyModule IMyProtocol#",
      "isImplementation": true
    }
  ]
}
```

### Occurrence Structure

Each document's `occurrences` array:

```json
{
  "symbol": "swift MyModule MyClass#",
  "range": [10, 6, 14],
  "symbolRoles": 1,
  "enclosingSymbol": "swift MyModule MyModule#",
  "snippet": "class MyClass: IMyProtocol {"
}
```

#### Range Format
- Single-line: `[startLine, startCol, endCol]` (3 elements)
- Multi-line: `[startLine, startCol, endLine, endCol]` (4 elements)
- All values are 0-indexed

### SCIP Symbol ID Format

Symbol IDs follow a structured format for uniqueness and parseability:

```
<scheme> ' ' <package> ' ' <descriptor>+
```

#### Components

| Component | Description | Example |
|-----------|-------------|---------|
| Scheme | Language identifier | `swift` |
| Package | Module/package name | `MyModule` |
| Descriptor | Symbol path with suffix | `MyClass#doSomething().` |

#### Descriptor Suffixes

| Suffix | Meaning | Example |
|--------|---------|---------|
| `/` | Namespace | `MyModule/` |
| `#` | Type (class, struct, enum, protocol) | `MyClass#` |
| `.` | Term/Property | `myProperty.` |
| `().` | Method/Function | `doSomething().` |
| `[]` | Type parameter | `T[]` |

#### Swift Symbol ID Examples

```
swift MyModule MyClass#
swift MyModule MyClass#doSomething().
swift MyModule MyClass#myProperty.
swift MyModule IMyProtocol#
swift MyModule MyClass#init().
swift MyModule MyEnum#caseA.
local 42                              # Local variable (not exported)
```

### Relationship Kinds

| Kind | Description | Swift Usage |
|------|-------------|-------------|
| `conforms` | Protocol conformance | `class Foo: Protocol` |
| `inherits` | Class inheritance | `class Child: Parent` |
| `overrides` | Method override | `override func foo()` |
| `implements` | Protocol method impl | Implementing protocol requirements |

---

## Swift Indexer Requirements

### Input Sources

1. **DerivedData Index Store**
   - Path: `<DerivedData>/Index.noindex/DataStore/` or `<DerivedData>/Index/DataStore/`
   - Contains compiled index data from `swiftc -index-store-path`
   - Must handle custom DerivedData locations

2. **Project Root**
   - Used to compute relative file paths
   - Source of git state information

3. **Git State** (Optional)
   - Track which files changed since last index
   - Store last indexed commit hash
   - Support incremental indexing

### Output

- JSON file at specified output path
- Follows SCIP JSON schema (protobuf-compatible)
- Contains all symbols, occurrences, and relationships

### Performance Targets

- Full index of 500k LOC project: < 30 seconds
- Incremental index (10 changed files): < 2 seconds
- Memory usage: < 500MB for large projects

---

## Dependencies

### Core Dependencies

| Package | Purpose | SPM URL |
|---------|---------|---------|
| **IndexStoreDB** | Read Xcode's index store | `https://github.com/swiftlang/indexstore-db` |
| **SwiftProtobuf** | SCIP protobuf support (optional, for binary output) | `https://github.com/apple/swift-protobuf` |
| **ArgumentParser** | CLI argument parsing | `https://github.com/apple/swift-argument-parser` |

### Optional Dependencies

| Package | Purpose | SPM URL |
|---------|---------|---------|
| **SwiftGit2** | Git operations for incremental indexing | `https://github.com/SwiftGit2/SwiftGit2` |

### Dependency Notes

#### IndexStoreDB
- **Important**: No semantic version tags; use branch-based versioning
- Recommended: Use `release/6.0` branch or `swift-6.0.2-RELEASE` tag
- Requires macOS 12+ for full functionality
- Built on `libIndexStore` (ships with Xcode)

```swift
.package(url: "https://github.com/swiftlang/indexstore-db", branch: "release/6.0")
```

#### SwiftProtobuf
- Latest stable: `1.28.x`
- Only needed if outputting binary protobuf (optional)
- JSON output can be done with Foundation's JSONEncoder

```swift
.package(url: "https://github.com/apple/swift-protobuf", from: "1.28.0")
```

#### ArgumentParser
- Latest stable: `1.5.x`
- Supports async commands via `AsyncParsableCommand`
- Well-documented, Apple-maintained

```swift
.package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0")
```

#### SwiftGit2 (Optional)
- Provides libgit2 bindings
- Used for git status checks
- Alternative: Shell out to `git` command

```swift
.package(url: "https://github.com/SwiftGit2/SwiftGit2", from: "0.10.0")
```

---

## Implementation Details

### Architecture

```
swift-scip-indexer/
├── Sources/
│   └── SwiftSCIPIndexer/
│       ├── main.swift              # Entry point
│       ├── Commands/
│       │   ├── IndexCommand.swift  # Main indexing command
│       │   └── StatusCommand.swift # Check index status
│       ├── Indexer/
│       │   ├── IndexStoreReader.swift    # Read from DerivedData
│       │   ├── SymbolCollector.swift     # Collect and process symbols
│       │   ├── RelationshipResolver.swift # Resolve type relationships
│       │   └── SnippetExtractor.swift    # Extract code snippets
│       ├── Git/
│       │   ├── GitStateTracker.swift     # Track git changes
│       │   └── IncrementalFilter.swift   # Filter unchanged files
│       ├── SCIP/
│       │   ├── SCIPIndex.swift           # SCIP data structures
│       │   ├── SCIPSymbolBuilder.swift   # Build symbol IDs
│       │   └── SCIPJSONWriter.swift      # JSON serialization
│       └── Models/
│           ├── IndexedSymbol.swift
│           ├── IndexedOccurrence.swift
│           └── IndexedRelationship.swift
└── Tests/
    └── SwiftSCIPIndexerTests/
```

### Core Data Structures

```swift
// Models/IndexedSymbol.swift
struct IndexedSymbol {
    let symbolID: String        // SCIP format: "swift Module Type#member."
    let name: String            // Human-readable name
    let kind: SymbolKind        // .class, .struct, .protocol, .function, etc.
    let module: String?
    let documentation: [String]
    let relationships: [SymbolRelationship]
}

enum SymbolKind: String, Codable {
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

struct SymbolRelationship {
    let targetSymbolID: String
    let kind: RelationshipKind
}

enum RelationshipKind: String, Codable {
    case conforms = "conforms"
    case inherits = "inherits"
    case overrides = "overrides"
}
```

```swift
// Models/IndexedOccurrence.swift
struct IndexedOccurrence {
    let symbolID: String
    let filePath: String        // Relative to project root
    let range: SourceRange
    let role: SymbolRole
    let snippet: String?
    let enclosingSymbol: String?
    let enclosingName: String?
}

struct SourceRange {
    let startLine: Int          // 0-indexed
    let startColumn: Int
    let endLine: Int
    let endColumn: Int
    
    var asSCIPRange: [Int] {
        if startLine == endLine {
            return [startLine, startColumn, endColumn]
        }
        return [startLine, startColumn, endLine, endColumn]
    }
}

struct SymbolRole: OptionSet {
    let rawValue: Int
    
    static let definition = SymbolRole(rawValue: 1)
    static let `import` = SymbolRole(rawValue: 2)
    static let writeAccess = SymbolRole(rawValue: 4)
    static let readAccess = SymbolRole(rawValue: 8)
    static let reference = SymbolRole(rawValue: 8)  // Alias
    static let generated = SymbolRole(rawValue: 16)
    static let test = SymbolRole(rawValue: 32)
}
```

### IndexStoreDB Integration

```swift
// Indexer/IndexStoreReader.swift
import IndexStoreDB

final class IndexStoreReader {
    private let indexStore: IndexStoreDB
    private let projectRoot: URL
    
    init(derivedDataPath: URL, projectRoot: URL) throws {
        // IndexStoreDB expects the path to the DataStore directory
        let storePath = Self.findIndexStorePath(in: derivedDataPath)
        
        // Create temporary database path for IndexStoreDB
        let dbPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("swift-scip-\(UUID().uuidString)")
        
        self.indexStore = try IndexStoreDB(
            storePath: storePath.path,
            databasePath: dbPath.path,
            library: nil,  // Uses system libIndexStore
            waitUntilDoneInitializing: true
        )
        self.projectRoot = projectRoot
    }
    
    /// Find all symbols in the index store
    func collectSymbols() -> [IndexedSymbol] {
        // Use indexStore.symbols() or iterate through occurrences
        // ...
    }
    
    /// Find all occurrences for a set of files
    func collectOccurrences(forFiles files: [String]?) -> [IndexedOccurrence] {
        // If files is nil, collect all occurrences
        // Otherwise, filter to only specified files
        // ...
    }
    
    /// Find relationships (inheritance, conformances)
    func collectRelationships() -> [SymbolRelationship] {
        // Use indexStore to find base types, conformances
        // ...
    }
    
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
}
```

### SCIP Symbol ID Builder

```swift
// SCIP/SCIPSymbolBuilder.swift
struct SCIPSymbolBuilder {
    
    /// Build SCIP symbol ID from IndexStoreDB symbol
    static func buildSymbolID(
        usr: String,          // Unified Symbol Resolution from compiler
        name: String,
        kind: SymbolKind,
        module: String?
    ) -> String {
        // Local symbols
        if usr.hasPrefix("s:") == false || module == nil {
            return "local \(usr.hashValue)"
        }
        
        let moduleName = module ?? "Unknown"
        let suffix = kindSuffix(for: kind)
        
        // Build descriptor chain
        // For nested types: "swift Module OuterType#InnerType#"
        // For methods: "swift Module Type#method()."
        
        return "swift \(moduleName) \(name)\(suffix)"
    }
    
    private static func kindSuffix(for kind: SymbolKind) -> String {
        switch kind {
        case .class, .struct, .protocol, .enum:
            return "#"
        case .function:
            return "()."
        case .property, .enumCase:
            return "."
        case .typeAlias:
            return "#"
        case .local, .unknown:
            return ""
        }
    }
}
```

### Git State Tracking

```swift
// Git/GitStateTracker.swift
import Foundation

final class GitStateTracker {
    private let projectRoot: URL
    private let stateFile: URL
    
    struct IndexState: Codable {
        let lastCommitHash: String
        let lastIndexedAt: Date
        let indexedFiles: [String: String]  // path -> content hash
    }
    
    init(projectRoot: URL) {
        self.projectRoot = projectRoot
        self.stateFile = projectRoot
            .appendingPathComponent(".swift-scip-state.json")
    }
    
    /// Get files that changed since last index
    func getChangedFiles() throws -> [String]? {
        guard let state = loadState() else {
            return nil  // Full index needed
        }
        
        // Get current HEAD
        let currentHash = try getCurrentCommitHash()
        
        if currentHash == state.lastCommitHash {
            // Same commit - check working tree changes
            return try getWorkingTreeChanges()
        }
        
        // Different commit - get diff
        return try getChangedFilesSince(commit: state.lastCommitHash)
    }
    
    /// Save index state after successful indexing
    func saveState(commitHash: String, files: [String]) throws {
        let state = IndexState(
            lastCommitHash: commitHash,
            lastIndexedAt: Date(),
            indexedFiles: Dictionary(uniqueKeysWithValues: files.map { ($0, "") })
        )
        let data = try JSONEncoder().encode(state)
        try data.write(to: stateFile)
    }
    
    private func getCurrentCommitHash() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "HEAD"]
        process.currentDirectoryURL = projectRoot
        
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    
    private func getChangedFilesSince(commit: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["diff", "--name-only", commit, "HEAD", "--", "*.swift"]
        process.currentDirectoryURL = projectRoot
        
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        return output.split(separator: "\n").map(String.init)
    }
    
    private func getWorkingTreeChanges() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--porcelain", "--", "*.swift"]
        process.currentDirectoryURL = projectRoot
        
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        return output.split(separator: "\n").compactMap { line in
            // Format: "XY filename" where X=index, Y=worktree
            let trimmed = line.dropFirst(3)  // Remove status prefix
            return String(trimmed)
        }
    }
    
    private func loadState() -> IndexState? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        return try? JSONDecoder().decode(IndexState.self, from: data)
    }
}
```

### JSON Output Writer

```swift
// SCIP/SCIPJSONWriter.swift
import Foundation

struct SCIPJSONWriter {
    
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
    
    static func write(
        symbols: [IndexedSymbol],
        occurrences: [IndexedOccurrence],
        projectRoot: URL,
        to outputPath: URL
    ) throws {
        // Group occurrences by file
        let grouped = Dictionary(grouping: occurrences, by: \.filePath)
        
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
            documents: documents
        )
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(output)
        try data.write(to: outputPath)
    }
}
```

### Snippet Extraction

```swift
// Indexer/SnippetExtractor.swift
import Foundation

struct SnippetExtractor {
    
    /// Extract a code snippet around a source location
    static func extractSnippet(
        file: URL,
        line: Int,
        contextLines: Int = 0
    ) -> String? {
        guard let content = try? String(contentsOf: file, encoding: .utf8) else {
            return nil
        }
        
        let lines = content.components(separatedBy: .newlines)
        
        let startLine = max(0, line - contextLines)
        let endLine = min(lines.count - 1, line + contextLines)
        
        guard startLine <= endLine, startLine < lines.count else {
            return nil
        }
        
        return lines[startLine...endLine].joined(separator: "\n")
    }
}
```

---

## Package.swift

```swift
// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "swift-scip-indexer",
    platforms: [
        .macOS(.v13)  // Required for IndexStoreDB and async/await
    ],
    products: [
        .executable(
            name: "swift-scip-indexer",
            targets: ["SwiftSCIPIndexer"]
        )
    ],
    dependencies: [
        // CLI argument parsing
        .package(
            url: "https://github.com/apple/swift-argument-parser",
            from: "1.5.0"
        ),
        // Index store access (Xcode's indexing data)
        .package(
            url: "https://github.com/swiftlang/indexstore-db",
            branch: "release/6.0"
        ),
        // Optional: For binary protobuf output
        // .package(
        //     url: "https://github.com/apple/swift-protobuf",
        //     from: "1.28.0"
        // ),
    ],
    targets: [
        .executableTarget(
            name: "SwiftSCIPIndexer",
            dependencies: [
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
                .product(name: "IndexStoreDB", package: "indexstore-db"),
                // .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/SwiftSCIPIndexer"
        ),
        .testTarget(
            name: "SwiftSCIPIndexerTests",
            dependencies: ["SwiftSCIPIndexer"],
            path: "Tests/SwiftSCIPIndexerTests"
        ),
    ]
)
```

### Build Notes

1. **Xcode Requirement**: IndexStoreDB requires Xcode to be installed (uses system libIndexStore)
2. **macOS Version**: Minimum macOS 13 for full async/await and IndexStoreDB support
3. **Swift Version**: Requires Swift 5.9+ for Package.swift syntax

---

## CLI Interface

### Commands

```bash
# Full index
swift-scip-indexer index \
    --derived-data ~/Library/Developer/Xcode/DerivedData/MyProject-xxx \
    --project-root /path/to/project \
    --output /path/to/output.scip.json

# Incremental index (checks git state)
swift-scip-indexer index \
    --derived-data ~/CustomDerivedData \
    --project-root /path/to/project \
    --output /path/to/output.scip.json \
    --incremental

# Force full re-index
swift-scip-indexer index \
    --derived-data ~/CustomDerivedData \
    --project-root /path/to/project \
    --output /path/to/output.scip.json \
    --force

# Check index status
swift-scip-indexer status \
    --project-root /path/to/project
```

### Command Implementation

```swift
// Commands/IndexCommand.swift
import ArgumentParser
import Foundation

@main
struct SwiftSCIPIndexer: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-scip-indexer",
        abstract: "Generate SCIP index from Xcode's DerivedData",
        version: "1.0.0",
        subcommands: [IndexCommand.self, StatusCommand.self],
        defaultSubcommand: IndexCommand.self
    )
}

struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Index Swift project and generate SCIP output"
    )
    
    @Option(name: .long, help: "Path to DerivedData directory")
    var derivedData: String
    
    @Option(name: .long, help: "Path to project root")
    var projectRoot: String
    
    @Option(name: .shortAndLong, help: "Output path for SCIP JSON file")
    var output: String
    
    @Flag(name: .long, help: "Only index files changed since last run")
    var incremental: Bool = false
    
    @Flag(name: .long, help: "Force full re-index, ignoring cached state")
    var force: Bool = false
    
    @Option(name: .long, help: "Filter to specific module(s)")
    var module: [String] = []
    
    @Flag(name: .long, help: "Include snippet context in occurrences")
    var includeSnippets: Bool = true
    
    mutating func run() async throws {
        let derivedDataURL = URL(fileURLWithPath: derivedData)
        let projectRootURL = URL(fileURLWithPath: projectRoot)
        let outputURL = URL(fileURLWithPath: output)
        
        print("📚 Swift SCIP Indexer")
        print("   DerivedData: \(derivedDataURL.path)")
        print("   Project Root: \(projectRootURL.path)")
        print("   Output: \(outputURL.path)")
        print("   Mode: \(incremental ? "Incremental" : "Full")")
        print("")
        
        // Determine files to index
        var filesToIndex: [String]? = nil
        
        if incremental && !force {
            let tracker = GitStateTracker(projectRoot: projectRootURL)
            filesToIndex = try tracker.getChangedFiles()
            
            if let files = filesToIndex {
                print("🔍 Incremental mode: \(files.count) changed files")
            } else {
                print("🔍 No previous state found, performing full index")
            }
        }
        
        // Read index store
        print("📖 Reading index store...")
        let reader = try IndexStoreReader(
            derivedDataPath: derivedDataURL,
            projectRoot: projectRootURL
        )
        
        // Collect data
        print("🔎 Collecting symbols...")
        let symbols = reader.collectSymbols()
        print("   Found \(symbols.count) symbols")
        
        print("🔎 Collecting occurrences...")
        let occurrences = reader.collectOccurrences(forFiles: filesToIndex)
        print("   Found \(occurrences.count) occurrences")
        
        print("🔎 Resolving relationships...")
        let relationships = reader.collectRelationships()
        print("   Found \(relationships.count) relationships")
        
        // Write output
        print("💾 Writing SCIP index...")
        try SCIPJSONWriter.write(
            symbols: symbols,
            occurrences: occurrences,
            projectRoot: projectRootURL,
            to: outputURL
        )
        
        // Save state for incremental updates
        if incremental {
            let tracker = GitStateTracker(projectRoot: projectRootURL)
            let commitHash = try tracker.getCurrentCommitHash()
            let files = Array(Set(occurrences.map(\.filePath)))
            try tracker.saveState(commitHash: commitHash, files: files)
        }
        
        print("✅ Done! Index written to \(outputURL.path)")
    }
}

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Check index state and pending changes"
    )
    
    @Option(name: .long, help: "Path to project root")
    var projectRoot: String
    
    mutating func run() async throws {
        let projectRootURL = URL(fileURLWithPath: projectRoot)
        let tracker = GitStateTracker(projectRoot: projectRootURL)
        
        guard let state = tracker.loadState() else {
            print("❌ No index state found. Run 'index' first.")
            return
        }
        
        print("📊 Index Status")
        print("   Last indexed: \(state.lastIndexedAt)")
        print("   Commit: \(state.lastCommitHash.prefix(8))")
        print("   Files indexed: \(state.indexedFiles.count)")
        
        if let changed = try tracker.getChangedFiles() {
            print("   Pending changes: \(changed.count) files")
            for file in changed.prefix(10) {
                print("     - \(file)")
            }
            if changed.count > 10 {
                print("     ... and \(changed.count - 10) more")
            }
        }
    }
}
```

---

## Testing Strategy

### Unit Tests

```swift
// Tests/SwiftSCIPIndexerTests/SCIPSymbolBuilderTests.swift
import XCTest
@testable import SwiftSCIPIndexer

final class SCIPSymbolBuilderTests: XCTestCase {
    
    func testClassSymbolID() {
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "s:8MyModule7MyClassC",
            name: "MyClass",
            kind: .class,
            module: "MyModule"
        )
        
        XCTAssertEqual(symbolID, "swift MyModule MyClass#")
    }
    
    func testMethodSymbolID() {
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "s:8MyModule7MyClassC9doSomethingyyF",
            name: "doSomething",
            kind: .function,
            module: "MyModule"
        )
        
        XCTAssertEqual(symbolID, "swift MyModule doSomething().")
    }
    
    func testLocalSymbolID() {
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "local_123",
            name: "temp",
            kind: .local,
            module: nil
        )
        
        XCTAssertTrue(symbolID.hasPrefix("local "))
    }
}
```

### Integration Tests

```swift
// Tests/SwiftSCIPIndexerTests/IntegrationTests.swift
import XCTest
@testable import SwiftSCIPIndexer

final class IntegrationTests: XCTestCase {
    
    var testProjectPath: URL!
    var derivedDataPath: URL!
    
    override func setUp() {
        // Set up test fixtures
        testProjectPath = Bundle.module.url(forResource: "TestProject", withExtension: nil)!
        derivedDataPath = Bundle.module.url(forResource: "TestDerivedData", withExtension: nil)!
    }
    
    func testFullIndexing() throws {
        let reader = try IndexStoreReader(
            derivedDataPath: derivedDataPath,
            projectRoot: testProjectPath
        )
        
        let symbols = reader.collectSymbols()
        XCTAssertFalse(symbols.isEmpty)
        
        // Verify expected symbols
        let classSymbols = symbols.filter { $0.kind == .class }
        XCTAssertFalse(classSymbols.isEmpty)
    }
    
    func testJSONOutput() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("test-output.scip.json")
        
        defer { try? FileManager.default.removeItem(at: outputURL) }
        
        let reader = try IndexStoreReader(
            derivedDataPath: derivedDataPath,
            projectRoot: testProjectPath
        )
        
        let symbols = reader.collectSymbols()
        let occurrences = reader.collectOccurrences(forFiles: nil)
        
        try SCIPJSONWriter.write(
            symbols: symbols,
            occurrences: occurrences,
            projectRoot: testProjectPath,
            to: outputURL
        )
        
        // Verify output
        let data = try Data(contentsOf: outputURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        XCTAssertNotNil(json["metadata"])
        XCTAssertNotNil(json["documents"])
    }
}
```

### Validation Against Python Reader

After generating SCIP output, validate it can be read by the Python system:

```bash
# Generate index
swift-scip-indexer index \
    --derived-data ./DerivedData \
    --project-root . \
    --output ./index.scip.json

# Validate with Python reader
python -c "
from graphrag.indexer.scip_reader import load_scip_index
index = load_scip_index('./index.scip.json')
print(f'Symbols: {len(index.symbols)}')
print(f'Occurrences: {len(index.occurrences)}')
print(f'Relationships: {len(index.relationships)}')
"
```

---

## Error Handling

### Common Errors

| Error | Cause | Solution |
|-------|-------|----------|
| `Index store not found` | DerivedData doesn't contain index | Build project with indexing enabled |
| `libIndexStore not found` | Xcode not installed | Install Xcode or Command Line Tools |
| `Module not found` | Module filter doesn't match | Check module names in index |
| `Git state error` | Not a git repository | Initialize git or use `--force` |

### Xcode Index Store Requirements

For the index store to be populated:

1. **Build the project** - Index is created during compilation
2. **Indexing enabled** - Check `COMPILER_INDEX_STORE_ENABLE` build setting
3. **Correct DerivedData** - Ensure you're pointing to the right build

```bash
# Verify index store exists
ls -la ~/Library/Developer/Xcode/DerivedData/YourProject-*/Index.noindex/DataStore/

# Force rebuild with indexing
xcodebuild build \
    -project YourProject.xcodeproj \
    -scheme YourScheme \
    -derivedDataPath ./CustomDerivedData \
    COMPILER_INDEX_STORE_ENABLE=YES
```

---

## Future Enhancements

1. **Binary SCIP Output**: Support native protobuf format for Sourcegraph compatibility
2. **Watch Mode**: Monitor file changes and re-index automatically
3. **Parallel Processing**: Index multiple modules concurrently
4. **Source Availability**: Handle SPM dependencies without source
5. **Cross-module Resolution**: Link symbols across module boundaries
6. **Documentation Extraction**: Parse Swift doc comments for symbol documentation

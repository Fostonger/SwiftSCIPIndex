import Foundation
import SQLite3

/// Efficient SQLite-based storage for SCIP indexes
/// Handles multi-GB datasets without loading everything into memory
final class SCIPDatabaseWriter {
    private let dbPath: URL
    private var db: OpaquePointer?
    private let readOnly: Bool
    
    // Prepared statements for batch operations
    private var insertDocumentStmt: OpaquePointer?
    private var insertSymbolStmt: OpaquePointer?
    private var insertOccurrenceStmt: OpaquePointer?
    private var insertRelationshipStmt: OpaquePointer?
    
    init(dbPath: URL, readOnly: Bool = false) throws {
        self.dbPath = dbPath
        self.readOnly = readOnly
        try openDatabase()
        if !readOnly {
            try createSchema()
        }
    }
    
    deinit {
        finalizeStatements()
        closeDatabase()
    }
    
    // MARK: - State Management
    
    struct IndexState {
        let lastCommitHash: String
        let lastIndexedAt: Date
        let indexedFiles: [String]
    }
    
    /// Save index state (commit hash, indexed files)
    func saveState(commitHash: String, indexedFiles: [String]) throws {
        try beginTransaction()
        
        do {
            // Clear existing state (only one row)
            try execute("DELETE FROM index_state")
            
            // Insert new state
            let filesJSON = try JSONEncoder().encode(indexedFiles)
            let filesJSONString = String(data: filesJSON, encoding: .utf8) ?? "[]"
            
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            let sql = "INSERT INTO index_state (last_commit_hash, last_indexed_at, indexed_files) VALUES (?, ?, ?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SCIPDatabaseError.prepareFailed(errorMessage)
            }
            
            sqlite3_bind_text(stmt, 1, commitHash, -1, SQLITE_TRANSIENT)
            sqlite3_bind_int64(stmt, 2, Int64(Date().timeIntervalSince1970))
            sqlite3_bind_text(stmt, 3, filesJSONString, -1, SQLITE_TRANSIENT)
            
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw SCIPDatabaseError.executionFailed(errorMessage)
            }
            
            try commitTransaction()
        } catch {
            rollbackTransaction()
            throw error
        }
    }
    
    /// Load index state from database
    func loadState() throws -> IndexState? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        let sql = "SELECT last_commit_hash, last_indexed_at, indexed_files FROM index_state LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            return nil
        }
        
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            return nil
        }
        
        guard let commitHashPtr = sqlite3_column_text(stmt, 0),
              let filesJSONPtr = sqlite3_column_text(stmt, 2) else {
            return nil
        }
        
        let commitHash = String(cString: commitHashPtr)
        let indexedAt = Date(timeIntervalSince1970: TimeInterval(sqlite3_column_int64(stmt, 1)))
        let filesJSON = String(cString: filesJSONPtr)
        
        let files = (try? JSONDecoder().decode([String].self, from: filesJSON.data(using: .utf8)!)) ?? []
        
        return IndexState(
            lastCommitHash: commitHash,
            lastIndexedAt: indexedAt,
            indexedFiles: files
        )
    }
    
    // MARK: - Writing
    
    /// Write complete index to database (streaming, memory-efficient)
    func write(
        symbols: [IndexedSymbol],
        occurrences: [IndexedOccurrence],
        projectRoot: URL
    ) throws {
        try beginTransaction()
        
        do {
            // Clear existing data
            try execute("DELETE FROM occurrences")
            try execute("DELETE FROM relationships")
            try execute("DELETE FROM symbols")
            try execute("DELETE FROM documents")
            
            // Save metadata
            try saveMetadata(projectRoot: projectRoot)
            
            // Prepare statements for batch inserts
            try prepareStatements()
            
            // Group occurrences by file for efficient insertion
            let occurrencesByFile = Dictionary(grouping: occurrences, by: \.filePath)
            
            // Build symbol lookup for quick access
            let symbolsByID = Dictionary(uniqueKeysWithValues: symbols.map { ($0.symbolID, $0) })
            
            // Insert documents and occurrences
            for (filePath, fileOccurrences) in occurrencesByFile {
                let fileId = try insertDocument(path: filePath)
                
                // Find symbols defined in this file
                let definedSymbolIDs = Set(
                    fileOccurrences
                        .filter { $0.role.contains(.definition) }
                        .map { $0.symbolID }
                )
                
                // Insert symbols defined in this file
                for symbolID in definedSymbolIDs {
                    if let symbol = symbolsByID[symbolID] {
                        try insertSymbol(symbol, fileId: fileId)
                    }
                }
                
                // Insert occurrences
                for occurrence in fileOccurrences {
                    try insertOccurrence(occurrence, fileId: fileId)
                }
            }
            
            // Insert relationships (after all symbols are inserted)
            for symbol in symbols {
                for relationship in symbol.relationships {
                    try insertRelationship(
                        fromSymbolID: symbol.symbolID,
                        toSymbolID: relationship.targetSymbolID,
                        kind: relationship.kind.rawValue
                    )
                }
            }
            
            try commitTransaction()
        } catch {
            rollbackTransaction()
            throw error
        }
    }
    
    /// Update specific documents (incremental merge)
    func updateDocuments(
        filePaths: [String],
        symbols: [IndexedSymbol],
        occurrences: [IndexedOccurrence]
    ) throws {
        try beginTransaction()
        
        do {
            try prepareStatements()
            
            // Group occurrences by file
            let occurrencesByFile = Dictionary(grouping: occurrences, by: \.filePath)
            let symbolsByID = Dictionary(uniqueKeysWithValues: symbols.map { ($0.symbolID, $0) })
            
            for filePath in filePaths {
                // Delete existing data for this file (cascade will handle occurrences/symbols)
                if let fileId = try getFileId(path: filePath) {
                    try execute("DELETE FROM occurrences WHERE file_id = ?", parameters: [.int(fileId)])
                    try execute("DELETE FROM symbols WHERE file_id = ?", parameters: [.int(fileId)])
                    try execute("DELETE FROM documents WHERE id = ?", parameters: [.int(fileId)])
                }
                
                // Insert new data if there are occurrences for this file
                guard let fileOccurrences = occurrencesByFile[filePath], !fileOccurrences.isEmpty else {
                    continue
                }
                
                let fileId = try insertDocument(path: filePath)
                
                // Find symbols defined in this file
                let definedSymbolIDs = Set(
                    fileOccurrences
                        .filter { $0.role.contains(.definition) }
                        .map { $0.symbolID }
                )
                
                for symbolID in definedSymbolIDs {
                    if let symbol = symbolsByID[symbolID] {
                        try insertSymbol(symbol, fileId: fileId)
                    }
                }
                
                for occurrence in fileOccurrences {
                    try insertOccurrence(occurrence, fileId: fileId)
                }
            }
            
            try commitTransaction()
        } catch {
            rollbackTransaction()
            throw error
        }
    }
    
    /// Delete documents (for removed files)
    func deleteDocuments(filePaths: [String]) throws {
        try beginTransaction()
        
        do {
            for filePath in filePaths {
                // Cascade delete will handle symbols and occurrences
                try execute(
                    "DELETE FROM documents WHERE relative_path = ?",
                    parameters: [.text(filePath)]
                )
            }
            
            try commitTransaction()
        } catch {
            rollbackTransaction()
            throw error
        }
    }
    
    /// Get list of all indexed file paths
    func getIndexedFilePaths() throws -> [String] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        let sql = "SELECT relative_path FROM documents ORDER BY relative_path"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SCIPDatabaseError.prepareFailed(errorMessage)
        }
        
        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let pathPtr = sqlite3_column_text(stmt, 0) {
                paths.append(String(cString: pathPtr))
            }
        }
        
        return paths
    }
    
    // MARK: - Private Schema
    
    private func createSchema() throws {
        let schema = """
        CREATE TABLE IF NOT EXISTS metadata (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        
        CREATE TABLE IF NOT EXISTS index_state (
            last_commit_hash TEXT NOT NULL,
            last_indexed_at INTEGER NOT NULL,
            indexed_files TEXT
        );
        
        CREATE TABLE IF NOT EXISTS documents (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            relative_path TEXT NOT NULL UNIQUE,
            language TEXT NOT NULL DEFAULT 'swift',
            indexed_at INTEGER NOT NULL
        );
        
        CREATE TABLE IF NOT EXISTS symbols (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            symbol_id TEXT NOT NULL,
            kind TEXT,
            documentation TEXT,
            file_id INTEGER,
            FOREIGN KEY(file_id) REFERENCES documents(id) ON DELETE CASCADE
        );
        
        CREATE TABLE IF NOT EXISTS relationships (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            symbol_id TEXT NOT NULL,
            target_symbol_id TEXT NOT NULL,
            kind TEXT NOT NULL
        );
        
        CREATE TABLE IF NOT EXISTS occurrences (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            symbol_id TEXT NOT NULL,
            file_id INTEGER NOT NULL,
            start_line INTEGER NOT NULL,
            start_column INTEGER NOT NULL,
            end_line INTEGER NOT NULL,
            end_column INTEGER NOT NULL,
            roles INTEGER NOT NULL,
            enclosing_symbol TEXT,
            snippet TEXT,
            FOREIGN KEY(file_id) REFERENCES documents(id) ON DELETE CASCADE
        );
        
        CREATE INDEX IF NOT EXISTS idx_documents_path ON documents(relative_path);
        CREATE INDEX IF NOT EXISTS idx_symbols_id ON symbols(symbol_id);
        CREATE INDEX IF NOT EXISTS idx_symbols_file ON symbols(file_id);
        CREATE INDEX IF NOT EXISTS idx_occurrences_symbol ON occurrences(symbol_id);
        CREATE INDEX IF NOT EXISTS idx_occurrences_file ON occurrences(file_id);
        CREATE INDEX IF NOT EXISTS idx_relationships_symbol ON relationships(symbol_id);
        """
        
        guard sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK else {
            throw SCIPDatabaseError.schemaCreationFailed(errorMessage)
        }
        
        try configurePerformance()
    }
    
    private func configurePerformance() throws {
        // WAL mode for better concurrency
        try execute("PRAGMA journal_mode = WAL")
        
        // Larger cache size (80MB)
        try execute("PRAGMA cache_size = -20000")
        
        // Normal synchronous mode (faster, still safe)
        try execute("PRAGMA synchronous = NORMAL")
        
        // Enable foreign keys
        try execute("PRAGMA foreign_keys = ON")
    }
    
    private func saveMetadata(projectRoot: URL) throws {
        try execute("DELETE FROM metadata")
        
        let metadata: [(String, String)] = [
            ("version", "1"),
            ("tool_name", "swift-scip-indexer"),
            ("tool_version", "1.0.0"),
            ("project_root", "file://\(projectRoot.path)"),
            ("text_document_encoding", "UTF-8")
        ]
        
        for (key, value) in metadata {
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            
            let sql = "INSERT INTO metadata (key, value) VALUES (?, ?)"
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
                throw SCIPDatabaseError.prepareFailed(errorMessage)
            }
            
            sqlite3_bind_text(stmt, 1, key, -1, SQLITE_TRANSIENT)
            sqlite3_bind_text(stmt, 2, value, -1, SQLITE_TRANSIENT)
            
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw SCIPDatabaseError.executionFailed(errorMessage)
            }
        }
    }
    
    // MARK: - Private Insert Methods
    
    private func prepareStatements() throws {
        finalizeStatements()
        
        // Document insert
        let docSQL = "INSERT INTO documents (relative_path, language, indexed_at) VALUES (?, 'swift', ?)"
        guard sqlite3_prepare_v2(db, docSQL, -1, &insertDocumentStmt, nil) == SQLITE_OK else {
            throw SCIPDatabaseError.prepareFailed(errorMessage)
        }
        
        // Symbol insert
        let symSQL = "INSERT INTO symbols (symbol_id, kind, documentation, file_id) VALUES (?, ?, ?, ?)"
        guard sqlite3_prepare_v2(db, symSQL, -1, &insertSymbolStmt, nil) == SQLITE_OK else {
            throw SCIPDatabaseError.prepareFailed(errorMessage)
        }
        
        // Occurrence insert
        let occSQL = """
            INSERT INTO occurrences 
            (symbol_id, file_id, start_line, start_column, end_line, end_column, roles, enclosing_symbol, snippet) 
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
        guard sqlite3_prepare_v2(db, occSQL, -1, &insertOccurrenceStmt, nil) == SQLITE_OK else {
            throw SCIPDatabaseError.prepareFailed(errorMessage)
        }
        
        // Relationship insert
        let relSQL = "INSERT INTO relationships (symbol_id, target_symbol_id, kind) VALUES (?, ?, ?)"
        guard sqlite3_prepare_v2(db, relSQL, -1, &insertRelationshipStmt, nil) == SQLITE_OK else {
            throw SCIPDatabaseError.prepareFailed(errorMessage)
        }
    }
    
    private func finalizeStatements() {
        if let stmt = insertDocumentStmt {
            sqlite3_finalize(stmt)
            insertDocumentStmt = nil
        }
        if let stmt = insertSymbolStmt {
            sqlite3_finalize(stmt)
            insertSymbolStmt = nil
        }
        if let stmt = insertOccurrenceStmt {
            sqlite3_finalize(stmt)
            insertOccurrenceStmt = nil
        }
        if let stmt = insertRelationshipStmt {
            sqlite3_finalize(stmt)
            insertRelationshipStmt = nil
        }
    }
    
    private func insertDocument(path: String) throws -> Int64 {
        guard let stmt = insertDocumentStmt else {
            throw SCIPDatabaseError.prepareFailed("Statement not prepared")
        }
        
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, Int64(Date().timeIntervalSince1970))
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SCIPDatabaseError.executionFailed(errorMessage)
        }
        
        return sqlite3_last_insert_rowid(db)
    }
    
    private func insertSymbol(_ symbol: IndexedSymbol, fileId: Int64) throws {
        guard let stmt = insertSymbolStmt else {
            throw SCIPDatabaseError.prepareFailed("Statement not prepared")
        }
        
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, symbol.symbolID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, symbol.kind.rawValue, -1, SQLITE_TRANSIENT)
        
        // Encode documentation as JSON
        if !symbol.documentation.isEmpty {
            let docJSON = (try? JSONEncoder().encode(symbol.documentation))
                .flatMap { String(data: $0, encoding: .utf8) }
            sqlite3_bind_text(stmt, 3, docJSON ?? "[]", -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        
        sqlite3_bind_int64(stmt, 4, fileId)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SCIPDatabaseError.executionFailed(errorMessage)
        }
    }
    
    private func insertOccurrence(_ occurrence: IndexedOccurrence, fileId: Int64) throws {
        guard let stmt = insertOccurrenceStmt else {
            throw SCIPDatabaseError.prepareFailed("Statement not prepared")
        }
        
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, occurrence.symbolID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_int64(stmt, 2, fileId)
        sqlite3_bind_int(stmt, 3, Int32(occurrence.range.startLine))
        sqlite3_bind_int(stmt, 4, Int32(occurrence.range.startColumn))
        sqlite3_bind_int(stmt, 5, Int32(occurrence.range.endLine))
        sqlite3_bind_int(stmt, 6, Int32(occurrence.range.endColumn))
        sqlite3_bind_int(stmt, 7, Int32(occurrence.role.rawValue))
        
        if let enclosing = occurrence.enclosingSymbol {
            sqlite3_bind_text(stmt, 8, enclosing, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 8)
        }
        
        if let snippet = occurrence.snippet {
            sqlite3_bind_text(stmt, 9, snippet, -1, SQLITE_TRANSIENT)
        } else {
            sqlite3_bind_null(stmt, 9)
        }
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SCIPDatabaseError.executionFailed(errorMessage)
        }
    }
    
    private func insertRelationship(fromSymbolID: String, toSymbolID: String, kind: String) throws {
        guard let stmt = insertRelationshipStmt else {
            throw SCIPDatabaseError.prepareFailed("Statement not prepared")
        }
        
        sqlite3_reset(stmt)
        sqlite3_bind_text(stmt, 1, fromSymbolID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 2, toSymbolID, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(stmt, 3, kind, -1, SQLITE_TRANSIENT)
        
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw SCIPDatabaseError.executionFailed(errorMessage)
        }
    }
    
    private func getFileId(path: String) throws -> Int64? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        let sql = "SELECT id FROM documents WHERE relative_path = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SCIPDatabaseError.prepareFailed(errorMessage)
        }
        
        sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT)
        
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_int64(stmt, 0)
        }
        
        return nil
    }
    
    // MARK: - Private Database Operations
    
    private func openDatabase() throws {
        let path = dbPath.path
        let flags = readOnly ? SQLITE_OPEN_READONLY : (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE)
        
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            throw SCIPDatabaseError.openFailed(errorMessage)
        }
    }
    
    private func closeDatabase() {
        if let db = db {
            sqlite3_close(db)
            self.db = nil
        }
    }
    
    private func beginTransaction() throws {
        try execute("BEGIN TRANSACTION")
    }
    
    private func commitTransaction() throws {
        try execute("COMMIT")
    }
    
    private func rollbackTransaction() {
        _ = try? execute("ROLLBACK")
    }
    
    private enum SQLiteParam {
        case int(Int64)
        case text(String)
        case null
    }
    
    @discardableResult
    private func execute(_ sql: String, parameters: [SQLiteParam] = []) throws -> Int32 {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw SCIPDatabaseError.prepareFailed(errorMessage)
        }
        
        // Bind parameters
        for (index, param) in parameters.enumerated() {
            let pos = Int32(index + 1)
            switch param {
            case .int(let value):
                sqlite3_bind_int64(stmt, pos, value)
            case .text(let value):
                sqlite3_bind_text(stmt, pos, value, -1, SQLITE_TRANSIENT)
            case .null:
                sqlite3_bind_null(stmt, pos)
            }
        }
        
        let result = sqlite3_step(stmt)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SCIPDatabaseError.executionFailed(errorMessage)
        }
        
        return result
    }
    
    private var errorMessage: String {
        if let db = db {
            return String(cString: sqlite3_errmsg(db))
        }
        return "Unknown error"
    }
}

// MARK: - SQLite Transient Constant

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

// MARK: - Errors

enum SCIPDatabaseError: Error, LocalizedError {
    case openFailed(String)
    case schemaCreationFailed(String)
    case prepareFailed(String)
    case executionFailed(String)
    case invalidParameter
    
    var errorDescription: String? {
        switch self {
        case .openFailed(let msg):
            return "Failed to open database: \(msg)"
        case .schemaCreationFailed(let msg):
            return "Failed to create schema: \(msg)"
        case .prepareFailed(let msg):
            return "Failed to prepare statement: \(msg)"
        case .executionFailed(let msg):
            return "Failed to execute statement: \(msg)"
        case .invalidParameter:
            return "Invalid parameter type"
        }
    }
}

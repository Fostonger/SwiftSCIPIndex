import Foundation

/// Manages branch-specific index caches for fast branch switching
final class BranchIndexManager {
    private let projectRoot: URL
    private let cacheRoot: URL
    
    struct BranchCache {
        let branchName: String
        let commitHash: String
        let dbPath: URL          // SQLite database path (contains index + state)
        let lastIndexedAt: Date
    }
    
    init(projectRoot: URL) {
        self.projectRoot = projectRoot
        self.cacheRoot = projectRoot
            .appendingPathComponent(".swift-scip-index")
            .appendingPathComponent("branches")
    }
    
    /// Get current git branch name
    func getCurrentBranch() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
        process.currentDirectoryURL = projectRoot
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw BranchIndexManagerError.notAGitRepository
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let branchName = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? "HEAD"
        
        // Sanitize branch name for filesystem
        return sanitizeBranchName(branchName)
    }
    
    /// Get cache directory for a branch
    func getBranchCacheDir(branchName: String) -> URL {
        return cacheRoot.appendingPathComponent(branchName)
    }
    
    /// Get SQLite database path for a branch
    func getBranchDatabasePath(branchName: String) -> URL {
        return getBranchCacheDir(branchName: branchName)
            .appendingPathComponent("index.db")
    }
    
    /// Check if branch cache exists and return its info
    func getBranchCache(branchName: String) throws -> BranchCache? {
        let dbPath = getBranchDatabasePath(branchName: branchName)
        
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            return nil
        }
        
        // Load state from database metadata table
        let dbWriter = try SCIPDatabaseWriter(dbPath: dbPath, readOnly: true)
        guard let state = try dbWriter.loadState() else {
            return nil
        }
        
        // Return cache info (validation happens at usage time)
        let attrs = try? FileManager.default.attributesOfItem(atPath: dbPath.path)
        let lastIndexedAt = attrs?[.modificationDate] as? Date ?? Date.distantPast
        
        return BranchCache(
            branchName: branchName,
            commitHash: state.lastCommitHash,
            dbPath: dbPath,
            lastIndexedAt: lastIndexedAt
        )
    }
    
    /// Create branch cache directory structure
    func createBranchCache(branchName: String) throws {
        let cacheDir = getBranchCacheDir(branchName: branchName)
        try FileManager.default.createDirectory(
            at: cacheDir,
            withIntermediateDirectories: true
        )
    }
    
    /// Fast switch: Copy cached SQLite database to output location
    func fastSwitchToBranch(branchName: String, outputDbPath: URL) throws {
        let cachedDb = getBranchDatabasePath(branchName: branchName)
        
        guard FileManager.default.fileExists(atPath: cachedDb.path) else {
            throw BranchIndexManagerError.cacheNotFound(branch: branchName)
        }
        
        // Ensure output directory exists
        try FileManager.default.createDirectory(
            at: outputDbPath.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        
        // Remove existing output file if present
        if FileManager.default.fileExists(atPath: outputDbPath.path) {
            try FileManager.default.removeItem(at: outputDbPath)
        }
        
        // Also remove WAL and SHM files if present (SQLite auxiliary files)
        let walPath = outputDbPath.appendingPathExtension("wal")
        let shmPath = outputDbPath.appendingPathExtension("shm")
        try? FileManager.default.removeItem(at: walPath)
        try? FileManager.default.removeItem(at: shmPath)
        
        // Copy SQLite database (fast file operation, even for multi-GB files)
        try FileManager.default.copyItem(at: cachedDb, to: outputDbPath)
        
        // Copy WAL and SHM files if they exist in the cache
        let cachedWal = cachedDb.appendingPathExtension("wal")
        let cachedShm = cachedDb.appendingPathExtension("shm")
        if FileManager.default.fileExists(atPath: cachedWal.path) {
            try? FileManager.default.copyItem(at: cachedWal, to: walPath)
        }
        if FileManager.default.fileExists(atPath: cachedShm.path) {
            try? FileManager.default.copyItem(at: cachedShm, to: shmPath)
        }
    }
    
    /// Copy output database to branch cache
    func saveToBranchCache(branchName: String, fromDbPath: URL) throws {
        try createBranchCache(branchName: branchName)
        
        let cachedDb = getBranchDatabasePath(branchName: branchName)
        
        // Remove existing cache if present
        if FileManager.default.fileExists(atPath: cachedDb.path) {
            try FileManager.default.removeItem(at: cachedDb)
        }
        
        // Also remove WAL and SHM files if present
        let cachedWal = cachedDb.appendingPathExtension("wal")
        let cachedShm = cachedDb.appendingPathExtension("shm")
        try? FileManager.default.removeItem(at: cachedWal)
        try? FileManager.default.removeItem(at: cachedShm)
        
        // Copy to cache
        try FileManager.default.copyItem(at: fromDbPath, to: cachedDb)
        
        // Copy WAL and SHM files if they exist
        let walPath = fromDbPath.appendingPathExtension("wal")
        let shmPath = fromDbPath.appendingPathExtension("shm")
        if FileManager.default.fileExists(atPath: walPath.path) {
            try? FileManager.default.copyItem(at: walPath, to: cachedWal)
        }
        if FileManager.default.fileExists(atPath: shmPath.path) {
            try? FileManager.default.copyItem(at: shmPath, to: cachedShm)
        }
    }
    
    /// List all cached branches
    func listCachedBranches() -> [String] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: cacheRoot,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }
        
        return contents.compactMap { url in
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                return nil
            }
            
            // Check if index.db exists in this directory
            let dbPath = url.appendingPathComponent("index.db")
            guard FileManager.default.fileExists(atPath: dbPath.path) else {
                return nil
            }
            
            return url.lastPathComponent
        }
    }
    
    /// Clean up cache for a specific branch
    func cleanBranchCache(branchName: String) throws {
        let cacheDir = getBranchCacheDir(branchName: branchName)
        if FileManager.default.fileExists(atPath: cacheDir.path) {
            try FileManager.default.removeItem(at: cacheDir)
        }
    }
    
    /// Clean up all branch caches
    func cleanAllCaches() throws {
        if FileManager.default.fileExists(atPath: cacheRoot.path) {
            try FileManager.default.removeItem(at: cacheRoot)
        }
    }
    
    /// Sanitize branch name for filesystem use
    private func sanitizeBranchName(_ name: String) -> String {
        // Replace invalid filesystem characters
        let invalidChars = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return name.components(separatedBy: invalidChars).joined(separator: "_")
    }
    
    // MARK: - Migration
    
    /// Migrate legacy JSON state file to SQLite database
    /// Returns true if migration was performed, false if no legacy state exists
    @discardableResult
    func migrateLegacyState() throws -> Bool {
        let legacyStateFile = projectRoot
            .appendingPathComponent(".swift-scip-state.json")
        
        guard FileManager.default.fileExists(atPath: legacyStateFile.path) else {
            return false // No legacy state to migrate
        }
        
        // Try to determine branch name from git
        let branchName: String
        do {
            branchName = try getCurrentBranch()
        } catch {
            // Default to "main" if can't determine
            branchName = "main"
        }
        
        // Load legacy JSON state
        let stateData = try Data(contentsOf: legacyStateFile)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let legacyState = try decoder.decode(LegacyIndexState.self, from: stateData)
        
        // Create branch cache directory and database
        try createBranchCache(branchName: branchName)
        let dbPath = getBranchDatabasePath(branchName: branchName)
        
        // Remove existing database if present
        if FileManager.default.fileExists(atPath: dbPath.path) {
            try FileManager.default.removeItem(at: dbPath)
        }
        
        let dbWriter = try SCIPDatabaseWriter(dbPath: dbPath)
        
        // Save state to SQLite database
        let files = Array(legacyState.indexedFiles.keys)
        try dbWriter.saveState(commitHash: legacyState.lastCommitHash, indexedFiles: files)
        
        // Backup legacy file
        let backupPath = legacyStateFile.deletingPathExtension()
            .appendingPathExtension("json.backup")
        
        // Remove existing backup if present
        if FileManager.default.fileExists(atPath: backupPath.path) {
            try FileManager.default.removeItem(at: backupPath)
        }
        
        try FileManager.default.moveItem(at: legacyStateFile, to: backupPath)
        
        return true
    }
    
    /// Check if legacy state file exists
    func hasLegacyState() -> Bool {
        let legacyStateFile = projectRoot
            .appendingPathComponent(".swift-scip-state.json")
        return FileManager.default.fileExists(atPath: legacyStateFile.path)
    }
}

// MARK: - Legacy State Model

/// Legacy JSON state format for migration
private struct LegacyIndexState: Codable {
    let lastCommitHash: String
    let lastIndexedAt: Date
    let indexedFiles: [String: String]  // path -> content hash
}

// MARK: - Errors

enum BranchIndexManagerError: Error, LocalizedError {
    case notAGitRepository
    case cacheNotFound(branch: String)
    case invalidCache
    
    var errorDescription: String? {
        switch self {
        case .notAGitRepository:
            return "Not a git repository"
        case .cacheNotFound(let branch):
            return "Cache not found for branch: \(branch)"
        case .invalidCache:
            return "Invalid or corrupted cache"
        }
    }
}

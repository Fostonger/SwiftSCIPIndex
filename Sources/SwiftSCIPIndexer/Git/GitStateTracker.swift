import Foundation

/// Tracks git state for incremental indexing
final class GitStateTracker {
    private let projectRoot: URL
    private let stateFile: URL
    
    /// State saved between indexing runs
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
    
    // MARK: - Branch-Aware Methods
    
    /// Load state from branch-specific SQLite database
    func loadBranchState(branchName: String) -> SCIPDatabaseWriter.IndexState? {
        let branchManager = BranchIndexManager(projectRoot: projectRoot)
        let dbPath = branchManager.getBranchDatabasePath(branchName: branchName)
        
        guard FileManager.default.fileExists(atPath: dbPath.path) else {
            return nil
        }
        
        do {
            let dbWriter = try SCIPDatabaseWriter(dbPath: dbPath, readOnly: true)
            return try dbWriter.loadState()
        } catch {
            return nil
        }
    }
    
    /// Get files that changed since last index for a specific branch
    func getChangedFilesForBranch(branchName: String) throws -> [String]? {
        guard let state = loadBranchState(branchName: branchName) else {
            return nil  // Full index needed
        }
        
        let currentHash = try getCurrentCommitHash()
        
        if currentHash == state.lastCommitHash {
            // Same commit - check working tree changes
            return try getWorkingTreeChanges()
        }
        
        // Different commit - get diff
        return try getChangedFilesSince(commit: state.lastCommitHash)
    }
    
    /// Get files that were deleted since a given commit
    func getDeletedFilesSince(commit: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["diff", "--name-only", "--diff-filter=D", commit, "HEAD", "--", "*.swift"]
        process.currentDirectoryURL = projectRoot
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        return output.split(separator: "\n").map(String.init)
    }
    
    /// Get files that changed since last index
    /// - Returns: Array of changed file paths, or nil if full index is needed
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
    
    /// Get the current HEAD commit hash
    func getCurrentCommitHash() throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "HEAD"]
        process.currentDirectoryURL = projectRoot
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        guard process.terminationStatus == 0 else {
            throw GitStateTrackerError.notAGitRepository
        }
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
    
    /// Save index state after successful indexing
    /// - Parameters:
    ///   - commitHash: Current commit hash
    ///   - files: List of indexed file paths
    func saveState(commitHash: String, files: [String]) throws {
        let state = IndexState(
            lastCommitHash: commitHash,
            lastIndexedAt: Date(),
            indexedFiles: Dictionary(uniqueKeysWithValues: files.map { ($0, "") })
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        try data.write(to: stateFile)
    }
    
    /// Load previously saved state
    func loadState() -> IndexState? {
        guard let data = try? Data(contentsOf: stateFile) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(IndexState.self, from: data)
    }
    
    /// Check if a git repository exists at the project root
    func isGitRepository() -> Bool {
        let gitDir = projectRoot.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
    
    // MARK: - Internal Methods
    
    func getChangedFilesSince(commit: String) throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["diff", "--name-only", commit, "HEAD", "--", "*.swift"]
        process.currentDirectoryURL = projectRoot
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        var files = output.split(separator: "\n").map(String.init)
        
        // Also include working tree changes
        let workingTreeChanges = try getWorkingTreeChanges()
        files.append(contentsOf: workingTreeChanges)
        
        return Array(Set(files))  // Remove duplicates
    }
    
    func getWorkingTreeChanges() throws -> [String] {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--porcelain", "--", "*.swift"]
        process.currentDirectoryURL = projectRoot
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        
        try process.run()
        process.waitUntilExit()
        
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        
        return output.split(separator: "\n").compactMap { line in
            // Format: "XY filename" where X=index status, Y=worktree status
            // Need to handle renamed files: "R  old -> new"
            let lineStr = String(line)
            guard lineStr.count > 3 else { return nil }
            
            let filenamePart = String(lineStr.dropFirst(3))
            
            // Handle renamed files
            if filenamePart.contains(" -> ") {
                let parts = filenamePart.components(separatedBy: " -> ")
                return parts.last
            }
            
            return filenamePart
        }
    }
}

// MARK: - Errors

enum GitStateTrackerError: Error, LocalizedError {
    case notAGitRepository
    case gitCommandFailed(String)
    
    var errorDescription: String? {
        switch self {
        case .notAGitRepository:
            return "Not a git repository. Use --force for full indexing without git state tracking."
        case .gitCommandFailed(let message):
            return "Git command failed: \(message)"
        }
    }
}


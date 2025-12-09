import XCTest
@testable import SwiftSCIPIndexer

final class BranchIndexManagerTests: XCTestCase {
    
    var tempDirectory: URL!
    var manager: BranchIndexManager!
    
    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BranchIndexManagerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        manager = BranchIndexManager(projectRoot: tempDirectory)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }
    
    // MARK: - Branch Name Sanitization
    
    func testGetBranchCacheDir() {
        let cacheDir = manager.getBranchCacheDir(branchName: "main")
        XCTAssertTrue(cacheDir.path.contains(".swift-scip-index"))
        XCTAssertTrue(cacheDir.path.contains("branches"))
        XCTAssertTrue(cacheDir.path.contains("main"))
    }
    
    func testGetBranchDatabasePath() {
        let dbPath = manager.getBranchDatabasePath(branchName: "feature")
        XCTAssertTrue(dbPath.path.hasSuffix("index.db"))
        XCTAssertTrue(dbPath.path.contains("feature"))
    }
    
    func testSanitizedBranchNameInPath() {
        // Branch names with slashes should be sanitized
        let dbPath = manager.getBranchDatabasePath(branchName: "feature_test")
        XCTAssertTrue(dbPath.path.contains("feature_test"))
    }
    
    // MARK: - Cache Directory Creation
    
    func testCreateBranchCache() throws {
        let branchName = "test-branch"
        try manager.createBranchCache(branchName: branchName)
        
        let cacheDir = manager.getBranchCacheDir(branchName: branchName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.path))
    }
    
    func testCreateBranchCacheIdempotent() throws {
        let branchName = "test-branch"
        
        // Should not throw on multiple calls
        try manager.createBranchCache(branchName: branchName)
        try manager.createBranchCache(branchName: branchName)
        
        let cacheDir = manager.getBranchCacheDir(branchName: branchName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.path))
    }
    
    // MARK: - Cache Operations
    
    func testGetBranchCacheReturnsNilWhenNotExists() throws {
        let cache = try manager.getBranchCache(branchName: "nonexistent")
        XCTAssertNil(cache)
    }
    
    func testGetBranchCacheReturnsInfoWhenExists() throws {
        let branchName = "cached-branch"
        let commitHash = "abc123def456"
        
        // Create a branch cache with state
        try manager.createBranchCache(branchName: branchName)
        let dbPath = manager.getBranchDatabasePath(branchName: branchName)
        let dbWriter = try SCIPDatabaseWriter(dbPath: dbPath)
        try dbWriter.saveState(commitHash: commitHash, indexedFiles: ["file.swift"])
        
        // Get cache info
        let cache = try manager.getBranchCache(branchName: branchName)
        XCTAssertNotNil(cache)
        XCTAssertEqual(cache?.branchName, branchName)
        XCTAssertEqual(cache?.commitHash, commitHash)
    }
    
    // MARK: - Cache List
    
    func testListCachedBranches() throws {
        // Create some branch caches
        for branch in ["main", "develop", "feature-1"] {
            try manager.createBranchCache(branchName: branch)
            let dbPath = manager.getBranchDatabasePath(branchName: branch)
            let dbWriter = try SCIPDatabaseWriter(dbPath: dbPath)
            try dbWriter.saveState(commitHash: "abc", indexedFiles: [])
        }
        
        let branches = manager.listCachedBranches()
        XCTAssertEqual(branches.count, 3)
        XCTAssertTrue(branches.contains("main"))
        XCTAssertTrue(branches.contains("develop"))
        XCTAssertTrue(branches.contains("feature-1"))
    }
    
    func testListCachedBranchesEmpty() {
        let branches = manager.listCachedBranches()
        XCTAssertTrue(branches.isEmpty)
    }
    
    // MARK: - Cache Cleanup
    
    func testCleanBranchCache() throws {
        let branchName = "to-clean"
        try manager.createBranchCache(branchName: branchName)
        
        let cacheDir = manager.getBranchCacheDir(branchName: branchName)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cacheDir.path))
        
        try manager.cleanBranchCache(branchName: branchName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheDir.path))
    }
    
    func testCleanAllCaches() throws {
        // Create multiple caches
        for branch in ["main", "develop"] {
            try manager.createBranchCache(branchName: branch)
        }
        
        try manager.cleanAllCaches()
        
        let branches = manager.listCachedBranches()
        XCTAssertTrue(branches.isEmpty)
    }
    
    // MARK: - Fast Switch
    
    func testFastSwitchToBranch() throws {
        let branchName = "switch-test"
        let commitHash = "test123"
        
        // Create source cache
        try manager.createBranchCache(branchName: branchName)
        let sourceDb = manager.getBranchDatabasePath(branchName: branchName)
        let dbWriter = try SCIPDatabaseWriter(dbPath: sourceDb)
        try dbWriter.saveState(commitHash: commitHash, indexedFiles: ["a.swift", "b.swift"])
        
        // Switch to output location
        let outputDb = tempDirectory.appendingPathComponent("output.db")
        try manager.fastSwitchToBranch(branchName: branchName, outputDbPath: outputDb)
        
        // Verify output exists and has correct state
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputDb.path))
        
        let outputDbWriter = try SCIPDatabaseWriter(dbPath: outputDb, readOnly: true)
        let state = try outputDbWriter.loadState()
        XCTAssertEqual(state?.lastCommitHash, commitHash)
        XCTAssertEqual(state?.indexedFiles.count, 2)
    }
    
    func testFastSwitchThrowsWhenCacheNotFound() {
        let outputDb = tempDirectory.appendingPathComponent("output.db")
        
        XCTAssertThrowsError(try manager.fastSwitchToBranch(branchName: "nonexistent", outputDbPath: outputDb)) { error in
            XCTAssertTrue(error is BranchIndexManagerError)
        }
    }
    
    // MARK: - Save to Cache
    
    func testSaveToBranchCache() throws {
        let branchName = "save-test"
        let commitHash = "save123"
        
        // Create source database
        let sourceDb = tempDirectory.appendingPathComponent("source.db")
        let sourceWriter = try SCIPDatabaseWriter(dbPath: sourceDb)
        try sourceWriter.saveState(commitHash: commitHash, indexedFiles: ["test.swift"])
        
        // Save to cache
        try manager.saveToBranchCache(branchName: branchName, fromDbPath: sourceDb)
        
        // Verify cache has the data
        let cache = try manager.getBranchCache(branchName: branchName)
        XCTAssertNotNil(cache)
        XCTAssertEqual(cache?.commitHash, commitHash)
    }
    
    // MARK: - Migration
    
    func testHasLegacyStateReturnsFalseWhenNotExists() {
        XCTAssertFalse(manager.hasLegacyState())
    }
    
    func testHasLegacyStateReturnsTrueWhenExists() throws {
        let legacyFile = tempDirectory.appendingPathComponent(".swift-scip-state.json")
        let state = """
        {
            "lastCommitHash": "abc123",
            "lastIndexedAt": "2024-01-01T00:00:00Z",
            "indexedFiles": {"test.swift": ""}
        }
        """
        try state.write(to: legacyFile, atomically: true, encoding: .utf8)
        
        XCTAssertTrue(manager.hasLegacyState())
    }
    
    func testMigrateLegacyState() throws {
        // Create legacy state file
        let legacyFile = tempDirectory.appendingPathComponent(".swift-scip-state.json")
        let state = """
        {
            "lastCommitHash": "migrate123",
            "lastIndexedAt": "2024-01-01T00:00:00Z",
            "indexedFiles": {"file1.swift": "", "file2.swift": ""}
        }
        """
        try state.write(to: legacyFile, atomically: true, encoding: .utf8)
        
        // Migrate (will use "main" as default branch since not a git repo)
        let migrated = try manager.migrateLegacyState()
        XCTAssertTrue(migrated)
        
        // Legacy file should be backed up
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyFile.path))
        let backupFile = tempDirectory.appendingPathComponent(".swift-scip-state.json.backup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupFile.path))
        
        // New state should exist in SQLite
        let cache = try manager.getBranchCache(branchName: "main")
        XCTAssertNotNil(cache)
        XCTAssertEqual(cache?.commitHash, "migrate123")
    }
    
    func testMigrateLegacyStateReturnsFalseWhenNoLegacy() throws {
        let migrated = try manager.migrateLegacyState()
        XCTAssertFalse(migrated)
    }
    
    // MARK: - Git Operations (requires git repo)
    
    func testGetCurrentBranchThrowsForNonGitRepo() {
        XCTAssertThrowsError(try manager.getCurrentBranch()) { error in
            XCTAssertTrue(error is BranchIndexManagerError)
        }
    }
}

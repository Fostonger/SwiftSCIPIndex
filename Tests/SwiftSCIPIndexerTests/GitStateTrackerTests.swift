import XCTest
@testable import SwiftSCIPIndexer

final class GitStateTrackerTests: XCTestCase {
    
    var tempDirectory: URL!
    var tracker: GitStateTracker!
    
    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("GitStateTrackerTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        tracker = GitStateTracker(projectRoot: tempDirectory)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }
    
    func testIsNotGitRepository() {
        // Fresh temp directory is not a git repo
        XCTAssertFalse(tracker.isGitRepository())
    }
    
    func testLoadStateReturnsNilWhenNoState() {
        let state = tracker.loadState()
        XCTAssertNil(state)
    }
    
    func testSaveAndLoadState() throws {
        let files = ["file1.swift", "file2.swift"]
        let commitHash = "abc123def456"
        
        try tracker.saveState(commitHash: commitHash, files: files)
        
        let state = tracker.loadState()
        XCTAssertNotNil(state)
        XCTAssertEqual(state?.lastCommitHash, commitHash)
        XCTAssertEqual(state?.indexedFiles.count, 2)
        XCTAssertTrue(state?.indexedFiles.keys.contains("file1.swift") ?? false)
        XCTAssertTrue(state?.indexedFiles.keys.contains("file2.swift") ?? false)
    }
    
    func testIndexStateEncoding() throws {
        let state = GitStateTracker.IndexState(
            lastCommitHash: "abc123",
            lastIndexedAt: Date(timeIntervalSince1970: 1000000),
            indexedFiles: ["test.swift": ""]
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(state)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(GitStateTracker.IndexState.self, from: data)
        
        XCTAssertEqual(decoded.lastCommitHash, "abc123")
        XCTAssertEqual(decoded.indexedFiles.count, 1)
    }
    
    func testGetChangedFilesReturnsNilWithoutState() throws {
        // Without any saved state, getChangedFiles should return nil
        // Since this is not a git repo, it will return nil (indicating full index needed)
        let changed = try? tracker.getChangedFiles()
        XCTAssertNil(changed, "Should return nil when no state exists")
    }
}


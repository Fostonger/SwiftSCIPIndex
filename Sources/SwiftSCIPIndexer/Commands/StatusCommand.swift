import ArgumentParser
import Foundation

struct StatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Check index state and pending changes"
    )
    
    @Option(name: .long, help: "Path to project root")
    var projectRoot: String
    
    @Flag(name: .long, help: "Show detailed file list")
    var verbose: Bool = false
    
    mutating func run() async throws {
        let projectRootURL = URL(fileURLWithPath: projectRoot)
        let tracker = GitStateTracker(projectRoot: projectRootURL)
        
        print("📊 Index Status")
        print("   Project: \(projectRootURL.path)")
        print("")
        
        // Check git status
        if !tracker.isGitRepository() {
            print("⚠️  Not a git repository")
            print("   Incremental indexing is not available.")
            return
        }
        
        // Load state
        guard let state = tracker.loadState() else {
            print("❌ No index state found")
            print("   Run 'swift-scip-indexer index --incremental' to create initial index.")
            return
        }
        
        // Format date
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let dateStr = formatter.string(from: state.lastIndexedAt)
        
        print("📝 Last Index")
        print("   Date: \(dateStr)")
        print("   Commit: \(state.lastCommitHash.prefix(8))")
        print("   Files indexed: \(state.indexedFiles.count)")
        print("")
        
        // Check current commit
        do {
            let currentHash = try tracker.getCurrentCommitHash()
            print("📍 Current State")
            print("   Commit: \(currentHash.prefix(8))")
            
            if currentHash == state.lastCommitHash {
                print("   Status: Same commit as last index")
            } else {
                print("   Status: \(currentHash.prefix(8)) (different from indexed)")
            }
        } catch {
            print("⚠️  Could not get current commit: \(error.localizedDescription)")
        }
        
        print("")
        
        // Check pending changes
        do {
            if let changed = try tracker.getChangedFiles() {
                if changed.isEmpty {
                    print("✅ No pending changes")
                    print("   Index is up to date.")
                } else {
                    print("📋 Pending Changes: \(changed.count) file(s)")
                    
                    if verbose || changed.count <= 10 {
                        for file in changed.sorted() {
                            print("   - \(file)")
                        }
                    } else {
                        for file in changed.sorted().prefix(10) {
                            print("   - \(file)")
                        }
                        print("   ... and \(changed.count - 10) more")
                    }
                    
                    print("")
                    print("💡 Run 'swift-scip-indexer index --incremental' to update the index.")
                }
            } else {
                print("⚠️  Could not determine pending changes")
            }
        } catch {
            print("⚠️  Error checking pending changes: \(error.localizedDescription)")
        }
    }
}


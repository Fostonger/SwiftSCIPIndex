import ArgumentParser
import Foundation

struct IndexCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "index",
        abstract: "Index Swift project and generate SCIP output"
    )
    
    @Option(name: .long, help: "Path to DerivedData directory")
    var derivedData: String
    
    @Option(name: .long, help: "Path to project root")
    var projectRoot: String
    
    @Option(name: .shortAndLong, help: "Output path for SCIP index (SQLite .db or JSON .json)")
    var output: String
    
    @Flag(name: .long, help: "Only index files changed since last run")
    var incremental: Bool = false
    
    @Flag(name: .long, help: "Force full re-index, ignoring cached state")
    var force: Bool = false
    
    @Option(name: .long, help: "Filter to specific module(s)")
    var module: [String] = []
    
    @Flag(name: .long, inversion: .prefixedNo, help: "Include snippet context in occurrences")
    var includeSnippets: Bool = true
    
    @Flag(name: .long, help: "Verbose output")
    var verbose: Bool = false
    
    @Flag(name: .long, help: "Output as JSON instead of SQLite (legacy format)")
    var json: Bool = false
    
    mutating func run() async throws {
        let derivedDataURL = URL(fileURLWithPath: derivedData)
        let projectRootURL = URL(fileURLWithPath: projectRoot)
        let outputURL = URL(fileURLWithPath: output)
        
        print("📚 Swift SCIP Indexer")
        print("   DerivedData: \(derivedDataURL.path)")
        print("   Project Root: \(projectRootURL.path)")
        print("   Output: \(outputURL.path)")
        print("   Mode: \(force ? "Full (forced)" : incremental ? "Incremental" : "Full")")
        print("")
        
        let branchManager = BranchIndexManager(projectRoot: projectRootURL)
        let tracker = GitStateTracker(projectRoot: projectRootURL)
        
        // Determine output format
        let useJson = json || outputURL.pathExtension.lowercased() == "json"
        
        // If using JSON or not a git repo, use legacy mode
        if useJson || !tracker.isGitRepository() {
            if !tracker.isGitRepository() {
                print("⚠️  Not a git repository, using legacy mode")
            }
            return try await runLegacyMode(
                derivedDataURL: derivedDataURL,
                projectRootURL: projectRootURL,
                outputURL: outputURL
            )
        }
        
        // Check for and migrate legacy state
        if branchManager.hasLegacyState() {
            do {
                if try branchManager.migrateLegacyState() {
                    print("📦 Migrated legacy state to branch-aware format")
                }
            } catch {
                print("⚠️  Failed to migrate legacy state: \(error.localizedDescription)")
            }
        }
        
        // Branch-aware mode with SQLite
        let currentBranch: String
        let currentCommitHash: String
        
        do {
            currentBranch = try branchManager.getCurrentBranch()
            currentCommitHash = try tracker.getCurrentCommitHash()
            print("🌿 Branch: \(currentBranch)")
            print("   Commit: \(currentCommitHash.prefix(8))")
        } catch {
            print("⚠️  Git detection failed: \(error.localizedDescription)")
            return try await runLegacyMode(
                derivedDataURL: derivedDataURL,
                projectRootURL: projectRootURL,
                outputURL: outputURL
            )
        }
        
        // Ensure output has .db extension for SQLite
        let outputDbPath = outputURL.pathExtension.lowercased() == "db"
            ? outputURL
            : outputURL.deletingPathExtension().appendingPathExtension("db")
        
        let startTime = Date()
        
        // Check for cached branch index
        if let branchCache = try? branchManager.getBranchCache(branchName: currentBranch) {
            if branchCache.commitHash == currentCommitHash && !force {
                // Fast path: Same branch, same commit - instant switch
                print("⚡ Fast switch: Using cached index")
                
                do {
                    try branchManager.fastSwitchToBranch(
                        branchName: currentBranch,
                        outputDbPath: outputDbPath
                    )
                    
                    let elapsed = Date().timeIntervalSince(startTime)
                    print("")
                    print("✅ Index restored from cache")
                    print("   Time elapsed: \(String(format: "%.3f", elapsed))s")
                    printFileSize(outputDbPath)
                    return
                } catch {
                    print("⚠️  Cache restore failed: \(error.localizedDescription)")
                    print("   Falling back to full index")
                }
            }
        }
        
        // Determine files to index
        var filesToIndex: [String]? = nil
        var isIncrementalUpdate = false
        
        if incremental && !force {
            do {
                filesToIndex = try tracker.getChangedFilesForBranch(branchName: currentBranch)
                
                if let files = filesToIndex {
                    if files.isEmpty {
                        // No changes - try to use cache
                        let branchDbPath = branchManager.getBranchDatabasePath(branchName: currentBranch)
                        if FileManager.default.fileExists(atPath: branchDbPath.path) {
                            print("✅ No changes detected since last index.")
                            try branchManager.fastSwitchToBranch(
                                branchName: currentBranch,
                                outputDbPath: outputDbPath
                            )
                            
                            // Update state with current commit hash
                            let dbWriter = try SCIPDatabaseWriter(dbPath: outputDbPath)
                            if let state = try dbWriter.loadState() {
                                try dbWriter.saveState(
                                    commitHash: currentCommitHash,
                                    indexedFiles: state.indexedFiles
                                )
                            }
                            
                            // Update cache
                            try branchManager.saveToBranchCache(
                                branchName: currentBranch,
                                fromDbPath: outputDbPath
                            )
                            
                            printFileSize(outputDbPath)
                            return
                        }
                    }
                    
                    isIncrementalUpdate = true
                    print("🔍 Incremental mode: \(files.count) changed file(s)")
                    if verbose {
                        for file in files.prefix(20) {
                            print("   - \(file)")
                        }
                        if files.count > 20 {
                            print("   ... and \(files.count - 20) more")
                        }
                    }
                } else {
                    print("🔍 No previous state found, performing full index")
                }
            } catch {
                print("⚠️  Git state tracking failed: \(error.localizedDescription)")
                print("   Falling back to full index")
            }
        }
        
        // Read index store
        print("📖 Reading index store...")
        
        let reader: IndexStoreReader
        do {
            reader = try IndexStoreReader(
                derivedDataPath: derivedDataURL,
                projectRoot: projectRootURL,
                includeSnippets: includeSnippets
            )
        } catch {
            print("❌ Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
        
        // Collect data
        print("🔎 Collecting symbols...")
        let symbols = reader.collectSymbols()
        print("   Found \(symbols.count) symbols")
        
        if verbose {
            let symbolsByKind = Dictionary(grouping: symbols, by: \.kind)
            for (kind, kindSymbols) in symbolsByKind.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                print("   - \(kind.rawValue): \(kindSymbols.count)")
            }
        }
        
        print("🔎 Collecting occurrences...")
        let occurrences = reader.collectOccurrences(forFiles: filesToIndex)
        print("   Found \(occurrences.count) occurrences")
        
        if verbose {
            let fileCount = Set(occurrences.map(\.filePath)).count
            print("   - Across \(fileCount) files")
            
            let definitions = occurrences.filter { $0.role.contains(.definition) }.count
            let references = occurrences.filter { $0.role.contains(.reference) }.count
            print("   - Definitions: \(definitions)")
            print("   - References: \(references)")
        }
        
        print("🔎 Resolving relationships...")
        let relationships = reader.collectRelationships()
        print("   Found \(relationships.count) relationships")
        
        // Write to SQLite database
        print("💾 Writing SCIP index to database...")
        do {
            // Ensure output directory exists
            try FileManager.default.createDirectory(
                at: outputDbPath.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            
            // Remove existing output if present
            if FileManager.default.fileExists(atPath: outputDbPath.path) {
                try FileManager.default.removeItem(at: outputDbPath)
            }
            
            let branchDbPath = branchManager.getBranchDatabasePath(branchName: currentBranch)
            
            if isIncrementalUpdate, let changedFiles = filesToIndex,
               FileManager.default.fileExists(atPath: branchDbPath.path) {
                // Incremental update mode
                print("   Performing incremental update...")
                
                // Copy existing cache to output location
                try branchManager.fastSwitchToBranch(
                    branchName: currentBranch,
                    outputDbPath: outputDbPath
                )
                
                // Open output database and update
                let dbWriter = try SCIPDatabaseWriter(dbPath: outputDbPath)
                
                // Get deleted files
                if let state = try dbWriter.loadState() {
                    let deletedFiles = try tracker.getDeletedFilesSince(commit: state.lastCommitHash)
                    if !deletedFiles.isEmpty {
                        print("   Removing \(deletedFiles.count) deleted file(s)...")
                        try dbWriter.deleteDocuments(filePaths: deletedFiles)
                    }
                }
                
                // Update changed files
                try dbWriter.updateDocuments(
                    filePaths: changedFiles,
                    symbols: symbols,
                    occurrences: occurrences
                )
                
                // Update state
                let allFiles = try dbWriter.getIndexedFilePaths()
                try dbWriter.saveState(commitHash: currentCommitHash, indexedFiles: allFiles)
                
            } else {
                // Full index mode
                print("   Performing full index...")
                
                // Create branch cache directory
                try branchManager.createBranchCache(branchName: currentBranch)
                
                let dbWriter = try SCIPDatabaseWriter(dbPath: outputDbPath)
                try dbWriter.write(
                    symbols: symbols,
                    occurrences: occurrences,
                    projectRoot: projectRootURL
                )
                
                // Save state
                let files = Array(Set(occurrences.map(\.filePath)))
                try dbWriter.saveState(commitHash: currentCommitHash, indexedFiles: files)
            }
            
            // Save to branch cache
            try branchManager.saveToBranchCache(
                branchName: currentBranch,
                fromDbPath: outputDbPath
            )
            
        } catch {
            print("❌ Error writing output: \(error.localizedDescription)")
            throw ExitCode.failure
        }
        
        // Clear snippet cache
        SnippetExtractor.clearCache()
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("")
        print("✅ Done! Index written to \(outputDbPath.path)")
        print("   Time elapsed: \(String(format: "%.2f", elapsed))s")
        printFileSize(outputDbPath)
        
        if verbose && incremental {
            print("📝 Index state saved for branch '\(currentBranch)' at commit \(currentCommitHash.prefix(8))")
        }
    }
    
    /// Legacy mode for JSON output or non-git repositories
    private func runLegacyMode(
        derivedDataURL: URL,
        projectRootURL: URL,
        outputURL: URL
    ) async throws {
        var filesToIndex: [String]? = nil
        
        if incremental && !force {
            let tracker = GitStateTracker(projectRoot: projectRootURL)
            
            if tracker.isGitRepository() {
                do {
                    filesToIndex = try tracker.getChangedFiles()
                    
                    if let files = filesToIndex {
                        if files.isEmpty {
                            print("✅ No changes detected since last index. Nothing to do.")
                            return
                        }
                        print("🔍 Incremental mode: \(files.count) changed file(s)")
                        if verbose {
                            for file in files.prefix(20) {
                                print("   - \(file)")
                            }
                            if files.count > 20 {
                                print("   ... and \(files.count - 20) more")
                            }
                        }
                    } else {
                        print("🔍 No previous state found, performing full index")
                    }
                } catch {
                    print("⚠️  Git state tracking failed: \(error.localizedDescription)")
                    print("   Falling back to full index")
                }
            }
        }
        
        // Read index store
        print("📖 Reading index store...")
        let startTime = Date()
        
        let reader: IndexStoreReader
        do {
            reader = try IndexStoreReader(
                derivedDataPath: derivedDataURL,
                projectRoot: projectRootURL,
                includeSnippets: includeSnippets
            )
        } catch {
            print("❌ Error: \(error.localizedDescription)")
            throw ExitCode.failure
        }
        
        // Collect data
        print("🔎 Collecting symbols...")
        let symbols = reader.collectSymbols()
        print("   Found \(symbols.count) symbols")
        
        if verbose {
            let symbolsByKind = Dictionary(grouping: symbols, by: \.kind)
            for (kind, kindSymbols) in symbolsByKind.sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                print("   - \(kind.rawValue): \(kindSymbols.count)")
            }
        }
        
        print("🔎 Collecting occurrences...")
        let occurrences = reader.collectOccurrences(forFiles: filesToIndex)
        print("   Found \(occurrences.count) occurrences")
        
        if verbose {
            let fileCount = Set(occurrences.map(\.filePath)).count
            print("   - Across \(fileCount) files")
            
            let definitions = occurrences.filter { $0.role.contains(.definition) }.count
            let references = occurrences.filter { $0.role.contains(.reference) }.count
            print("   - Definitions: \(definitions)")
            print("   - References: \(references)")
        }
        
        print("🔎 Resolving relationships...")
        let relationships = reader.collectRelationships()
        print("   Found \(relationships.count) relationships")
        
        // Write output
        print("💾 Writing SCIP index...")
        do {
            try SCIPJSONWriter.write(
                symbols: symbols,
                occurrences: occurrences,
                projectRoot: projectRootURL,
                to: outputURL
            )
        } catch {
            print("❌ Error writing output: \(error.localizedDescription)")
            throw ExitCode.failure
        }
        
        // Save state for incremental updates
        if incremental && !force {
            let tracker = GitStateTracker(projectRoot: projectRootURL)
            if tracker.isGitRepository() {
                do {
                    let commitHash = try tracker.getCurrentCommitHash()
                    let files = Array(Set(occurrences.map(\.filePath)))
                    try tracker.saveState(commitHash: commitHash, files: files)
                    if verbose {
                        print("📝 Saved index state for commit \(commitHash.prefix(8))")
                    }
                } catch {
                    print("⚠️  Could not save index state: \(error.localizedDescription)")
                }
            }
        }
        
        // Clear snippet cache
        SnippetExtractor.clearCache()
        
        let elapsed = Date().timeIntervalSince(startTime)
        print("")
        print("✅ Done! Index written to \(outputURL.path)")
        print("   Time elapsed: \(String(format: "%.2f", elapsed))s")
        printFileSize(outputURL)
    }
    
    private func printFileSize(_ url: URL) {
        if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
           let size = attrs[.size] as? Int64 {
            let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            print("   Output size: \(sizeStr)")
        }
    }
}

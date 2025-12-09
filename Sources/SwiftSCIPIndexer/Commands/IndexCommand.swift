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
    
    @Option(name: .shortAndLong, help: "Output path for SCIP JSON file")
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
        
        // Determine files to index
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
            } else {
                print("⚠️  Not a git repository, performing full index")
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
        
        // Print file size
        if let attrs = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
           let size = attrs[.size] as? Int64 {
            let sizeStr = ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
            print("   Output size: \(sizeStr)")
        }
    }
}


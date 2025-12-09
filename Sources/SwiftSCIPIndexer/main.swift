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


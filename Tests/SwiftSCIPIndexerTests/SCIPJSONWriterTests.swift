import XCTest
@testable import SwiftSCIPIndexer

final class SCIPJSONWriterTests: XCTestCase {
    
    var tempDirectory: URL!
    
    override func setUp() {
        super.setUp()
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SCIPJSONWriterTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }
    
    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDirectory)
        super.tearDown()
    }
    
    func testWriteEmptyIndex() throws {
        let outputURL = tempDirectory.appendingPathComponent("output.scip.json")
        let projectRoot = URL(fileURLWithPath: "/test/project")
        
        try SCIPJSONWriter.write(
            symbols: [],
            occurrences: [],
            projectRoot: projectRoot,
            to: outputURL
        )
        
        // Verify file exists
        XCTAssertTrue(FileManager.default.fileExists(atPath: outputURL.path))
        
        // Verify content
        let data = try Data(contentsOf: outputURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        XCTAssertNotNil(json["metadata"])
        XCTAssertNotNil(json["documents"])
        
        let documents = json["documents"] as! [[String: Any]]
        XCTAssertEqual(documents.count, 0)
    }
    
    func testWriteWithSymbolsAndOccurrences() throws {
        let outputURL = tempDirectory.appendingPathComponent("output.scip.json")
        let projectRoot = URL(fileURLWithPath: "/test/project")
        
        let symbol = IndexedSymbol(
            symbolID: "swift TestModule TestClass#",
            name: "TestClass",
            kind: .class,
            module: "TestModule",
            documentation: ["A test class"],
            relationships: []
        )
        
        let occurrence = IndexedOccurrence(
            symbolID: "swift TestModule TestClass#",
            filePath: "Sources/TestClass.swift",
            range: SourceRange(startLine: 5, startColumn: 6, endLine: 5, endColumn: 15),
            role: .definition,
            snippet: "class TestClass {",
            enclosingSymbol: nil,
            enclosingName: nil
        )
        
        try SCIPJSONWriter.write(
            symbols: [symbol],
            occurrences: [occurrence],
            projectRoot: projectRoot,
            to: outputURL
        )
        
        // Verify content
        let data = try Data(contentsOf: outputURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        // Check metadata
        let metadata = json["metadata"] as! [String: Any]
        XCTAssertEqual(metadata["version"] as? Int, 1)
        XCTAssertEqual(metadata["projectRoot"] as? String, "file:///test/project")
        
        let toolInfo = metadata["toolInfo"] as! [String: Any]
        XCTAssertEqual(toolInfo["name"] as? String, "swift-scip-indexer")
        
        // Check documents
        let documents = json["documents"] as! [[String: Any]]
        XCTAssertEqual(documents.count, 1)
        
        let doc = documents[0]
        XCTAssertEqual(doc["relativePath"] as? String, "Sources/TestClass.swift")
        XCTAssertEqual(doc["language"] as? String, "swift")
        
        // Check symbols in document
        let docSymbols = doc["symbols"] as! [[String: Any]]
        XCTAssertEqual(docSymbols.count, 1)
        XCTAssertEqual(docSymbols[0]["symbol"] as? String, "swift TestModule TestClass#")
        XCTAssertEqual(docSymbols[0]["kind"] as? String, "class")
        
        // Check occurrences in document
        let docOccurrences = doc["occurrences"] as! [[String: Any]]
        XCTAssertEqual(docOccurrences.count, 1)
        XCTAssertEqual(docOccurrences[0]["symbol"] as? String, "swift TestModule TestClass#")
        XCTAssertEqual(docOccurrences[0]["symbolRoles"] as? Int, 1)
        XCTAssertEqual(docOccurrences[0]["snippet"] as? String, "class TestClass {")
    }
    
    func testWriteWithRelationships() throws {
        let outputURL = tempDirectory.appendingPathComponent("output.scip.json")
        let projectRoot = URL(fileURLWithPath: "/test/project")
        
        let symbol = IndexedSymbol(
            symbolID: "swift TestModule Child#",
            name: "Child",
            kind: .class,
            module: "TestModule",
            documentation: [],
            relationships: [
                SymbolRelationship(
                    targetSymbolID: "swift TestModule Parent#",
                    kind: .inherits
                )
            ]
        )
        
        let occurrence = IndexedOccurrence(
            symbolID: "swift TestModule Child#",
            filePath: "Sources/Child.swift",
            range: SourceRange(startLine: 1, startColumn: 6, endLine: 1, endColumn: 11),
            role: .definition,
            snippet: nil,
            enclosingSymbol: nil,
            enclosingName: nil
        )
        
        try SCIPJSONWriter.write(
            symbols: [symbol],
            occurrences: [occurrence],
            projectRoot: projectRoot,
            to: outputURL
        )
        
        // Verify relationships
        let data = try Data(contentsOf: outputURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        let documents = json["documents"] as! [[String: Any]]
        let doc = documents[0]
        let docSymbols = doc["symbols"] as! [[String: Any]]
        let relationships = docSymbols[0]["relationships"] as! [[String: Any]]
        
        XCTAssertEqual(relationships.count, 1)
        XCTAssertEqual(relationships[0]["symbol"] as? String, "swift TestModule Parent#")
        XCTAssertEqual(relationships[0]["isTypeDefinition"] as? Bool, true)
    }
    
    func testSCIPRangeFormat() throws {
        let outputURL = tempDirectory.appendingPathComponent("output.scip.json")
        let projectRoot = URL(fileURLWithPath: "/test/project")
        
        // Single-line occurrence
        let singleLineOccurrence = IndexedOccurrence(
            symbolID: "swift Test func1().",
            filePath: "test.swift",
            range: SourceRange(startLine: 10, startColumn: 5, endLine: 10, endColumn: 15),
            role: .reference,
            snippet: nil,
            enclosingSymbol: nil,
            enclosingName: nil
        )
        
        // Multi-line occurrence
        let multiLineOccurrence = IndexedOccurrence(
            symbolID: "swift Test func2().",
            filePath: "test.swift",
            range: SourceRange(startLine: 20, startColumn: 5, endLine: 25, endColumn: 10),
            role: .reference,
            snippet: nil,
            enclosingSymbol: nil,
            enclosingName: nil
        )
        
        try SCIPJSONWriter.write(
            symbols: [],
            occurrences: [singleLineOccurrence, multiLineOccurrence],
            projectRoot: projectRoot,
            to: outputURL
        )
        
        let data = try Data(contentsOf: outputURL)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        
        let documents = json["documents"] as! [[String: Any]]
        let doc = documents[0]
        let occurrences = doc["occurrences"] as! [[String: Any]]
        
        // Find single-line and multi-line occurrences
        let singleLine = occurrences.first { ($0["symbol"] as? String) == "swift Test func1()." }!
        let multiLine = occurrences.first { ($0["symbol"] as? String) == "swift Test func2()." }!
        
        // Single line should have 3 elements
        let singleLineRange = singleLine["range"] as! [Int]
        XCTAssertEqual(singleLineRange.count, 3)
        
        // Multi-line should have 4 elements
        let multiLineRange = multiLine["range"] as! [Int]
        XCTAssertEqual(multiLineRange.count, 4)
    }
}

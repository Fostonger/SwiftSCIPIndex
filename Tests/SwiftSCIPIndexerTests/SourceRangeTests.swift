import XCTest
@testable import SwiftSCIPIndexer

final class SourceRangeTests: XCTestCase {
    
    func testSingleLineRange() {
        let range = SourceRange(
            startLine: 10,
            startColumn: 5,
            endLine: 10,
            endColumn: 15
        )
        
        let scipRange = range.asSCIPRange
        
        XCTAssertEqual(scipRange.count, 3)
        XCTAssertEqual(scipRange[0], 10)  // startLine
        XCTAssertEqual(scipRange[1], 5)   // startColumn
        XCTAssertEqual(scipRange[2], 15)  // endColumn
    }
    
    func testMultiLineRange() {
        let range = SourceRange(
            startLine: 10,
            startColumn: 5,
            endLine: 15,
            endColumn: 20
        )
        
        let scipRange = range.asSCIPRange
        
        XCTAssertEqual(scipRange.count, 4)
        XCTAssertEqual(scipRange[0], 10)  // startLine
        XCTAssertEqual(scipRange[1], 5)   // startColumn
        XCTAssertEqual(scipRange[2], 15)  // endLine
        XCTAssertEqual(scipRange[3], 20)  // endColumn
    }
    
    func testZeroIndexedRange() {
        let range = SourceRange(
            startLine: 0,
            startColumn: 0,
            endLine: 0,
            endColumn: 10
        )
        
        let scipRange = range.asSCIPRange
        
        XCTAssertEqual(scipRange.count, 3)
        XCTAssertEqual(scipRange[0], 0)
        XCTAssertEqual(scipRange[1], 0)
        XCTAssertEqual(scipRange[2], 10)
    }
    
    func testSingleCharacterRange() {
        let range = SourceRange(
            startLine: 5,
            startColumn: 10,
            endLine: 5,
            endColumn: 11
        )
        
        let scipRange = range.asSCIPRange
        
        XCTAssertEqual(scipRange.count, 3)
        XCTAssertEqual(scipRange[0], 5)
        XCTAssertEqual(scipRange[1], 10)
        XCTAssertEqual(scipRange[2], 11)
    }
}


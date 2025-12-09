import XCTest
@testable import SwiftSCIPIndexer

final class SymbolRoleTests: XCTestCase {
    
    func testDefinitionRole() {
        let role = SCIPSymbolRole.definition
        XCTAssertEqual(role.rawValue, 1)
        XCTAssertTrue(role.contains(.definition))
        XCTAssertFalse(role.contains(.reference))
    }
    
    func testReferenceRole() {
        let role = SCIPSymbolRole.reference
        XCTAssertEqual(role.rawValue, 8)
        XCTAssertTrue(role.contains(.reference))
        XCTAssertTrue(role.contains(.readAccess))  // Alias
    }
    
    func testReadAccessAlias() {
        // reference and readAccess should be equivalent
        XCTAssertEqual(SCIPSymbolRole.reference.rawValue, SCIPSymbolRole.readAccess.rawValue)
    }
    
    func testCombinedRoles() {
        var role = SCIPSymbolRole.definition
        role.insert(.writeAccess)
        
        XCTAssertEqual(role.rawValue, 5)  // 1 + 4
        XCTAssertTrue(role.contains(.definition))
        XCTAssertTrue(role.contains(.writeAccess))
        XCTAssertFalse(role.contains(.reference))
    }
    
    func testAllRoles() {
        var role = SCIPSymbolRole()
        role.insert(.definition)
        role.insert(.import)
        role.insert(.writeAccess)
        role.insert(.readAccess)
        role.insert(.generated)
        role.insert(.test)
        
        // 1 + 2 + 4 + 8 + 16 + 32 = 63
        XCTAssertEqual(role.rawValue, 63)
    }
    
    func testEmptyRole() {
        let role = SCIPSymbolRole()
        XCTAssertEqual(role.rawValue, 0)
        XCTAssertTrue(role.isEmpty)
    }
}

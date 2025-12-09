import XCTest
@testable import SwiftSCIPIndexer

final class SCIPSymbolBuilderTests: XCTestCase {
    
    func testClassSymbolID() {
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "s:8MyModule7MyClassC",
            name: "MyClass",
            kind: .class,
            module: "MyModule"
        )
        
        XCTAssertEqual(symbolID, "swift MyModule MyClass#")
    }
    
    func testStructSymbolID() {
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "s:8MyModule8MyStructV",
            name: "MyStruct",
            kind: .struct,
            module: "MyModule"
        )
        
        XCTAssertEqual(symbolID, "swift MyModule MyStruct#")
    }
    
    func testProtocolSymbolID() {
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "s:8MyModule10MyProtocolP",
            name: "MyProtocol",
            kind: .protocol,
            module: "MyModule"
        )
        
        XCTAssertEqual(symbolID, "swift MyModule MyProtocol#")
    }
    
    func testEnumSymbolID() {
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "s:8MyModule6MyEnumO",
            name: "MyEnum",
            kind: .enum,
            module: "MyModule"
        )
        
        XCTAssertEqual(symbolID, "swift MyModule MyEnum#")
    }
    
    func testMethodSymbolID() {
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "s:8MyModule7MyClassC9doSomethingyyF",
            name: "doSomething",
            kind: .function,
            module: "MyModule"
        )
        
        XCTAssertEqual(symbolID, "swift MyModule doSomething().")
    }
    
    func testPropertySymbolID() {
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "s:8MyModule7MyClassC8propertySSvp",
            name: "property",
            kind: .property,
            module: "MyModule"
        )
        
        XCTAssertEqual(symbolID, "swift MyModule property.")
    }
    
    func testEnumCaseSymbolID() {
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "s:8MyModule6MyEnumO5caseAyA2CmF",
            name: "caseA",
            kind: .enumCase,
            module: "MyModule"
        )
        
        XCTAssertEqual(symbolID, "swift MyModule caseA.")
    }
    
    func testTypeAliasSymbolID() {
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "s:8MyModule11MyTypeAliasa",
            name: "MyTypeAlias",
            kind: .typeAlias,
            module: "MyModule"
        )
        
        XCTAssertEqual(symbolID, "swift MyModule MyTypeAlias#")
    }
    
    func testLocalSymbolID() {
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "local_123",
            name: "temp",
            kind: .local,
            module: nil
        )
        
        XCTAssertTrue(symbolID.hasPrefix("local "))
    }
    
    func testLocalSymbolWithoutSwiftUSR() {
        // USRs that don't start with "s:" are treated as local
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "c:objc(cs)NSObject",
            name: "NSObject",
            kind: .class,
            module: "Foundation"
        )
        
        XCTAssertTrue(symbolID.hasPrefix("local "))
    }
    
    func testSymbolWithNoModule() {
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "s:SomeUSR",
            name: "Something",
            kind: .function,
            module: nil
        )
        
        XCTAssertTrue(symbolID.hasPrefix("local "))
    }
    
    func testContainedMethodSymbolID() {
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "s:8MyModule7MyClassC9doSomethingyyF",
            name: "doSomething",
            kind: .function,
            module: "MyModule",
            containerName: "MyClass"
        )
        
        XCTAssertEqual(symbolID, "swift MyModule MyClass#doSomething().")
    }
    
    func testContainedPropertySymbolID() {
        let symbolID = SCIPSymbolBuilder.buildSymbolID(
            usr: "s:8MyModule7MyClassC4nameSSvp",
            name: "name",
            kind: .property,
            module: "MyModule",
            containerName: "MyClass"
        )
        
        XCTAssertEqual(symbolID, "swift MyModule MyClass#name.")
    }
}


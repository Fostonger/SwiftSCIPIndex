import Foundation

/// Represents a range in source code
struct SourceRange: Codable, Sendable {
    let startLine: Int          // 0-indexed
    let startColumn: Int
    let endLine: Int
    let endColumn: Int
    
    /// Convert to SCIP range format
    /// - Single-line: [startLine, startCol, endCol] (3 elements)
    /// - Multi-line: [startLine, startCol, endLine, endCol] (4 elements)
    var asSCIPRange: [Int] {
        if startLine == endLine {
            return [startLine, startColumn, endColumn]
        }
        return [startLine, startColumn, endLine, endColumn]
    }
}


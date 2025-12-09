import Foundation

/// Extracts code snippets from source files
struct SnippetExtractor {
    
    /// Cache for file contents to avoid repeated disk reads
    private static var fileCache: [URL: [String]] = [:]
    
    /// Extract a code snippet around a source location
    /// - Parameters:
    ///   - file: URL of the source file
    ///   - line: Line number (0-indexed)
    ///   - contextLines: Number of context lines before and after (default: 0)
    /// - Returns: The snippet string, or nil if extraction failed
    static func extractSnippet(
        file: URL,
        line: Int,
        contextLines: Int = 0
    ) -> String? {
        let lines: [String]
        
        // Check cache first
        if let cached = fileCache[file] {
            lines = cached
        } else {
            guard let content = try? String(contentsOf: file, encoding: .utf8) else {
                return nil
            }
            lines = content.components(separatedBy: .newlines)
            fileCache[file] = lines
        }
        
        let startLine = max(0, line - contextLines)
        let endLine = min(lines.count - 1, line + contextLines)
        
        guard startLine <= endLine, startLine < lines.count else {
            return nil
        }
        
        return lines[startLine...endLine].joined(separator: "\n")
    }
    
    /// Clear the file cache (useful for memory management in large projects)
    static func clearCache() {
        fileCache.removeAll()
    }
    
    /// Extract a single line from a file
    /// - Parameters:
    ///   - file: URL of the source file
    ///   - line: Line number (0-indexed)
    /// - Returns: The line content, or nil if extraction failed
    static func extractLine(file: URL, line: Int) -> String? {
        return extractSnippet(file: file, line: line, contextLines: 0)
    }
}


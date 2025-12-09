# Swift SCIP Indexer

A command-line tool that generates [SCIP](https://github.com/sourcegraph/scip) (Source Code Intelligence Protocol) indexes from Xcode's DerivedData for Swift projects. SCIP indexes enable powerful code navigation, search, and intelligence features in editors and code analysis tools.

## Features

- **Index Generation**: Extracts symbols, occurrences, and relationships from Xcode's index store
- **Incremental Indexing**: Only re-indexes changed files using git state tracking
- **Branch-Aware Caching**: Maintains separate index caches per git branch for fast branch switching
- **Multiple Output Formats**: Supports SQLite (`.db`) and JSON (`.json`) output formats
- **Performance Optimized**: Uses SQLite for efficient storage and fast queries on large codebases
- **Status Tracking**: Check index state and see pending changes

## Requirements

- macOS 13.0 or later
- Swift 5.9 or later
- Xcode with a built project (DerivedData must exist)
- Git repository (for incremental and branch-aware features)

## Installation

### Building from Source

```bash
git clone <repository-url>
cd SwiftSCIPIndex
swift build -c release
```

The executable will be available at `.build/release/swift-scip-indexer`.

### Installing System-Wide

After building, you can install it system-wide:

```bash
swift build -c release
cp .build/release/swift-scip-indexer /usr/local/bin/
```

## Usage

### Basic Indexing

Generate a full SCIP index for your Swift project:

```bash
swift-scip-indexer index \
    --derived-data ~/Library/Developer/Xcode/DerivedData \
    --project-root /path/to/your/project \
    --output /path/to/output.scip.db
```

**Note**: The default DerivedData location is `~/Library/Developer/Xcode/DerivedData`. You can find your project's specific DerivedData path in Xcode's preferences under Locations → Derived Data.

### Finding Your DerivedData Path

1. Open Xcode
2. Go to **Xcode → Settings → Locations**
3. Check the **Derived Data** path
4. Look for a folder matching your project name (e.g., `YourProject-xxxxx`)

### Incremental Indexing

Only index files that have changed since the last run:

```bash
swift-scip-indexer index \
    --derived-data ~/Library/Developer/Xcode/DerivedData \
    --project-root /path/to/your/project \
    --output /path/to/output.scip.db \
    --incremental
```

Incremental mode uses git to track which files have changed, significantly speeding up indexing for large projects.

### Check Index Status

View the current index state and see what files need to be re-indexed:

```bash
swift-scip-indexer status \
    --project-root /path/to/your/project
```

For detailed file listings:

```bash
swift-scip-indexer status \
    --project-root /path/to/your/project \
    --verbose
```

### Force Full Re-index

Force a complete re-index, ignoring any cached state:

```bash
swift-scip-indexer index \
    --derived-data ~/Library/Developer/Xcode/DerivedData \
    --project-root /path/to/your/project \
    --output /path/to/output.scip.db \
    --force
```

### JSON Output (Legacy Format)

Generate JSON output instead of SQLite:

```bash
swift-scip-indexer index \
    --derived-data ~/Library/Developer/Xcode/DerivedData \
    --project-root /path/to/your/project \
    --output /path/to/output.scip.json \
    --json
```

**Note**: JSON format is less efficient for large codebases. SQLite format is recommended for projects with more than a few hundred files.

### Verbose Output

Get detailed information about the indexing process:

```bash
swift-scip-indexer index \
    --derived-data ~/Library/Developer/Xcode/DerivedData \
    --project-root /path/to/your/project \
    --output /path/to/output.scip.db \
    --verbose
```

### Module Filtering

Index only specific modules:

```bash
swift-scip-indexer index \
    --derived-data ~/Library/Developer/Xcode/DerivedData \
    --project-root /path/to/your/project \
    --output /path/to/output.scip.db \
    --module MyModule --module AnotherModule
```

### Disable Snippet Context

Exclude code snippets from occurrences (reduces output size):

```bash
swift-scip-indexer index \
    --derived-data ~/Library/Developer/Xcode/DerivedData \
    --project-root /path/to/your/project \
    --output /path/to/output.scip.db \
    --no-include-snippets
```

## Branch-Aware Indexing

The indexer automatically detects your current git branch and maintains separate index caches for each branch. This enables:

- **Fast Branch Switching**: When switching to a previously indexed branch, the index is restored instantly from cache
- **Efficient Updates**: Only changed files are re-indexed when switching branches
- **Automatic State Management**: Index state is tracked per branch and commit

Branch caches are stored in `.swift-scip-index/branches/` within your project root.

## How It Works

1. **Reads Index Store**: The tool reads from Xcode's IndexStoreDB, which contains symbol and occurrence information from your project's build
2. **Extracts Data**: Collects symbols (classes, functions, variables, etc.), their occurrences (definitions and references), and relationships
3. **Generates SCIP**: Converts the index store data into SCIP format
4. **Writes Output**: Saves the index as either SQLite database or JSON file

## Output Format

### SQLite Format (Recommended)

The SQLite format (`.db`) provides:
- Efficient storage (~30-50% smaller than JSON)
- Fast queries without loading entire database
- Incremental updates
- Scalability for large codebases (100GB+)

### JSON Format (Legacy)

The JSON format (`.json`) is available for compatibility but is less efficient for large projects.

## Project Structure

The indexer stores its state in `.swift-scip-index/` within your project root:

```
.swift-scip-index/
├── branches/
│   ├── main/
│   │   └── index.db
│   └── feature-branch/
│       └── index.db
└── state.json (legacy, if present)
```

## Troubleshooting

### "Index store not found"

Make sure:
1. Your project has been built in Xcode at least once
2. The DerivedData path is correct
3. The DerivedData folder contains your project's build artifacts

### "Not a git repository"

Incremental and branch-aware features require a git repository. The tool will fall back to legacy mode for non-git projects.

### Slow indexing on large projects

- Use `--incremental` flag for faster subsequent runs
- Consider using SQLite format instead of JSON
- Use `--module` to index only specific modules

## Related Projects

- [SCIP](https://github.com/sourcegraph/scip) - Source Code Intelligence Protocol
- [IndexStoreDB](https://github.com/apple/swift-indexstore-db) - Swift Index Store Database library

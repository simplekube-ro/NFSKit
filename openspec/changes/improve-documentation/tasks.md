## 1. Architecture Document

- [x] 1.1 Create `docs/ARCHITECTURE.md` with layer stack section and Mermaid diagram showing NFSClient → NFSEventLoop → C bridge → Libnfs.xcframework
- [x] 1.2 Add event loop design section with Mermaid sequence diagram showing DispatchSource I/O flow, serial queue confinement, and continuation registry pattern
- [x] 1.3 Add pipeline system section explaining AIMD congestion control, bulk/metadata classification, and PipelineController behavior
- [x] 1.4 Add connection lifecycle section with Mermaid sequence diagram showing portmapper → mountd → nfsd steps and DispatchSource recreation at each fd change
- [x] 1.5 Add C bridge module section explaining Sources/nfs/ structure, shim headers, cSettings, and XCFramework build pipeline
- [x] 1.6 Add memory management section covering Unmanaged callback pointers, ReadBuffer ARC wrappers, and file handle cleanup
- [x] 1.7 Add thread safety model section documenting Sendable types, serial queue confinement, and non-thread-safe components (NFSDirectory)

## 2. API Reference

- [x] 2.1 Create `docs/API.md` with NFSClient section: initializer, connection methods (connect, disconnect, listExports), with full signatures, parameters, errors
- [x] 2.2 Add NFSClient file operations section: openFile, contents, write, with progress callback semantics and zero-copy threshold documentation
- [x] 2.3 Add NFSClient directory operations section: contentsOfDirectory, createDirectory, removeDirectory
- [x] 2.4 Add NFSClient file metadata section: attributesOfItem, removeFile, moveItem, truncateFile, removeItem, readlink
- [x] 2.5 Add NFSClient performance tuning section: configurePerformance, setSecurity — noting must-call-before-connect constraint
- [x] 2.6 Add NFSClient diagnostics section: stats, serverAddress
- [x] 2.7 Add NFSFileHandle section: all read/write/seek/metadata methods with lifecycle documentation
- [x] 2.8 Add NFSSecurity enum section with all cases and their authentication descriptions
- [x] 2.9 Add NFSStats struct section with all 7 counter properties and cumulative semantics
- [x] 2.10 Add error handling section with common POSIXError codes and their NFSKit-specific meanings
- [x] 2.11 Add concurrency guarantees section documenting Sendable conformance and @Sendable closures
- [x] 2.12 Add URLResourceKey attributes table listing all keys returned by directory/attribute operations

## 3. README Revision

- [x] 3.1 Rewrite README.md header with project description and badges (Swift version, platforms, license)
- [x] 3.2 Add features section with key capability highlights
- [x] 3.3 Rewrite installation section with current SPM instructions
- [x] 3.4 Replace all callback-based examples with async/await examples: listing exports, connecting, directory listing, reading files, writing files, file operations
- [x] 3.5 Add platform support matrix section
- [x] 3.6 Add documentation links section pointing to docs/ARCHITECTURE.md and docs/API.md
- [x] 3.7 Revise license section with clear dual-license notice (MIT + LGPL v2.1)

## 4. Verification

- [x] 4.1 Verify all internal links between README, ARCHITECTURE.md, and API.md resolve correctly
- [x] 4.2 Verify Mermaid diagrams render correctly in GitHub-flavored Markdown
- [x] 4.3 Verify all method signatures in API.md match the current source code

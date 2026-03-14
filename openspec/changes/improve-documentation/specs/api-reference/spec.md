## ADDED Requirements

### Requirement: API reference documents NFSClient public interface
The API reference SHALL document all public methods on NFSClient with their full Swift signatures, parameter descriptions, return types, thrown errors, and usage notes.

#### Scenario: Developer looks up NFSClient.connect
- **WHEN** a developer searches the API reference for connection methods
- **THEN** they find `connect(export:)`, `disconnect()`, and `listExports()` with full signatures, parameter descriptions, and error conditions

#### Scenario: Developer looks up file operations
- **WHEN** a developer searches for file read/write methods
- **THEN** they find `contents(atPath:progress:)` and `write(data:toPath:progress:)` with documentation of the progress callback semantics (return `false` to cancel) and the zero-copy threshold behavior

#### Scenario: Developer looks up performance tuning
- **WHEN** a developer searches for performance configuration
- **THEN** they find `configurePerformance(readMax:writeMax:autoReconnect:retransmissions:timeout:)` with documentation noting it MUST be called before `connect(export:)` and describing each parameter's effect

### Requirement: API reference documents NFSFileHandle public interface
The API reference SHALL document all public methods on NFSFileHandle including read, write, seek, and metadata operations.

#### Scenario: Developer looks up file handle I/O
- **WHEN** a developer searches for file handle methods
- **THEN** they find `read(count:)`, `pread(offset:count:)`, `write(data:)`, `pwrite(data:offset:)`, `lseek(offset:whence:)`, `fsync()`, `fstat()`, and `ftruncate(toLength:)` with full signatures

#### Scenario: Developer understands handle lifecycle
- **WHEN** a developer reads the NFSFileHandle section
- **THEN** they understand that handles are obtained via `NFSClient.openFile(atPath:flags:)` and automatically closed when the handle is deallocated

### Requirement: API reference documents NFSSecurity enum
The API reference SHALL document all cases of NFSSecurity with descriptions of each authentication mode.

#### Scenario: Developer looks up security modes
- **WHEN** a developer reads the NFSSecurity section
- **THEN** they find `.system`, `.kerberos5`, `.kerberos5i`, and `.kerberos5p` with descriptions of what each mode provides (AUTH_SYS, Kerberos auth, integrity, privacy)

### Requirement: API reference documents NFSStats struct
The API reference SHALL document all properties of NFSStats with descriptions of what each counter measures.

#### Scenario: Developer interprets RPC statistics
- **WHEN** a developer reads the NFSStats section
- **THEN** they find all 7 counter properties (`requestsSent`, `responsesReceived`, `timedOut`, `timedOutInOutqueue`, `majorTimedOut`, `retransmitted`, `reconnects`) with descriptions of what each measures and that all are cumulative since context creation

### Requirement: API reference documents error handling patterns
The API reference SHALL include a section documenting common POSIXError codes thrown by NFSKit operations and their meanings.

#### Scenario: Developer troubleshoots an error
- **WHEN** a developer receives a POSIXError from an NFSKit operation
- **THEN** they can look up the error code in the API reference and find its meaning in the NFSKit context (e.g., `.ENOTCONN` means not connected, `.ECANCELED` means progress handler returned false)

### Requirement: API reference documents concurrency guarantees
The API reference SHALL include a section documenting which types are Sendable, thread-safety guarantees, and safe usage patterns.

#### Scenario: Developer checks Sendable conformance
- **WHEN** a developer reads the concurrency section
- **THEN** they understand that NFSClient, NFSFileHandle, NFSSecurity, and NFSStats are all Sendable, and all public closures are `@Sendable`

### Requirement: API reference documents URLResourceKey attributes
The API reference SHALL document which URLResourceKey values are populated by directory listing and attribute operations.

#### Scenario: Developer processes directory listing results
- **WHEN** a developer reads the attributes section
- **THEN** they find a table listing all URLResourceKey keys returned by `contentsOfDirectory(atPath:)` and `attributesOfItem(atPath:)` with their value types

### Requirement: API reference is structured for AI consumption
The API reference SHALL use a consistent, parseable heading hierarchy with Swift code blocks for all method signatures.

#### Scenario: AI assistant parses API reference
- **WHEN** an AI coding assistant reads `docs/API.md`
- **THEN** it can extract method signatures from Swift code blocks, find parameter descriptions in tables or lists, and navigate via the heading hierarchy (`## Type` → `### Method Group` → method entries)

### Requirement: API reference is linked from README
The API reference SHALL be reachable via a link in README.md.

#### Scenario: Navigation from README
- **WHEN** a developer clicks the API reference link in README
- **THEN** they navigate to `docs/API.md`

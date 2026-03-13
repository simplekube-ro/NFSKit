## ADDED Requirements

### Requirement: NFSClient is Sendable
`NFSClient` SHALL be a `final class` conforming to `Sendable`. It SHALL hold no mutable state — all mutable state lives in the event loop. It SHALL be safe to use from any actor, task, or thread.

#### Scenario: NFSClient used from multiple concurrent tasks
- **WHEN** multiple Swift Tasks call methods on the same NFSClient concurrently
- **THEN** all operations are submitted to the event loop without data races
- **THEN** no compiler warnings are produced under strict concurrency checking

#### Scenario: NFSClient passed across actor boundaries
- **WHEN** an NFSClient instance is sent from one actor to another
- **THEN** the send compiles without `@unchecked Sendable` on NFSClient itself

### Requirement: Async/await public API
All public NFS operations SHALL use `async throws` signatures. No `completionHandler`-based overloads SHALL be provided.

#### Scenario: File read uses async/await
- **WHEN** a caller reads a file
- **THEN** the call is `let data = try await client.contents(atPath: "/file.txt")`
- **THEN** no completion handler is involved

#### Scenario: Directory listing uses async/await
- **WHEN** a caller lists a directory
- **THEN** the call is `let entries = try await client.listDirectory("/path")`

#### Scenario: Connect and disconnect use async/await
- **WHEN** a caller connects to an NFS export
- **THEN** the call is `try await client.connect(export: "share")`
- **WHEN** a caller disconnects
- **THEN** the call is `try await client.disconnect()`

### Requirement: File handle as Sendable token
`NFSFileHandle` SHALL be a `final class` conforming to `Sendable` that holds an opaque handle identifier. The underlying `nfsfh*` pointer SHALL be stored only within the event loop's handle registry.

#### Scenario: File handle is Sendable
- **WHEN** an NFSFileHandle is passed to a detached Task
- **THEN** it compiles without warnings under strict concurrency checking

#### Scenario: File handle auto-closes on deallocation
- **WHEN** the last reference to an NFSFileHandle is released (deinit)
- **THEN** a close operation is submitted to the event loop
- **THEN** the handle registry entry is removed after `nfs_close_async` completes

#### Scenario: Operations on a closed handle throw
- **WHEN** a read or write is attempted on a handle whose registry entry has been removed
- **THEN** the operation throws an error indicating the handle is closed

### Requirement: All public types are Sendable
All types returned by public API methods SHALL conform to `Sendable`. This includes file attributes, directory entries, and stat results.

#### Scenario: File attributes are Sendable value types
- **WHEN** `stat()` returns file attributes
- **THEN** the return type is a Swift struct conforming to `Sendable`
- **THEN** it contains no reference types or mutable shared state

#### Scenario: Directory entries are Sendable value types
- **WHEN** `listDirectory()` returns entries
- **THEN** each entry is a Swift struct conforming to `Sendable`

### Requirement: Progress reporting via AsyncStream
File transfer progress SHALL be reported via `AsyncStream` rather than closure callbacks.

#### Scenario: Download with progress reporting
- **WHEN** a caller downloads a file with progress tracking
- **THEN** progress updates are delivered as an `AsyncStream<Progress>` or equivalent async sequence
- **THEN** the caller can iterate with `for await progress in stream`

#### Scenario: Cancellation through progress stream
- **WHEN** the caller stops consuming the progress stream (or cancels the enclosing Task)
- **THEN** the underlying file transfer batch is cancelled

### Requirement: Performance configuration before connect
The `configurePerformance` method SHALL remain callable before `connect()`. It SHALL operate directly on the `nfs_context*` via the event loop before DispatchSources are created.

#### Scenario: Configure performance before mount
- **WHEN** `configurePerformance(readMax:readAhead:)` is called before `connect(export:)`
- **THEN** the settings are applied to the `nfs_context*` via the event loop queue
- **THEN** the settings take effect during mount negotiation

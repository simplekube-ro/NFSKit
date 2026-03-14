## ADDED Requirements

### Requirement: Write buffer cleanup on callback error
The system SHALL free heap-allocated write buffers (`writeBuf`) when a libnfs callback fires with an error status. `CallbackData` SHALL support an optional cleanup closure that is invoked in both the success path (via `dataHandler`) and the error path (in `nfsCallback` when `status < 0`).

#### Scenario: Write callback returns error status
- **WHEN** `nfsCallback` fires with `status < 0` for a write operation
- **THEN** the cleanup closure on `CallbackData` MUST be invoked before resuming the continuation with a failure, freeing the `writeBuf`

#### Scenario: Write callback returns success status
- **WHEN** `nfsCallback` fires with `status >= 0` for a write operation
- **THEN** `dataHandler` is called as normal and the `defer { writeBuf.deallocate() }` in `dataHandler` frees the buffer (existing behavior preserved)

#### Scenario: Shutdown with in-flight writes
- **WHEN** `shutdownWithError` is called while write operations are in flight
- **THEN** `nfs_destroy_context` fires callbacks synchronously, each invoking the cleanup closure exactly once

### Requirement: Safe conditional type casting in continuation resume
The system SHALL use conditional casts (`as?`) instead of force-casts (`as!`) when delivering values through the type-erased `Result<Any, Error>` continuation channel. A type mismatch SHALL result in a `POSIXError(.EIO)` failure, not a crash.

#### Scenario: Correct type delivered through continuation
- **WHEN** a libnfs callback delivers a value and the `dataHandler` returns a `Result<Any, Error>` containing the expected type `T`
- **THEN** the continuation resumes with the correctly typed value

#### Scenario: Unexpected type delivered through continuation
- **WHEN** a type mismatch occurs during continuation resume (e.g., `Any` cannot be cast to expected `T`)
- **THEN** the continuation MUST resume with `POSIXError(.EIO, description: "Internal type mismatch in callback")` instead of crashing

### Requirement: Parallel pread buffer ownership documentation
The system SHALL document the ownership transfer invariant for `ReadBuffer` in `contentsUsingPreallocatedBuffer`. The `disown()` call and `Data(bytesNoCopy:)` construction MUST be adjacent with no intervening throwing code.

#### Scenario: Buffer ownership transfer after successful parallel read
- **WHEN** all parallel pread tasks complete successfully
- **THEN** `buffer.disown()` is called immediately followed by `Data(bytesNoCopy:count:deallocator:)` with no code between them that could throw

#### Scenario: Buffer cleanup after parallel read failure
- **WHEN** any parallel pread task fails with an error
- **THEN** the `ReadBuffer` retains ownership and its `deinit` deallocates the memory (structured concurrency guarantees all child tasks complete before the task group exits)

### Requirement: Nil-safe directory entry access
`NFSDirectory.subscript` SHALL guard against nil pointers returned by `nfs_readdir`. If the pointer is nil, the subscript SHALL trigger a `fatalError` with the out-of-bounds position rather than dereferencing a null pointer.

#### Scenario: Valid directory position access
- **WHEN** `subscript(position:)` is called with a valid index within the directory entry range
- **THEN** the entry is returned as `nfsdirent` via `pointee`

#### Scenario: Out-of-bounds directory position access
- **WHEN** `subscript(position:)` is called with an index beyond the directory entries (where `nfs_readdir` returns nil)
- **THEN** the system MUST `fatalError` with a message including the invalid position, not silently dereference nil

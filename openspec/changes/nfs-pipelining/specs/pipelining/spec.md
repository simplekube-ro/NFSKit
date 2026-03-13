## ADDED Requirements

### Requirement: Multiple RPCs in-flight simultaneously
The event loop SHALL support issuing multiple `nfs_*_async` calls before receiving replies, up to the pipeline depth limit provided by the adaptive depth controller.

#### Scenario: Pipeline fills up to depth limit
- **WHEN** 8 stat operations are submitted and the metadata pipeline depth is 4
- **THEN** 4 RPCs are issued immediately via `nfs_*_async`
- **THEN** the remaining 4 are held in the pending queue
- **WHEN** one in-flight RPC completes
- **THEN** the next pending operation is issued (maintaining up to 4 in-flight)

#### Scenario: Pipeline depth of 1 behaves like current serialized model
- **WHEN** the pipeline depth is 1
- **THEN** only one RPC is in-flight at a time
- **THEN** the next operation is issued only after the current one completes

### Requirement: Operation batching for chunked transfers
A multi-chunk file transfer (read or write) SHALL be represented as an `OperationBatch` that groups all chunk operations, tracks completion state, and manages ordered data reassembly.

#### Scenario: Large file read creates a batch of chunk operations
- **WHEN** `contents(atPath:)` is called for a 5MB file with 1MB chunk size
- **THEN** an OperationBatch is created with 5 chunk read operations
- **THEN** chunks are issued up to the bulk pipeline depth
- **THEN** completed chunk data is stored keyed by chunk index for ordered reassembly

#### Scenario: Batch assembles data in chunk order regardless of completion order
- **WHEN** chunks complete in order [2, 0, 3, 1]
- **THEN** the final assembled Data contains chunks in order [0, 1, 2, 3]

#### Scenario: Single operations use a trivial single-entry batch
- **WHEN** a standalone `stat()` is submitted
- **THEN** it uses a batch with exactly one operation
- **THEN** completion resumes the caller's continuation directly

### Requirement: Cooperative batch cancellation on error
When an operation within a batch fails, the batch SHALL transition to a cancelled state. Queued operations SHALL be dropped. In-flight operations SHALL be allowed to complete, but their results SHALL be discarded.

#### Scenario: Chunk read failure cancels remaining batch
- **WHEN** chunk 1 of a 5-chunk batch fails with an NFS error
- **THEN** the batch state transitions to `.cancelled`
- **THEN** chunks 3 and 4 (queued, not yet issued) are removed from the pending queue
- **THEN** the caller's continuation is resumed with the error immediately
- **WHEN** chunk 0 and 2 (in-flight) subsequently complete successfully
- **THEN** their data is discarded (batch is cancelled)
- **THEN** no continuation resume occurs (already resumed with error)

#### Scenario: Error in one batch does not affect other batches
- **WHEN** batch A (file read) has an error
- **THEN** batch B (directory stat) continues processing normally
- **THEN** only batch A's queued operations are cancelled

### Requirement: Swift Task cancellation integration
Batch operations SHALL integrate with Swift structured concurrency cancellation via `withTaskCancellationHandler`.

#### Scenario: Task cancelled while batch is in progress
- **WHEN** the Swift Task executing `contents(atPath:)` is cancelled
- **THEN** the batch transitions to `.cancelled`
- **THEN** queued operations are dropped
- **THEN** the caller's continuation is resumed with `CancellationError`
- **THEN** in-flight RPCs complete and their results are discarded

#### Scenario: Task cancelled before any operations are issued
- **WHEN** the Task is cancelled before the batch's operations enter the pipeline
- **THEN** no RPCs are issued
- **THEN** the continuation is resumed with `CancellationError`

### Requirement: Continuation registry for callback bridging
The event loop SHALL maintain a registry mapping callback identifiers to `CheckedContinuation` instances. C callbacks fired during `nfs_service()` SHALL look up and resume the appropriate continuation.

#### Scenario: Callback resumes the correct continuation
- **WHEN** `nfs_service()` fires a callback for operation with ID X
- **THEN** the event loop looks up continuation X in the registry
- **THEN** the continuation is resumed with the parsed result data
- **THEN** the registry entry for X is removed

#### Scenario: Callback data is copied before callback returns
- **WHEN** a callback fires with a data pointer
- **THEN** the data is copied into Swift-managed memory (e.g., `Data(bytes:count:)`) before the callback function returns

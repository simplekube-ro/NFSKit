## ADDED Requirements

### Requirement: Serial dispatch queue owns nfs_context
The event loop SHALL execute all `nfs_context*` operations on a single dedicated `DispatchSerialQueue`. No other thread or queue SHALL access the `nfs_context*` pointer.

#### Scenario: All C-level NFS calls run on the event loop queue
- **WHEN** any NFS operation is submitted (stat, read, write, mkdir, etc.)
- **THEN** the corresponding `nfs_*_async` call executes on the event loop's serial DispatchQueue

#### Scenario: No lock-based synchronization on nfs_context
- **WHEN** the event loop is running
- **THEN** no `NSLock`, `NSRecursiveLock`, or `NSCondition` is used to protect `nfs_context*` access

### Requirement: DispatchSource-driven I/O readiness
The event loop SHALL use `DispatchSource.makeReadSource` to monitor the NFS file descriptor for incoming data. A `DispatchSource.makeWriteSource` SHALL be dynamically activated when `nfs_which_events()` indicates POLLOUT is needed.

#### Scenario: Read source fires on incoming NFS data
- **WHEN** data arrives on the NFS file descriptor
- **THEN** the read source event handler calls `nfs_service(ctx, POLLIN)` on the serial queue

#### Scenario: Write source activates when outbound data is pending
- **WHEN** `nfs_which_events()` includes POLLOUT after an operation is submitted
- **THEN** the write source is activated (resumed)
- **WHEN** `nfs_which_events()` no longer includes POLLOUT
- **THEN** the write source is suspended

#### Scenario: Idle connection with no pending operations
- **WHEN** no operations are in-flight or queued
- **THEN** only the read source remains active (for server-initiated events), the write source is suspended

### Requirement: File descriptor change detection
The event loop SHALL detect when `nfs_get_fd()` returns a different file descriptor than the currently monitored one, and recreate DispatchSources for the new descriptor.

#### Scenario: File descriptor changes after reconnect
- **WHEN** `nfs_service()` completes and `nfs_get_fd()` returns a value different from the cached fd
- **THEN** the existing read and write DispatchSources are cancelled
- **THEN** new DispatchSources are created for the new file descriptor
- **THEN** pending operations continue processing on the new sources

#### Scenario: File descriptor changes after initial mount
- **WHEN** `nfs_mount_async` completes and the connection is established
- **THEN** DispatchSources are created for the file descriptor returned by `nfs_get_fd()`

### Requirement: Event loop lifecycle management
The event loop SHALL be startable and stoppable. Starting creates DispatchSources and begins processing. Stopping cancels all DispatchSources and resumes any pending continuations with an error.

#### Scenario: Event loop starts after mount
- **WHEN** the NFS mount operation succeeds
- **THEN** DispatchSources are created and resumed for the mounted connection's file descriptor

#### Scenario: Event loop stops on disconnect
- **WHEN** the client disconnects
- **THEN** all DispatchSources are cancelled
- **THEN** all pending continuations are resumed with a disconnection error
- **THEN** the operation queue is drained

#### Scenario: Event loop stops on deallocation
- **WHEN** the NFSClient is deallocated (deinit)
- **THEN** the event loop triggers a graceful shutdown equivalent to disconnect

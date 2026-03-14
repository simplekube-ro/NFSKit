## ADDED Requirements

### Requirement: Path component validation in recursive directory removal
The system SHALL validate each directory entry name in `removeDirectoryRecursive` before constructing a full path. Names containing `/`, or equal to `.` or `..`, SHALL be skipped with a continue.

#### Scenario: Normal directory entry names
- **WHEN** `removeDirectoryRecursive` iterates directory entries with valid names (e.g., `"file.txt"`, `"subdir"`)
- **THEN** each entry is processed normally via `removeItem(atPath:)`

#### Scenario: Directory entry name containing path separator
- **WHEN** a directory entry has a name containing `/` (e.g., `"../../../etc/passwd"`)
- **THEN** the entry MUST be skipped without constructing a traversal path

#### Scenario: Directory entry name is dot or dot-dot
- **WHEN** a directory entry has name `.` or `..`
- **THEN** the entry MUST be skipped

### Requirement: Server-reported readMax capping
The system SHALL cap the chunk size used in `contentsUsingPreallocatedBuffer` to a maximum of 4 MB (`4 * 1024 * 1024` bytes), regardless of the value returned by `nfs_get_readmax`.

#### Scenario: Server reports reasonable readMax
- **WHEN** the NFS server negotiates a readmax of 1 MB
- **THEN** the chunk size used for parallel reads is 1 MB

#### Scenario: Server reports excessively large readMax
- **WHEN** the NFS server negotiates a readmax of 1 GB or larger
- **THEN** the chunk size MUST be capped at 4 MB to prevent integer overflow in chunk calculations

### Requirement: Pending operations queue backpressure
The system SHALL enforce a maximum depth on the `pendingOperations` queue in `NFSEventLoop`. When the queue is full, new operations SHALL fail with `POSIXError(.ENOBUFS)`.

#### Scenario: Operations within queue limit
- **WHEN** operations are submitted and `pendingOperations.count` is below `maxPendingOperations`
- **THEN** operations are queued normally

#### Scenario: Queue at maximum capacity
- **WHEN** an operation is submitted and `pendingOperations.count` has reached `maxPendingOperations`
- **THEN** the operation MUST fail immediately with `POSIXError(.ENOBUFS)`

#### Scenario: Queue drains below limit
- **WHEN** in-flight operations complete and `pendingOperations` drops below the limit
- **THEN** new operations are accepted again

### Requirement: File open flags documentation
The `openFile(atPath:flags:)` method SHALL document which `O_*` flag combinations are supported and tested. Unsupported flag combinations are passed through to the NFS server without client-side validation.

#### Scenario: Standard read-only open
- **WHEN** `openFile` is called with `O_RDONLY` (the default)
- **THEN** the file is opened for reading

#### Scenario: Unusual flag combination
- **WHEN** `openFile` is called with an uncommon flag combination (e.g., `O_RDWR | O_DIRECTORY`)
- **THEN** the flags are passed to the NFS server which applies its own validation; client-side behavior is documented as undefined for unsupported combinations

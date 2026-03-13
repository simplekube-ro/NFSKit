## ADDED Requirements

### Requirement: Pre-allocated contiguous buffer for bulk reads
`NFSClient.contents(atPath:)` SHALL allocate a single contiguous buffer of `fileSize` bytes and issue pipelined `nfs_pread_async` calls where each chunk writes directly to `buffer + (chunkIndex * chunkSize)`.

#### Scenario: File read uses single pre-allocated buffer
- **WHEN** `contents(atPath:)` is called for a file of known size S
- **THEN** a single `ReadBuffer` of size S SHALL be allocated, and each pipelined pread SHALL target a distinct offset within that buffer

#### Scenario: Result wraps buffer without reassembly copy
- **WHEN** all chunk reads complete successfully
- **THEN** the result `Data` SHALL be created via `Data(bytesNoCopy:count:deallocator:)` from the pre-allocated buffer, with no `Data.append` or concatenation

#### Scenario: Large file cap triggers chunked fallback
- **WHEN** `contents(atPath:)` is called for a file larger than the pre-allocation cap (default 64MB)
- **THEN** the system SHALL fall back to per-chunk `ReadBuffer` allocation with reassembly

### Requirement: OperationBatch supports buffer-slice tracking
`OperationBatch` SHALL support an optional pre-allocated buffer mode where `recordChunkCompletion` records that a buffer slice was filled (by chunk index) rather than storing copied `Data`.

#### Scenario: Buffer-mode batch tracks filled slices
- **WHEN** an `OperationBatch` is created with a pre-allocated buffer and chunk size
- **THEN** `recordChunkCompletion(index:)` SHALL mark the slice as filled without storing any `Data`

#### Scenario: Buffer-mode assembleData returns the whole buffer
- **WHEN** `assembleData()` is called on a buffer-mode batch where all slices are filled
- **THEN** it SHALL return `Data(bytesNoCopy:)` wrapping the pre-allocated buffer

#### Scenario: Legacy mode still works with per-chunk Data
- **WHEN** an `OperationBatch` is created without a pre-allocated buffer (existing API)
- **THEN** it SHALL continue to accept `Data` per chunk and concatenate on `assembleData()`

### Requirement: Chunk size uses server-negotiated readmax
The default chunk size for bulk reads SHALL be `nfs_get_readmax()` (up to 4MB in libnfs 6.x) rather than the hardcoded 1MB.

#### Scenario: Chunk size matches negotiated readmax
- **WHEN** a bulk read is initiated after connection
- **THEN** the chunk size SHALL be the value returned by `nfs_get_readmax()`, capped at 4MB

### Requirement: Max transfer size increased to 4MB
The system SHALL support the libnfs 6.x maximum transfer size of 4MB (`NFS_MAX_XFER_SIZE = 4 * 1024 * 1024`), up from the previous 1MB limit.

#### Scenario: 4MB reads are issued when server supports it
- **WHEN** the server negotiates a readmax of 4MB or higher
- **THEN** the system SHALL issue read operations of up to 4MB per chunk

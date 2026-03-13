## ADDED Requirements

### Requirement: NFSStats struct exposes RPC transport statistics
The system SHALL provide an `NFSStats` struct that is `Sendable` and contains fields: `requestsSent`, `responsesReceived`, `timedOut`, `timedOutInOutqueue`, `majorTimedOut`, `retransmitted`, `reconnects` — all `UInt64`. The struct SHALL be a point-in-time snapshot.

#### Scenario: Stats struct contains all RPC counters
- **WHEN** an `NFSStats` value is obtained
- **THEN** it SHALL expose all 7 counters from `struct rpc_stats` as read-only `UInt64` properties

### Requirement: NFSClient.stats returns current RPC statistics
`NFSClient` SHALL provide an `async` method `stats() -> NFSStats` that queries `rpc_get_stats()` through the event loop's serial queue and returns a snapshot.

#### Scenario: Stats query on active connection
- **WHEN** `stats()` is called while connected to an NFS server
- **THEN** it SHALL return an `NFSStats` reflecting the current RPC transport counters

#### Scenario: Stats query when disconnected
- **WHEN** `stats()` is called before connection or after disconnect
- **THEN** it SHALL throw an error indicating no active connection

### Requirement: Logging callback routes libnfs messages to Swift
`NFSEventLoop` SHALL support setting a log callback via `setLogHandler(_ handler: @escaping @Sendable (Int, String) -> Void)` that receives the log level and message string from libnfs's `rpc_log_cb`.

#### Scenario: Log messages forwarded to Swift handler
- **WHEN** a log handler is set and libnfs emits a log message at level 2
- **THEN** the handler SHALL be called with `(2, "the message text")`

#### Scenario: Log handler respects debug level
- **WHEN** `nfs_set_debug(ctx, level)` is called with level N
- **THEN** only log messages at level <= N SHALL be forwarded to the handler

### Requirement: NFSClient exposes server address
`NFSClient` SHALL provide an async property `serverAddress` that returns `sockaddr_storage?` by calling `nfs_get_server_address()` through the event loop.

#### Scenario: Server address available after connect
- **WHEN** `serverAddress` is accessed after a successful `connect(export:)`
- **THEN** it SHALL return the `sockaddr_storage` of the NFS server

#### Scenario: Server address nil before connect
- **WHEN** `serverAddress` is accessed before `connect(export:)`
- **THEN** it SHALL return `nil`

### Requirement: configurePerformance updated for 6.x
`NFSClient.configurePerformance()` SHALL accept `readMax: Int?`, `writeMax: Int?`, `autoReconnect: Int32?`, `retransmissions: Int32?`, `timeout: Int32?` parameters. The `readAhead`, `pageCachePages`, and `pageCacheTTL` parameters SHALL be removed.

#### Scenario: New parameters are forwarded to libnfs
- **WHEN** `configurePerformance(writeMax: 2_097_152, retransmissions: 3, timeout: 5000)` is called
- **THEN** `nfs_set_writemax(ctx, 2097152)`, `nfs_set_retrans(ctx, 3)`, and `nfs_set_timeout(ctx, 5000)` SHALL be called

#### Scenario: readMax uses Int type
- **WHEN** `configurePerformance(readMax: 4_194_304)` is called
- **THEN** `nfs_set_readmax(ctx, size_t(4194304))` SHALL be called with the correct `size_t` type

#### Scenario: Removed parameters are not accepted
- **WHEN** code attempts to pass `readAhead`, `pageCachePages`, or `pageCacheTTL`
- **THEN** it SHALL fail to compile (parameters no longer exist)

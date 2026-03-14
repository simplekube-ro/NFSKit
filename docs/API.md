# NFSKit API Reference

NFSKit is a Swift async/await wrapper around [libnfs](https://github.com/sahlberg/libnfs), providing NFS client functionality for Apple platforms. All public types are `Sendable` and safe to use from any actor or task.

**Availability**: macOS 10.15+, iOS 13.0+, tvOS 13.0+, watchOS 6.0+, macCatalyst 13.0+

---

## NFSClient

```swift
public final class NFSClient: Sendable
```

The primary entry point for all NFS operations. Create an instance with an NFS URL, call `connect(export:)` to mount a share, then use the file and directory methods. All operations are dispatched through an internal `NFSEventLoop` that manages pipelined I/O on a serial `DispatchQueue`.

### Initializer

```swift
public init?(url: URL, timeout: TimeInterval = 60) throws
```

Creates an NFS client for the given server URL.

**Parameters**

| Parameter | Description |
|-----------|-------------|
| `url` | An NFS URL identifying the server, e.g. `nfs://hostname` or `nfs://hostname:2049`. The path component is not used here; pass the export path to `connect(export:)`. |
| `timeout` | Timeout in seconds for individual NFS operations. Default: `60`. |

**Returns** `nil` if `url` has no host component.

**Throws** If the internal `NFSEventLoop` cannot be initialized.

---

### Properties

```swift
public let url: URL
```

The NFS server URL used to create this client.

---

### Connection

#### connect(export:)

```swift
public func connect(export: String) async throws
```

Mounts the given NFS export. After a successful mount, the client automatically reads the root directory attributes and sets the effective UID/GID for subsequent operations.

**Parameters**

| Parameter | Description |
|-----------|-------------|
| `export` | The export path, e.g. `/share` or `/exports/data`. |

**Throws** `POSIXError` if the mount fails (DNS resolution failure, server unreachable, export not found, etc.).

**Note** Call `configurePerformance(...)` and `setSecurity(_:)` before this method. Both methods throw if called after the connection is established.

---

#### disconnect()

```swift
public func disconnect() async throws
```

Unmounts the current export and releases the server-side session.

**Throws** `POSIXError` if the unmount RPC fails.

---

#### listExports()

```swift
public func listExports() async throws -> [String]
```

Queries the server's mountd for available exports. Uses a separate RPC context so it does not disturb an existing NFS connection.

**Returns** An array of export path strings, e.g. `["/share", "/backup"]`.

**Throws** `POSIXError(.EBUSY)` if an export query is already in progress. `POSIXError` for RPC or network failures.

---

### File Handles

#### openFile(atPath:flags:)

```swift
public func openFile(atPath path: String, flags: Int32 = O_RDONLY) async throws -> NFSFileHandle
```

Opens a file on the NFS share and returns a token-based handle for subsequent I/O.

**Parameters**

| Parameter | Description |
|-----------|-------------|
| `path` | The file path relative to the mounted export root. |
| `flags` | POSIX open flags. Default: `O_RDONLY`. Common values: `O_WRONLY | O_CREAT | O_TRUNC` to create or overwrite, `O_RDWR` for read-write access. |

**Returns** An `NFSFileHandle` that can be used for read, write, seek, and metadata operations.

**Throws** `POSIXError` for permission errors, missing files (with `O_RDONLY`), and other POSIX failures.

**Note** The file handle is automatically closed when deallocated. For explicit control, the handle's underlying resources are released the moment the object is freed.

---

### File Content

#### contents(atPath:progress:)

```swift
public func contents(
    atPath path: String,
    progress: (@Sendable (Int64, Int64) -> Bool)? = nil
) async throws -> Data
```

Reads the entire contents of a file.

For files up to 64 MB (`contentsBufferThreshold`), the method allocates a single buffer, issues pipelined `pread` calls that write directly into it, and wraps the result in `Data(bytesNoCopy:)` for zero-copy delivery.

For files larger than 64 MB, a sequential chunked read is used to bound peak memory usage.

**Parameters**

| Parameter | Description |
|-----------|-------------|
| `path` | The file path relative to the mounted export root. |
| `progress` | Optional `@Sendable` closure called after each chunk. Receives `(bytesRead, totalSize)`. Return `false` to cancel. |

**Returns** The complete file data.

**Throws** `POSIXError(.ECANCELED)` if the progress handler returns `false`. `POSIXError` for file access or network failures. Respects `Task` cancellation.

---

#### write(data:toPath:progress:)

```swift
public func write(
    data: Data,
    toPath path: String,
    progress: (@Sendable (Int64) -> Bool)? = nil
) async throws
```

Writes data to a file, creating it if it does not exist or truncating it if it does. Data is sent in 1 MB chunks. After all chunks are written, the file is fsynced to the server.

**Parameters**

| Parameter | Description |
|-----------|-------------|
| `data` | The data to write. |
| `path` | The file path relative to the mounted export root. |
| `progress` | Optional `@Sendable` closure called after each chunk. Receives `(bytesWritten)` — the cumulative number of bytes written so far. Return `false` to cancel. |

**Throws** `POSIXError(.ECANCELED)` if the progress handler returns `false`. `POSIXError` for permission or network failures. Respects `Task` cancellation.

---

#### Static: contentsBufferThreshold

```swift
static let contentsBufferThreshold: Int  // 67_108_864 (64 MB)
```

The maximum file size in bytes for the zero-copy pre-allocated buffer read path. Files larger than this threshold use the sequential chunked read path.

---

#### Static: shouldUsePreallocatedBuffer(fileSize:)

```swift
static func shouldUsePreallocatedBuffer(fileSize: Int64) -> Bool
```

Returns `true` if a file of `fileSize` bytes qualifies for the pre-allocated zero-copy read path (i.e., `fileSize > 0 && fileSize <= contentsBufferThreshold`). Exposed as a static helper for unit testing.

---

### Directory Operations

#### contentsOfDirectory(atPath:)

```swift
public func contentsOfDirectory(atPath path: String) async throws -> [[URLResourceKey: Any]]
```

Lists the contents of a directory.

**Returns** An array of attribute dictionaries, one per entry. See the [URLResourceKey Attributes](#urlresourcekey-attributes) section for available keys.

**Throws** `POSIXError` if the path does not exist, is not a directory, or a network error occurs.

---

#### createDirectory(atPath:)

```swift
public func createDirectory(atPath path: String) async throws
```

Creates a directory at the given path. Does not create intermediate directories.

**Throws** `POSIXError(.EEXIST)` if the path already exists. `POSIXError` for permission or other failures.

---

#### removeDirectory(atPath:)

```swift
public func removeDirectory(atPath path: String) async throws
```

Removes an empty directory. Fails if the directory contains any entries.

**Throws** `POSIXError(.ENOTEMPTY)` if the directory is not empty. `POSIXError(.ENOTDIR)` if the path is not a directory.

---

### File Metadata and Manipulation

#### attributesOfItem(atPath:)

```swift
public func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: Any]
```

Returns attributes for a file, directory, or symbolic link at `path`.

**Returns** An attribute dictionary. See the [URLResourceKey Attributes](#urlresourcekey-attributes) section for available keys.

**Throws** `POSIXError(.ENOENT)` if the path does not exist.

---

#### removeFile(atPath:)

```swift
public func removeFile(atPath path: String) async throws
```

Removes a regular file. Cannot be used on directories; use `removeDirectory(atPath:)` or `removeItem(atPath:)` instead.

**Throws** `POSIXError(.EISDIR)` if the path is a directory.

---

#### moveItem(atPath:toPath:)

```swift
public func moveItem(atPath path: String, toPath: String) async throws
```

Moves or renames a file or directory. Both paths must be on the same NFS export.

**Throws** `POSIXError` if the source does not exist, the destination's parent directory does not exist, or a cross-device move is attempted.

---

#### truncateFile(atPath:atOffset:)

```swift
public func truncateFile(atPath path: String, atOffset: UInt64) async throws
```

Truncates (or zero-extends) a file to exactly `atOffset` bytes.

**Throws** `POSIXError` for permission or network failures.

---

#### removeItem(atPath:)

```swift
public func removeItem(atPath path: String) async throws
```

Removes a file or, recursively, a directory and all its contents. Safe to call on both files and directories.

**Throws** `POSIXError(.ENOENT)` if the path does not exist. `POSIXError` for permission or network failures.

---

#### readlink(atPath:)

```swift
public func readlink(atPath path: String) async throws -> String
```

Reads the target of a symbolic link.

**Returns** The link target as a string (may be relative or absolute).

**Throws** `POSIXError(.EINVAL)` if the path is not a symbolic link.

---

### Performance Tuning

#### configurePerformance(readMax:writeMax:autoReconnect:retransmissions:timeout:)

```swift
public func configurePerformance(
    readMax: Int? = nil,
    writeMax: Int? = nil,
    autoReconnect: Int32? = nil,
    retransmissions: Int32? = nil,
    timeout: Int32? = nil
) throws
```

Configures libnfs performance parameters. **Must be called before `connect(export:)`** — several settings are read during mount negotiation and cannot be changed afterward.

All parameters are optional; pass only the values you want to override.

**Parameters**

| Parameter | Description |
|-----------|-------------|
| `readMax` | Override the server-negotiated maximum read size in bytes. |
| `writeMax` | Override the server-negotiated maximum write size in bytes. |
| `autoReconnect` | Reconnect retry count. `-1` for infinite retries, `0` to disable automatic reconnection. |
| `retransmissions` | Number of RPC retransmissions to attempt before reporting a failure. |
| `timeout` | RPC timeout in milliseconds. |

**Throws** `POSIXError` if any parameter cannot be applied (e.g. the context has been destroyed).

---

#### setSecurity(_:)

```swift
public func setSecurity(_ security: NFSSecurity) throws
```

Sets the NFS authentication security mode. **Must be called before `connect(export:)`**.

**Throws** `POSIXError` if the security mode cannot be applied (e.g. called after the connection is already established).

**Parameters**

| Parameter | Description |
|-----------|-------------|
| `security` | The desired `NFSSecurity` mode. See [NFSSecurity](#nfssecurity). |

---

### Diagnostics

#### stats()

```swift
public func stats() async throws -> NFSStats
```

Returns a point-in-time snapshot of RPC transport counters. Counters are cumulative since the `nfs_context` was created. Call repeatedly and compute deltas to observe rate.

**Returns** An `NFSStats` value with the current counter values.

**Throws** `POSIXError(.ENOTCONN)` if the client has been disconnected.

---

#### serverAddress()

```swift
public func serverAddress() async throws -> sockaddr_storage?
```

Returns the server socket address the client connected to.

**Returns** A `sockaddr_storage` copy, or `nil` if `connect(export:)` has not yet been called successfully.

**Throws** `POSIXError(.ENOTCONN)` if the client has been disconnected.

---

## NFSFileHandle

```swift
public final class NFSFileHandle: Sendable
```

A Sendable token representing an open NFS file handle. Obtained via `NFSClient.openFile(atPath:flags:)`.

The actual `nfsfh*` C pointer lives in the event loop's handle registry, keyed by `handleID`. All operations are dispatched to the event loop. When the token object is deallocated, a fire-and-forget close is submitted to the event loop to release the server-side handle.

### Properties

```swift
public let handleID: UInt64
```

The unique identifier for this handle in the event loop's registry. Stable for the lifetime of the handle object.

---

### Read

#### read(count:)

```swift
public func read(count: UInt64) async throws -> Data
```

Reads up to `count` bytes from the current file position, advancing the position by the number of bytes read.

**Returns** The bytes read. May be shorter than `count` at end-of-file.

**Throws** `POSIXError(.EBADF)` if the handle is no longer valid.

---

#### pread(offset:count:)

```swift
public func pread(offset: UInt64, count: UInt64) async throws -> Data
```

Reads up to `count` bytes starting at `offset` within the file, without changing the current file position.

**Parameters**

| Parameter | Description |
|-----------|-------------|
| `offset` | Byte offset from the beginning of the file. |
| `count` | Maximum number of bytes to read. |

**Returns** The bytes read. May be shorter than `count` at end-of-file.

**Throws** `POSIXError(.EBADF)` if the handle is no longer valid.

---

### Write

#### write(data:)

```swift
@discardableResult
public func write(data: Data) async throws -> Int
```

Writes `data` at the current file position, advancing the position by the number of bytes written.

**Returns** The number of bytes written.

**Throws** `POSIXError(.EBADF)` if the handle is no longer valid, `POSIXError(.ENOSPC)` if the server is out of space.

---

#### pwrite(data:offset:)

```swift
@discardableResult
public func pwrite(data: Data, offset: UInt64) async throws -> Int
```

Writes `data` at `offset` within the file without changing the current file position.

**Parameters**

| Parameter | Description |
|-----------|-------------|
| `data` | The bytes to write. |
| `offset` | Byte offset from the beginning of the file at which to start writing. |

**Returns** The number of bytes written.

**Throws** `POSIXError(.EBADF)` if the handle is no longer valid.

---

### Metadata

#### fsync()

```swift
public func fsync() async throws
```

Flushes file data and metadata to stable server storage. Blocks until the server confirms the flush.

**Throws** `POSIXError(.EBADF)` if the handle is no longer valid.

---

#### fstat()

```swift
public func fstat() async throws -> nfs_stat_64
```

Returns file attributes via the open handle. Equivalent to `stat` but uses the open file descriptor, avoiding a separate name-to-inode lookup.

**Returns** A `nfs_stat_64` C struct with size, mode, uid, gid, timestamps, and more.

**Throws** `POSIXError(.EBADF)` if the handle is no longer valid.

---

#### ftruncate(toLength:)

```swift
public func ftruncate(toLength: UInt64) async throws
```

Truncates (or zero-extends) the open file to exactly `toLength` bytes.

**Throws** `POSIXError(.EBADF)` if the handle is no longer valid.

---

#### lseek(offset:whence:)

```swift
@discardableResult
public func lseek(offset: Int64, whence: Int32) async throws -> UInt64
```

Repositions the current file offset.

**Parameters**

| Parameter | Description |
|-----------|-------------|
| `offset` | The byte offset relative to `whence`. |
| `whence` | `SEEK_SET` — absolute position. `SEEK_CUR` — relative to current position. `SEEK_END` — relative to end of file. |

**Returns** The new absolute file offset in bytes.

**Throws** `POSIXError(.EBADF)` if the handle is no longer valid, `POSIXError(.EINVAL)` for an invalid `whence` value or out-of-range offset.

---

## NFSSecurity

```swift
public enum NFSSecurity: Sendable
```

NFS authentication security modes. Configure via `NFSClient.setSecurity(_:)` before calling `connect(export:)`.

| Case | libnfs constant | Description |
|------|-----------------|-------------|
| `.system` | `RPC_SEC_UNDEFINED` | AUTH_SYS (default). Sends numeric UID/GID with each RPC. |
| `.kerberos5` | `RPC_SEC_KRB5` | Kerberos 5 authentication only. |
| `.kerberos5i` | `RPC_SEC_KRB5I` | Kerberos 5 with per-message integrity checking. |
| `.kerberos5p` | `RPC_SEC_KRB5P` | Kerberos 5 with per-message encryption (privacy). |

**Note** Kerberos modes require a valid KRB5 host configuration and a libnfs build compiled with `HAVE_LIBKRB5`. Attempting to use them without KRB5 support will result in a server-side mount error.

---

## NFSStats

```swift
public struct NFSStats: Sendable
```

A point-in-time snapshot of RPC transport statistics. All counters are cumulative since the underlying `nfs_context` was created. Retransmitted requests are counted multiple times in `requestsSent`.

Retrieve via `NFSClient.stats()`. Call repeatedly and compute deltas to measure rates.

### Properties

| Property | Type | Description |
|----------|------|-------------|
| `requestsSent` | `UInt64` | Total RPC requests sent, including retransmits. |
| `responsesReceived` | `UInt64` | Total RPC responses received. |
| `timedOut` | `UInt64` | Requests that received no response within the `timeo` window. |
| `timedOutInOutqueue` | `UInt64` | Requests that timed out while still in the send queue (never reached the server). |
| `majorTimedOut` | `UInt64` | Requests with no response after all `retrans` retry attempts. |
| `retransmitted` | `UInt64` | Requests retransmitted due to timeout or reconnect. |
| `reconnects` | `UInt64` | Reconnects triggered by a major timeout or dropped connection. |

### Initializer

```swift
public init(
    requestsSent: UInt64 = 0,
    responsesReceived: UInt64 = 0,
    timedOut: UInt64 = 0,
    timedOutInOutqueue: UInt64 = 0,
    majorTimedOut: UInt64 = 0,
    retransmitted: UInt64 = 0,
    reconnects: UInt64 = 0
)
```

Creates an `NFSStats` with explicit counter values. All parameters default to `0`. Primarily useful in tests.

---

## Error Handling

All `async throws` methods throw `Error`, typically a `POSIXError`. The table below lists the most common codes and their meanings in NFSKit.

| Error code | Meaning in NFSKit context |
|------------|--------------------------|
| `ENOTCONN` | Client not connected, or event loop has been shut down. |
| `EBADF` | File handle ID not found in the event loop's registry (handle was closed or never opened). |
| `EISCONN` | Cannot change security mode while a connection is active. |
| `ETIMEDOUT` | An NFS operation did not complete within the configured timeout. |
| `ECANCELED` | A progress handler returned `false`, or the enclosing `Task` was cancelled. |
| `EBUSY` | An export query (`listExports()`) is already in progress. |
| `ENOENT` | Path does not exist on the server. |
| `ENOTEMPTY` | `removeDirectory(atPath:)` called on a non-empty directory. |
| `ENOSPC` | Server has no space left on the device. |
| `ENODATA` | Internal: an optional value that must be non-nil was nil. Should not be seen in normal use. |

All errors from libnfs POSIX-style operations (negative return codes) are translated to `POSIXError` with the corresponding `POSIXErrorCode`.

---

## Concurrency

| Type | Sendable | Notes |
|------|----------|-------|
| `NFSClient` | Yes | Immutable properties; all mutable state in internal `NFSEventLoop`. |
| `NFSFileHandle` | Yes | Immutable token; underlying `nfsfh*` confined to event loop queue. |
| `NFSSecurity` | Yes | Pure enum value type. |
| `NFSStats` | Yes | Immutable struct; safe to pass across isolation boundaries. |

All progress and completion closures passed to NFSKit APIs are `@Sendable`.

NFSKit uses a serial `DispatchQueue` (not Swift actors) to protect NFS context state. This means:

- The public API is safe to call from any actor, task, or thread.
- There is no priority inversion between Swift concurrency and the NFS I/O queue.
- Long-running operations (large file transfers) do not block the calling task — they suspend at each `await` point.
- Task cancellation via `Task.cancel()` is respected at chunk boundaries in `contents(atPath:)` and `write(data:toPath:)`.

---

## URLResourceKey Attributes

The dictionaries returned by `contentsOfDirectory(atPath:)` and `attributesOfItem(atPath:)` contain the following keys.

| Key | Value type | Description |
|-----|-----------|-------------|
| `.nameKey` | `String` | The file or directory name (last path component). |
| `.pathKey` | `String` | The full path as passed to the operation. |
| `.fileSizeKey` | `Int64` | Size in bytes (`nfs_size`). |
| `.linkCountKey` | `NSNumber` | Hard link count (`nfs_nlink`). |
| `.fileResourceTypeKey` | `URLFileResourceType` | `.regular`, `.directory`, `.symbolicLink`, or `.unknown`. |
| `.isRegularFileKey` | `Bool` | `true` if the entry is a regular file (`S_IFREG`). |
| `.isDirectoryKey` | `Bool` | `true` if the entry is a directory (`S_IFDIR`). |
| `.isSymbolicLinkKey` | `Bool` | `true` if the entry is a symbolic link (`S_IFLNK`). |
| `.contentModificationDateKey` | `Date` | Last data modification time (`nfs_mtime` / `nfs_mtime_nsec`). |
| `.contentAccessDateKey` | `Date` | Last access time (`nfs_atime` / `nfs_atime_nsec`). |
| `.creationDateKey` | `Date` | Inode status change time (`nfs_ctime` / `nfs_ctime_nsec`). Note: NFS does not expose a true creation time; this maps to ctime. |

**Note** `.fileResourceTypeKey`, `.isRegularFileKey`, `.isDirectoryKey`, and `.isSymbolicLinkKey` are mutually consistent — exactly one resource type flag is `true` per entry. Device files, named pipes, and sockets are reported as `.unknown`.

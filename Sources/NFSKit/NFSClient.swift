//
//  NFSClient.swift
//  NFSKit
//
//  Public API for NFS client operations. Delegates all work to the
//  NFSEventLoop which owns the nfs_context* and manages pipelined I/O.
//
//  Thread Safety: NFSClient is Sendable. All stored properties are
//  immutable (`let`). Mutable NFS state lives on the event loop's
//  serial queue.
//

import Foundation
import nfs

/// A Sendable NFS client that provides async/await access to NFS operations.
///
/// Create a client with an NFS URL, call ``connect(export:)`` to mount,
/// then use the file and directory operations. All operations are dispatched
/// through an internal ``NFSEventLoop`` that manages pipelined I/O.
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
public final class NFSClient: Sendable {

    /// The NFS server URL used to create this client.
    public let url: URL

    /// The event loop that owns the NFS context and manages all I/O.
    internal let eventLoop: NFSEventLoop

    /// Create an NFS client for the given URL.
    ///
    /// - Parameters:
    ///   - url: An NFS URL (e.g. `nfs://hostname`).
    ///   - timeout: Timeout for individual operations in seconds. Default 60.
    /// - Returns: `nil` if the URL has no host component.
    public init?(url: URL, timeout: TimeInterval = 60) throws {
        guard url.host != nil else { return nil }
        self.url = url
        self.eventLoop = try NFSEventLoop(timeout: timeout)
    }
}

// MARK: - Connection

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
extension NFSClient {

    /// Mount the given NFS export.
    ///
    /// After a successful connect, the client automatically sets the UID/GID
    /// from the root directory attributes for subsequent operations.
    ///
    /// - Important: By default, NFS connections use `AUTH_SYS` which provides no
    ///   encryption or strong authentication. Call ``setSecurity(_:)`` with
    ///   ``NFSSecurity/kerberos5p`` **before** connecting if the network is untrusted.
    ///
    /// - Parameter export: The export path (e.g. `/share`).
    public func connect(export: String) async throws {
        let host = url.host ?? "localhost"
        let server = url.port.map { "\(host):\($0)" } ?? host
        try await eventLoop.mount(server: server, export: export)

        let stat = try await eventLoop.stat("/")
        try eventLoop.setUID(Int32(stat.nfs_uid))
        try eventLoop.setGID(Int32(stat.nfs_gid))
    }

    /// Unmount the current export.
    public func disconnect() async throws {
        try await eventLoop.unmount()
    }

    /// List available exports on the server.
    public func listExports() async throws -> [String] {
        let server = url.host ?? "localhost"
        return try await eventLoop.getexports(server: server)
    }
}

// MARK: - File Handles

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
extension NFSClient {

    /// Open a file and return a token-based handle.
    ///
    /// Supported flag combinations:
    /// - `O_RDONLY` — read-only access (default)
    /// - `O_WRONLY | O_CREAT | O_TRUNC` — create/overwrite for writing
    /// - `O_RDWR` — read-write access
    /// - `O_WRONLY | O_CREAT | O_APPEND` — append to file
    ///
    /// Other flag combinations are passed through to the NFS server, which
    /// applies its own validation. Behavior for unsupported combinations is
    /// server-dependent.
    ///
    /// - Parameters:
    ///   - path: The file path on the NFS share.
    ///   - flags: POSIX open flags.
    /// - Returns: An ``NFSFileHandle`` token for subsequent I/O.
    public func openFile(atPath path: String, flags: Int32 = O_RDONLY) async throws -> NFSFileHandle {
        let handleID = try await eventLoop.openFile(path, flags: flags)
        return NFSFileHandle(handleID: handleID, eventLoop: eventLoop)
    }
}

// MARK: - File Content Operations

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
extension NFSClient {

    /// Maximum file size (bytes) for the pre-allocated single-buffer read path.
    ///
    /// Files up to this size are read into a single allocation in one pass of
    /// pipelined pread calls, then wrapped with `Data(bytesNoCopy:)` for zero-copy
    /// delivery.  Files larger than this threshold fall back to the sequential
    /// chunked read path, which bounds peak memory usage.
    ///
    /// 64 MB is a conservative default that keeps peak RSS manageable on iOS while
    /// still benefiting most media and document transfers.
    static let contentsBufferThreshold: Int = 67_108_864 // 64 MB

    /// Returns whether the pre-allocated single-buffer path should be used for
    /// a file of the given size.
    ///
    /// Exposed as a static helper so unit tests can verify the threshold logic
    /// without a live NFS connection.
    static func shouldUsePreallocatedBuffer(fileSize: Int64) -> Bool {
        fileSize > 0 && fileSize <= Int64(contentsBufferThreshold)
    }

    /// Read the entire contents of a file.
    ///
    /// For files up to 64 MB, this method allocates a single buffer upfront and
    /// issues pipelined `pread` calls that write directly into it, then wraps the
    /// buffer in a `Data(bytesNoCopy:)` value for zero-copy delivery.
    ///
    /// For files larger than 64 MB the legacy sequential chunked read is used to
    /// bound peak memory usage.
    ///
    /// - Parameters:
    ///   - path: The file path on the NFS share.
    ///   - progress: Optional progress callback `(bytesRead, totalSize) -> shouldContinue`.
    ///               Return `false` to cancel the read.
    /// - Returns: The file data.
    public func contents(
        atPath path: String,
        progress: (@Sendable (Int64, Int64) -> Bool)? = nil
    ) async throws -> Data {
        try Task.checkCancellation()

        let handle = try await openFile(atPath: path, flags: O_RDONLY)
        let stat = try await handle.fstat()
        let fileSize = Int64(stat.nfs_size)

        // Empty file — no I/O needed.
        guard fileSize > 0 else { return Data() }

        if NFSClient.shouldUsePreallocatedBuffer(fileSize: fileSize) {
            return try await contentsUsingPreallocatedBuffer(
                handle: handle,
                fileSize: fileSize,
                progress: progress
            )
        } else {
            return try await contentsUsingLegacyChunkedRead(
                handle: handle,
                fileSize: fileSize,
                progress: progress
            )
        }
    }

    /// Reads a file whose size fits within the pre-allocated buffer threshold.
    ///
    /// Allocates a single `ReadBuffer`, then issues `pread` calls in pipeline order
    /// — each writing directly into the buffer at `chunkIndex * chunkSize`.  When
    /// all reads complete, wraps the buffer in `Data(bytesNoCopy:)`.
    private func contentsUsingPreallocatedBuffer(
        handle: NFSFileHandle,
        fileSize: Int64,
        progress: (@Sendable (Int64, Int64) -> Bool)?
    ) async throws -> Data {
        let chunkSize = min(try eventLoop.getReadMax(), 4 * 1024 * 1024)
        let totalBytes = Int(fileSize)
        let totalChunks = (totalBytes + chunkSize - 1) / chunkSize

        let buffer = ReadBuffer(byteCount: totalBytes)

        // Issue all pread calls in parallel (pipelined).  Each chunk writes into
        // a distinct, non-overlapping region of `buffer`.
        try await withThrowingTaskGroup(of: (Int, Int).self) { group in
            for chunkIndex in 0..<totalChunks {
                try Task.checkCancellation()
                let byteOffset = chunkIndex * chunkSize
                let remaining = totalBytes - byteOffset
                let readCount = min(chunkSize, remaining)
                let slicePtr = buffer.pointer.advanced(by: byteOffset)

                group.addTask {
                    let bytesRead = try await handle.preadIntoBuffer(
                        buffer: slicePtr,
                        offset: UInt64(byteOffset),
                        count: UInt64(readCount)
                    )
                    return (chunkIndex, bytesRead)
                }
            }

            // Drain results; they may arrive out of order but each writes to its
            // own non-overlapping slice so ordering doesn't matter here.
            var totalBytesRead = 0
            var cancelledByProgress = false
            for try await (_, bytesRead) in group {
                totalBytesRead += bytesRead
                if !cancelledByProgress,
                   let progress = progress,
                   !progress(Int64(totalBytesRead), fileSize) {
                    cancelledByProgress = true
                    group.cancelAll()
                    // Drain remaining in-flight tasks before throwing.
                    // preadIntoBuffer continuations hold raw pointers into
                    // `buffer`; we must not deallocate `buffer` while libnfs
                    // still holds those pointers.  withThrowingTaskGroup awaits
                    // all child tasks before propagating a throw from the body,
                    // but since we are throwing after the for-await loop exits
                    // we make the drain explicit to be safe.
                    do {
                        for try await _ in group { }
                    } catch { }
                }
            }
            if cancelledByProgress {
                throw POSIXError(.ECANCELED, description: "Cancelled by progress handler")
            }
        }

        // SAFETY INVARIANT: disown() and Data(bytesNoCopy:) must be adjacent with
        // no intervening code that can throw. disown() prevents ReadBuffer.deinit
        // from freeing the pointer; Data's deallocator takes over that responsibility.
        // If code between them throws, the pointer leaks (disown already called) or
        // double-frees (if disown is skipped). Structured concurrency guarantees all
        // child tasks have completed before reaching this point.
        buffer.disown()
        return Data(
            bytesNoCopy: buffer.pointer,
            count: totalBytes,
            deallocator: .custom { ptr, _ in ptr.deallocate() }
        )
    }

    /// Sequential chunked read — used for files larger than the pre-allocated buffer threshold.
    private func contentsUsingLegacyChunkedRead(
        handle: NFSFileHandle,
        fileSize: Int64,
        progress: (@Sendable (Int64, Int64) -> Bool)?
    ) async throws -> Data {
        var data = Data()
        data.reserveCapacity(Int(fileSize))
        var offset: Int64 = 0
        let chunkSize: Int64 = 1_048_576 // 1 MB

        while offset < fileSize {
            try Task.checkCancellation()

            let remaining = fileSize - offset
            let count = min(chunkSize, remaining)
            let chunk = try await handle.read(count: UInt64(count))
            if chunk.isEmpty { break }
            data.append(chunk)
            offset += Int64(chunk.count)

            if let progress = progress, !progress(offset, fileSize) {
                throw POSIXError(.ECANCELED, description: "Cancelled by progress handler")
            }
        }
        return data
    }

    /// Write data to a file, creating or truncating it.
    ///
    /// - Parameters:
    ///   - data: The data to write.
    ///   - path: The file path on the NFS share.
    ///   - progress: Optional progress callback `(bytesWritten) -> shouldContinue`.
    ///               Return `false` to cancel the write.
    public func write(
        data: Data,
        toPath path: String,
        progress: (@Sendable (Int64) -> Bool)? = nil
    ) async throws {
        try Task.checkCancellation()

        let handle = try await openFile(atPath: path, flags: O_WRONLY | O_CREAT | O_TRUNC)
        let chunkSize = 1_048_576
        var offset = 0

        while offset < data.count {
            try Task.checkCancellation()

            let end = min(offset + chunkSize, data.count)
            let chunk = data[offset..<end]
            _ = try await handle.write(data: Data(chunk))
            offset = end

            if let progress = progress, !progress(Int64(offset)) {
                throw POSIXError(.ECANCELED, description: "Cancelled by progress handler")
            }
        }
        try await handle.fsync()
    }
}

// MARK: - Directory Operations

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
extension NFSClient {

    /// List the contents of a directory.
    ///
    /// - Parameter path: The directory path on the NFS share.
    /// - Returns: An array of dictionaries with `URLResourceKey` attributes.
    public func contentsOfDirectory(atPath path: String) async throws -> [[URLResourceKey: Any]] {
        let dirPtr = try await eventLoop.opendir(path)
        return try await eventLoop.readdirAll(dirPtr: dirPtr, path: path)
    }

    /// Create a directory.
    public func createDirectory(atPath path: String) async throws {
        try await eventLoop.mkdir(path)
    }

    /// Remove an empty directory.
    public func removeDirectory(atPath path: String) async throws {
        try await eventLoop.rmdir(path)
    }
}

// MARK: - File Metadata & Manipulation

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
extension NFSClient {

    /// Get attributes of a file or directory.
    public func attributesOfItem(atPath path: String) async throws -> [URLResourceKey: Any] {
        let stat = try await eventLoop.stat(path)
        return buildAttributes(from: stat, path: path)
    }

    /// Remove a file (not a directory).
    public func removeFile(atPath path: String) async throws {
        try await eventLoop.unlink(path)
    }

    /// Move/rename a file or directory.
    public func moveItem(atPath path: String, toPath: String) async throws {
        try await eventLoop.rename(path, to: toPath)
    }

    /// Truncate a file to the given length.
    public func truncateFile(atPath path: String, atOffset: UInt64) async throws {
        try await eventLoop.truncate(path, toLength: atOffset)
    }

    /// Remove a file or directory recursively.
    public func removeItem(atPath path: String) async throws {
        let stat = try await eventLoop.stat(path)
        if stat.nfs_mode & UInt64(S_IFMT) == UInt64(S_IFDIR) {
            try await removeDirectoryRecursive(path: path)
        } else {
            try await eventLoop.unlink(path)
        }
    }

    private func removeDirectoryRecursive(path: String) async throws {
        let items = try await contentsOfDirectory(atPath: path)
        for item in items {
            guard let name = item[.nameKey] as? String else { continue }
            // Reject names that could construct a path traversal.
            guard !name.contains("/"), name != ".", name != ".." else { continue }
            let fullPath = path.hasSuffix("/") ? path + name : path + "/" + name
            try await removeItem(atPath: fullPath)
        }
        try await eventLoop.rmdir(path)
    }

    /// Read the target of a symbolic link.
    public func readlink(atPath path: String) async throws -> String {
        try await eventLoop.readlink(path)
    }

    // MARK: - Attribute Building

    private func buildAttributes(from stat: nfs_stat_64, path: String) -> [URLResourceKey: Any] {
        var dic: [URLResourceKey: Any] = [:]

        let name = (path as NSString).lastPathComponent
        dic[.nameKey] = name
        dic[.pathKey] = path
        dic[.fileSizeKey] = Int64(stat.nfs_size)
        dic[.linkCountKey] = NSNumber(value: stat.nfs_nlink)

        let mode = stat.nfs_mode & UInt64(S_IFMT)
        if mode == UInt64(S_IFREG) {
            dic[.fileResourceTypeKey] = URLFileResourceType.regular
            dic[.isRegularFileKey] = true
            dic[.isDirectoryKey] = false
            dic[.isSymbolicLinkKey] = false
        } else if mode == UInt64(S_IFDIR) {
            dic[.fileResourceTypeKey] = URLFileResourceType.directory
            dic[.isDirectoryKey] = true
            dic[.isRegularFileKey] = false
            dic[.isSymbolicLinkKey] = false
        } else if mode == UInt64(S_IFLNK) {
            dic[.fileResourceTypeKey] = URLFileResourceType.symbolicLink
            dic[.isSymbolicLinkKey] = true
            dic[.isRegularFileKey] = false
            dic[.isDirectoryKey] = false
        } else {
            dic[.fileResourceTypeKey] = URLFileResourceType.unknown
            dic[.isRegularFileKey] = false
            dic[.isDirectoryKey] = false
            dic[.isSymbolicLinkKey] = false
        }

        dic[.contentModificationDateKey] = Date(
            timespec(tv_sec: Int(stat.nfs_mtime), tv_nsec: Int(stat.nfs_mtime_nsec))
        )
        dic[.contentAccessDateKey] = Date(
            timespec(tv_sec: Int(stat.nfs_atime), tv_nsec: Int(stat.nfs_atime_nsec))
        )
        dic[.creationDateKey] = Date(
            timespec(tv_sec: Int(stat.nfs_ctime), tv_nsec: Int(stat.nfs_ctime_nsec))
        )

        return dic
    }
}

// MARK: - Performance Tuning

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
extension NFSClient {

    /// Configure libnfs performance parameters.
    ///
    /// Must be called **before** ``connect(export:)`` -- some settings are
    /// read during mount negotiation.
    ///
    /// - Parameters:
    ///   - readMax: Override server-negotiated maximum read size in bytes.
    ///   - writeMax: Override server-negotiated maximum write size in bytes.
    ///   - autoReconnect: Number of reconnect retries (-1 for infinite, 0 to disable).
    ///   - retransmissions: Number of RPC retransmissions before a failure is declared.
    ///   - timeout: RPC timeout in milliseconds.
    public func configurePerformance(
        readMax: Int? = nil,
        writeMax: Int? = nil,
        autoReconnect: Int32? = nil,
        retransmissions: Int32? = nil,
        timeout: Int32? = nil
    ) throws {
        if let readMax = readMax { try eventLoop.setReadMax(readMax) }
        if let writeMax = writeMax { try eventLoop.setWriteMax(writeMax) }
        if let retries = autoReconnect { try eventLoop.setAutoReconnect(retries) }
        if let count = retransmissions { try eventLoop.setRetransmissions(count) }
        if let milliseconds = timeout { try eventLoop.setTimeout(milliseconds) }
    }

    /// Set the NFS authentication security mode.
    ///
    /// Must be called **before** ``connect(export:)`` — libnfs reads the
    /// security setting during mount negotiation.
    ///
    /// - Parameter security: The desired ``NFSSecurity`` mode.
    /// - Throws: If the security mode cannot be applied (e.g. called after
    ///   the connection is already established).
    public func setSecurity(_ security: NFSSecurity) throws {
        try eventLoop.setSecurity(security)
    }

}

// MARK: - Diagnostics

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
extension NFSClient {

    /// Returns a point-in-time snapshot of RPC transport statistics.
    ///
    /// The counters are cumulative since the underlying `nfs_context` was
    /// created. Call repeatedly to compute deltas between samples.
    ///
    /// - Throws: `POSIXError(.ENOTCONN)` if the client has been disconnected.
    /// - Returns: An ``NFSStats`` with the current counter values.
    public func stats() async throws -> NFSStats {
        // stats() dispatches synchronously on the serial queue internally,
        // so calling it directly from an async context is safe.
        try eventLoop.stats()
    }

    /// Returns the NFS server address the client is (or was) connected to.
    ///
    /// Before a successful ``connect(export:)``, libnfs has no server address
    /// recorded and this method returns `nil`.
    ///
    /// - Throws: `POSIXError(.ENOTCONN)` if the client has been disconnected.
    /// - Returns: A `sockaddr_storage` copy, or `nil` if not yet connected.
    public func serverAddress() async throws -> sockaddr_storage? {
        try eventLoop.serverAddress()
    }
}

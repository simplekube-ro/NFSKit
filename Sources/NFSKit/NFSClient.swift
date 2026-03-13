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
    /// - Parameters:
    ///   - path: The file path on the NFS share.
    ///   - flags: POSIX open flags (`O_RDONLY`, `O_WRONLY | O_CREAT | O_TRUNC`, etc.).
    /// - Returns: An ``NFSFileHandle`` token for subsequent I/O.
    public func openFile(atPath path: String, flags: Int32 = O_RDONLY) async throws -> NFSFileHandle {
        let handleID = try await eventLoop.openFile(path, flags: flags)
        return NFSFileHandle(handleID: handleID, eventLoop: eventLoop)
    }
}

// MARK: - File Content Operations

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
extension NFSClient {

    /// Read the entire contents of a file.
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
    ///   - readAhead: Number of bytes to read ahead.
    ///   - pageCachePages: Number of page-cache pages.
    ///   - pageCacheTTL: Page-cache TTL in seconds (default 30).
    ///   - autoReconnect: Number of reconnect retries (-1 for infinite, 0 to disable).
    public func configurePerformance(
        readMax: UInt64? = nil,
        readAhead: UInt32? = nil,
        pageCachePages: UInt32? = nil,
        pageCacheTTL: UInt32? = nil,
        autoReconnect: Int32? = nil
    ) {
        if let readMax = readMax { try? eventLoop.setReadMax(readMax) }
        if let readAhead = readAhead { try? eventLoop.setReadAhead(readAhead) }
        if let pages = pageCachePages {
            try? eventLoop.setPageCache(pages: pages, ttl: pageCacheTTL ?? 30)
        }
        if let retries = autoReconnect { try? eventLoop.setAutoReconnect(retries) }
    }
}

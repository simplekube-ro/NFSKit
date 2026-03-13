//
//  NFSFileHandle.swift
//  NFSKit
//
//  Token-based file handle. The actual nfsfh* lives in the event loop's
//  handle registry; this type merely holds the handle ID and a reference
//  to the event loop so it can delegate I/O operations.
//
//  Thread Safety: This type is Sendable. The handleID and eventLoop are
//  both immutable. All mutable state lives on the event loop's serial queue.
//

import Foundation
import nfs

/// A Sendable file handle token.
///
/// The underlying NFS file handle pointer (`nfsfh*`) is stored in the
/// event loop's handle registry, keyed by ``handleID``. All operations
/// are dispatched to the event loop for execution.
///
/// When the token is deallocated, a fire-and-forget close is submitted
/// to the event loop so the server-side handle is released.
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
public final class NFSFileHandle: Sendable {

    /// The unique identifier for this handle in the event loop's registry.
    public let handleID: UInt64

    /// The event loop that owns the underlying nfsfh*.
    internal let eventLoop: NFSEventLoop

    init(handleID: UInt64, eventLoop: NFSEventLoop) {
        self.handleID = handleID
        self.eventLoop = eventLoop
    }

    deinit {
        let id = handleID
        let loop = eventLoop
        loop.closeFileFireAndForget(handleID: id)
    }

    // MARK: - Read

    /// Read up to `count` bytes from the current file position.
    public func read(count: UInt64) async throws -> Data {
        try await eventLoop.readFile(handleID: handleID, count: count)
    }

    /// Positional read: read up to `count` bytes starting at `offset`
    /// without changing the current file position.
    public func pread(offset: UInt64, count: UInt64) async throws -> Data {
        try await eventLoop.preadFile(handleID: handleID, offset: offset, count: count)
    }

    /// Positional read into a caller-owned buffer.
    ///
    /// Writes directly into `buffer` at the address provided, avoiding an extra
    /// allocation. Used internally by the pre-allocated buffer path in
    /// ``NFSClient.contents(atPath:)``.
    ///
    /// The caller must ensure `buffer` remains valid until the returned task completes.
    ///
    /// - Parameters:
    ///   - buffer: Pointer to the destination memory region (at least `count` bytes).
    ///   - offset: Byte offset within the file to start reading from.
    ///   - count: Number of bytes to request.
    /// - Returns: The number of bytes actually written into `buffer` (`<= count`).
    func preadIntoBuffer(
        buffer: UnsafeMutableRawPointer,
        offset: UInt64,
        count: UInt64
    ) async throws -> Int {
        try await eventLoop.preadIntoBuffer(
            handleID: handleID,
            buffer: buffer,
            offset: offset,
            count: count
        )
    }

    // MARK: - Write

    /// Write `data` at the current file position.
    /// Returns the number of bytes written.
    @discardableResult
    public func write(data: Data) async throws -> Int {
        try await eventLoop.writeFile(handleID: handleID, data: data)
    }

    /// Positional write: write `data` at `offset` without changing the
    /// current file position. Returns the number of bytes written.
    @discardableResult
    public func pwrite(data: Data, offset: UInt64) async throws -> Int {
        try await eventLoop.pwriteFile(handleID: handleID, offset: offset, data: data)
    }

    // MARK: - Metadata

    /// Flush file data to the server.
    public func fsync() async throws {
        try await eventLoop.fsync(handleID: handleID)
    }

    /// Get file attributes via the open handle.
    public func fstat() async throws -> nfs_stat_64 {
        try await eventLoop.fstat(handleID: handleID)
    }

    /// Truncate the file to `toLength` bytes.
    public func ftruncate(toLength: UInt64) async throws {
        try await eventLoop.ftruncate(handleID: handleID, toLength: toLength)
    }

    /// Seek within the file.
    /// - Parameters:
    ///   - offset: The byte offset relative to `whence`.
    ///   - whence: One of `SEEK_SET`, `SEEK_CUR`, or `SEEK_END`.
    /// - Returns: The new absolute file position.
    @discardableResult
    public func lseek(offset: Int64, whence: Int32) async throws -> UInt64 {
        try await eventLoop.lseek(handleID: handleID, offset: offset, whence: whence)
    }
}

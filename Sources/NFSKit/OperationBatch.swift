//
//  OperationBatch.swift
//  NFSKit
//
//  Manages a group of related NFS operations (e.g., chunks of a file
//  transfer) with ordered data reassembly and cooperative cancellation.
//
//  OperationBatch lives inside the event loop and is confined to its
//  serial DispatchQueue. It is NOT Sendable.
//

import Foundation

/// Unique identifier for a batch of related operations.
///
/// Batch IDs are assigned by the event loop. For testing, values can be
/// created directly via the `init(value:)` initializer.
struct BatchID: Hashable, Sendable {
    let value: UInt64
}

/// Groups related NFS operations (e.g., chunked file reads) and manages
/// their lifecycle: pending queue, in-flight tracking, ordered data
/// reassembly, and cooperative cancellation.
///
/// - Important: This type is **not** thread-safe. It must only be accessed
///   from the event loop's serial queue.
final class OperationBatch {

    /// The lifecycle state of a batch.
    enum State {
        /// The batch is actively processing operations.
        case active
        /// The batch was cancelled with the associated error.
        /// Pending operations are drained; in-flight callbacks are discarded.
        case cancelled(Error)
        /// All operations completed successfully and data has been assembled.
        case completed
    }

    /// The identifier for this batch.
    let batchID: BatchID

    /// The current lifecycle state.
    private(set) var state: State = .active

    /// Chunk indices that have not yet been issued to libnfs.
    private(set) var pendingChunkIndices: [Int]

    /// Chunk indices that have been issued but have not yet received a callback.
    private(set) var inFlightChunkIndices: Set<Int>

    /// Completed chunk data keyed by chunk index for ordered reassembly.
    private var completedChunks: [Int: Data] = [:]

    /// The total number of chunks in this batch.
    private let totalChunks: Int

    /// Creates a new operation batch.
    ///
    /// - Parameters:
    ///   - batchID: The unique identifier for this batch.
    ///   - totalChunks: The number of chunks in the batch. Use `1` for
    ///     single-operation batches (stat, mkdir, etc.).
    init(batchID: BatchID, totalChunks: Int) {
        self.batchID = batchID
        self.totalChunks = totalChunks
        self.pendingChunkIndices = Array(0..<totalChunks)
        self.inFlightChunkIndices = []
    }

    /// Dequeues the next pending chunk index for issuing to libnfs.
    ///
    /// The chunk is moved from `pendingChunkIndices` to `inFlightChunkIndices`.
    ///
    /// - Returns: The chunk index, or `nil` if the batch is cancelled or all
    ///   chunks have already been dequeued.
    func dequeueNextChunk() -> Int? {
        guard case .active = state, !pendingChunkIndices.isEmpty else { return nil }
        let index = pendingChunkIndices.removeFirst()
        inFlightChunkIndices.insert(index)
        return index
    }

    /// Records a successful chunk completion with its data.
    ///
    /// If the batch has been cancelled, the data is silently discarded.
    ///
    /// - Parameters:
    ///   - index: The chunk index that completed.
    ///   - data: The data returned by the NFS operation.
    func recordChunkCompletion(index: Int, data: Data) {
        guard case .active = state else { return }
        inFlightChunkIndices.remove(index)
        completedChunks[index] = data
    }

    /// Whether all chunks in the batch have completed successfully.
    ///
    /// Returns `false` if the batch is cancelled or completed.
    var isComplete: Bool {
        guard case .active = state else { return false }
        return completedChunks.count == totalChunks
    }

    /// Assembles all completed chunk data in chunk-index order.
    ///
    /// - Returns: The concatenated data from all chunks, ordered by index.
    ///   If some chunks are missing, only the available chunks contribute.
    func assembleData() -> Data {
        var result = Data()
        for index in 0..<totalChunks {
            if let chunk = completedChunks[index] {
                result.append(chunk)
            }
        }
        return result
    }

    /// Cancels the batch with the given error.
    ///
    /// - Drains `pendingChunkIndices` so no more chunks are issued.
    /// - Preserves `inFlightChunkIndices` so callbacks can check membership
    ///   and discard results.
    /// - A second call to `cancel` is a no-op; the original error is preserved.
    ///
    /// - Parameter reason: The error that caused the cancellation.
    func cancel(reason: Error) {
        guard case .active = state else { return }
        state = .cancelled(reason)
        pendingChunkIndices.removeAll()
    }

    /// Whether the batch has been cancelled.
    var isCancelled: Bool {
        if case .cancelled = state { return true }
        return false
    }

    /// Transitions the batch to the `.completed` state.
    ///
    /// Call this after all chunks have been assembled and the result has been
    /// delivered to the caller.
    func markCompleted() {
        state = .completed
    }
}

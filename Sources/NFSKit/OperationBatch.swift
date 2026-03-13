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

    /// Completed chunk data keyed by chunk index for ordered reassembly (legacy mode only).
    private var completedChunks: [Int: Data] = [:]

    /// The total number of chunks in this batch.
    private let totalChunks: Int

    // MARK: - Buffer-Slice Mode State

    /// The pre-allocated buffer into which libnfs writes directly (buffer-slice mode only).
    /// `nil` in legacy per-chunk mode.
    private let sliceBuffer: ReadBuffer?

    /// The size of each chunk written to the buffer, used to compute destination offsets
    /// for callers issuing pread calls (buffer-slice mode only).
    private let sliceChunkSize: Int

    /// Tracks actual bytes written per slice index, accounting for short reads at EOF
    /// (buffer-slice mode only).
    private var completedSliceByteCounts: [Int: Int] = [:]

    // MARK: - Initialisers

    /// Creates a new operation batch in legacy per-chunk mode.
    ///
    /// Each chunk delivers its own `Data` value to ``recordChunkCompletion(index:data:)``.
    /// ``assembleData()`` concatenates them in index order.
    ///
    /// - Parameters:
    ///   - batchID: The unique identifier for this batch.
    ///   - totalChunks: The number of chunks in the batch. Use `1` for
    ///     single-operation batches (stat, mkdir, etc.).
    init(batchID: BatchID, totalChunks: Int) {
        self.batchID = batchID
        self.totalChunks = totalChunks
        self.sliceBuffer = nil
        self.sliceChunkSize = 0
        self.pendingChunkIndices = Array(0..<totalChunks)
        self.inFlightChunkIndices = []
    }

    /// Creates a new operation batch in buffer-slice mode.
    ///
    /// In this mode, all chunks write directly into `buffer` at pre-computed
    /// offsets (`chunkIndex * chunkSize`). Callers use
    /// ``recordSliceCompletion(index:bytesWritten:)`` instead of
    /// ``recordChunkCompletion(index:data:)``.  ``assembleData()`` returns a
    /// zero-copy `Data` wrapping the buffer.
    ///
    /// - Parameters:
    ///   - batchID: The unique identifier for this batch.
    ///   - totalChunks: The number of chunks (slices) in the batch.
    ///   - buffer: The pre-allocated buffer. Its size must be at least
    ///     `totalChunks * chunkSize` bytes.  Ownership transfers to `Data`
    ///     on a successful ``assembleData()`` call.
    ///   - chunkSize: The byte size of each chunk used when issuing pread calls.
    ///     The last chunk may write fewer bytes (short read at EOF).
    init(batchID: BatchID, totalChunks: Int, buffer: ReadBuffer, chunkSize: Int) {
        self.batchID = batchID
        self.totalChunks = totalChunks
        self.sliceBuffer = buffer
        self.sliceChunkSize = chunkSize
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

    /// Records a successful chunk completion with its data (legacy per-chunk mode).
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

    /// Records a successful slice completion in buffer-slice mode.
    ///
    /// The slice's bytes have already been written to the shared buffer at offset
    /// `index * chunkSize` by the pread callback. This method records the actual
    /// byte count (which may be less than `chunkSize` for the last slice at EOF).
    ///
    /// If the batch has been cancelled, the record is silently discarded.
    ///
    /// - Parameters:
    ///   - index: The chunk/slice index that completed.
    ///   - bytesWritten: The number of bytes actually written into the buffer for
    ///     this slice. Must be `<= chunkSize`.
    func recordSliceCompletion(index: Int, bytesWritten: Int) {
        guard case .active = state else { return }
        inFlightChunkIndices.remove(index)
        completedSliceByteCounts[index] = bytesWritten
    }

    /// Whether all chunks in the batch have completed successfully.
    ///
    /// Returns `false` if the batch is cancelled or completed.
    var isComplete: Bool {
        guard case .active = state else { return false }
        if sliceBuffer != nil {
            return completedSliceByteCounts.count == totalChunks
        }
        return completedChunks.count == totalChunks
    }

    /// Assembles all completed data.
    ///
    /// **Legacy mode**: concatenates completed chunk `Data` values in index order.
    ///
    /// **Buffer-slice mode**: returns a zero-copy `Data` wrapping the pre-allocated
    /// buffer. The slice-byte-count array is summed to determine the valid length
    /// (accounting for a short final read). After this call the buffer is
    /// *disowned* — its memory is managed by the returned `Data`'s deallocator.
    ///
    /// - Returns: The assembled file data.
    func assembleData() -> Data {
        if let buffer = sliceBuffer {
            // Sum actual bytes written across all slices to handle a short final read.
            var totalBytesWritten = 0
            for index in 0..<totalChunks {
                totalBytesWritten += completedSliceByteCounts[index, default: 0]
            }
            // Transfer buffer ownership to Data. The pointer will be freed via the
            // custom deallocator when the Data value is released.
            buffer.disown()
            return Data(
                bytesNoCopy: buffer.pointer,
                count: totalBytesWritten,
                deallocator: .custom { ptr, _ in ptr.deallocate() }
            )
        }

        // Legacy mode: concatenate chunks in index order.
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

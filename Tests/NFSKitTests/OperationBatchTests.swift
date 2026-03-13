//
//  OperationBatchTests.swift
//  NFSKitTests
//
//  Tests for OperationBatch: batch creation, ordered reassembly,
//  cancellation, and single-operation batch support.
//

import XCTest
@testable import NFSKit

final class OperationBatchTests: XCTestCase {

    // MARK: - BatchID

    func testBatchIDEquality() {
        let a = BatchID(value: 1)
        let b = BatchID(value: 1)
        let c = BatchID(value: 2)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testBatchIDHashable() {
        let a = BatchID(value: 1)
        let b = BatchID(value: 2)
        var set: Set<BatchID> = []
        set.insert(a)
        set.insert(b)
        XCTAssertEqual(set.count, 2)
        set.insert(BatchID(value: 1))
        XCTAssertEqual(set.count, 2, "Duplicate BatchID should not increase set size")
    }

    // MARK: - Batch Creation

    func testBatchCreation() {
        let batch = OperationBatch(batchID: BatchID(value: 1), totalChunks: 5)
        XCTAssertEqual(batch.batchID, BatchID(value: 1))

        switch batch.state {
        case .active:
            break // expected
        default:
            XCTFail("New batch should be in .active state, got \(batch.state)")
        }

        XCTAssertEqual(batch.pendingChunkIndices, Array(0..<5))
        XCTAssertTrue(batch.inFlightChunkIndices.isEmpty)
        XCTAssertFalse(batch.isComplete)
        XCTAssertFalse(batch.isCancelled)
    }

    // MARK: - Dequeue

    func testDequeueMovesChunkFromPendingToInFlight() {
        let batch = OperationBatch(batchID: BatchID(value: 1), totalChunks: 3)

        let index = batch.dequeueNextChunk()
        XCTAssertEqual(index, 0)
        XCTAssertEqual(batch.pendingChunkIndices, [1, 2])
        XCTAssertEqual(batch.inFlightChunkIndices, [0])
    }

    func testDequeueReturnsNilWhenEmpty() {
        let batch = OperationBatch(batchID: BatchID(value: 1), totalChunks: 2)

        _ = batch.dequeueNextChunk() // 0
        _ = batch.dequeueNextChunk() // 1
        let result = batch.dequeueNextChunk()
        XCTAssertNil(result, "Should return nil when all chunks have been dequeued")
    }

    func testDequeueReturnsNilWhenCancelled() {
        let batch = OperationBatch(batchID: BatchID(value: 1), totalChunks: 3)
        batch.cancel(reason: POSIXError(.EIO))

        let result = batch.dequeueNextChunk()
        XCTAssertNil(result, "Cancelled batch should return nil from dequeue")
    }

    // MARK: - Chunk Completion

    func testRecordChunkCompletion() {
        let batch = OperationBatch(batchID: BatchID(value: 1), totalChunks: 2)
        let index = batch.dequeueNextChunk()!
        XCTAssertTrue(batch.inFlightChunkIndices.contains(index))

        batch.recordChunkCompletion(index: index, data: Data([0xAA]))
        XCTAssertFalse(batch.inFlightChunkIndices.contains(index))
    }

    func testRecordChunkCompletionDiscardedWhenCancelled() {
        let batch = OperationBatch(batchID: BatchID(value: 1), totalChunks: 2)
        let index = batch.dequeueNextChunk()!
        batch.cancel(reason: POSIXError(.ECANCELED))

        // Recording after cancellation should be silently discarded
        batch.recordChunkCompletion(index: index, data: Data([0xFF]))

        // The batch should remain cancelled, and assembling should yield no data
        // for this chunk (since the batch is cancelled, isComplete is false)
        XCTAssertTrue(batch.isCancelled)
        XCTAssertFalse(batch.isComplete)
    }

    // MARK: - Completion Tracking

    func testIsCompleteWhenAllChunksFinished() {
        let batch = OperationBatch(batchID: BatchID(value: 1), totalChunks: 3)

        for _ in 0..<3 {
            let idx = batch.dequeueNextChunk()!
            batch.recordChunkCompletion(index: idx, data: Data([UInt8(idx)]))
        }

        XCTAssertTrue(batch.isComplete)
    }

    func testIsNotCompleteWithPendingChunks() {
        let batch = OperationBatch(batchID: BatchID(value: 1), totalChunks: 3)

        // Complete only 2 of 3
        let idx0 = batch.dequeueNextChunk()!
        batch.recordChunkCompletion(index: idx0, data: Data([0x00]))
        let idx1 = batch.dequeueNextChunk()!
        batch.recordChunkCompletion(index: idx1, data: Data([0x01]))

        XCTAssertFalse(batch.isComplete, "Batch should not be complete with outstanding chunks")
    }

    // MARK: - Data Assembly

    func testAssembleDataInOrder() {
        let batch = OperationBatch(batchID: BatchID(value: 1), totalChunks: 3)

        // Dequeue all chunks
        let idx0 = batch.dequeueNextChunk()! // 0
        let idx1 = batch.dequeueNextChunk()! // 1
        let idx2 = batch.dequeueNextChunk()! // 2

        // Complete out of order: 2, 0, 1
        let chunk2 = Data([0x20, 0x21])
        let chunk0 = Data([0x00, 0x01])
        let chunk1 = Data([0x10, 0x11])

        batch.recordChunkCompletion(index: idx2, data: chunk2)
        batch.recordChunkCompletion(index: idx0, data: chunk0)
        batch.recordChunkCompletion(index: idx1, data: chunk1)

        XCTAssertTrue(batch.isComplete)

        let assembled = batch.assembleData()
        let expected = Data([0x00, 0x01, 0x10, 0x11, 0x20, 0x21])
        XCTAssertEqual(assembled, expected, "Assembled data should be in chunk index order")
    }

    // MARK: - Cancellation

    func testCancelDrainsPendingQueue() {
        let batch = OperationBatch(batchID: BatchID(value: 1), totalChunks: 5)

        // Dequeue 2 of 5
        _ = batch.dequeueNextChunk()
        _ = batch.dequeueNextChunk()
        XCTAssertEqual(batch.pendingChunkIndices.count, 3)

        batch.cancel(reason: POSIXError(.EIO))
        XCTAssertTrue(batch.pendingChunkIndices.isEmpty, "Cancel should drain pending queue")
    }

    func testCancelPreservesInFlightForDiscardCheck() {
        let batch = OperationBatch(batchID: BatchID(value: 1), totalChunks: 3)

        _ = batch.dequeueNextChunk() // 0 -> in-flight
        _ = batch.dequeueNextChunk() // 1 -> in-flight
        XCTAssertEqual(batch.inFlightChunkIndices.count, 2)

        batch.cancel(reason: POSIXError(.EIO))
        XCTAssertEqual(batch.inFlightChunkIndices.count, 2,
                        "In-flight indices should be preserved after cancel for discard checks")
    }

    func testCancelSetsStateWithError() {
        let batch = OperationBatch(batchID: BatchID(value: 1), totalChunks: 2)
        let error = POSIXError(.ETIMEDOUT)
        batch.cancel(reason: error)

        switch batch.state {
        case .cancelled(let reason):
            let posixError = reason as? POSIXError
            XCTAssertNotNil(posixError)
            XCTAssertEqual(posixError?.code, .ETIMEDOUT)
        default:
            XCTFail("State should be .cancelled, got \(batch.state)")
        }

        XCTAssertTrue(batch.isCancelled)
    }

    func testDoubleCancelIsNoOp() {
        let batch = OperationBatch(batchID: BatchID(value: 1), totalChunks: 2)
        let firstError = POSIXError(.ETIMEDOUT)
        let secondError = POSIXError(.EIO)

        batch.cancel(reason: firstError)
        batch.cancel(reason: secondError)

        // State should still reflect the first cancellation error
        switch batch.state {
        case .cancelled(let reason):
            let posixError = reason as? POSIXError
            XCTAssertEqual(posixError?.code, .ETIMEDOUT,
                           "Second cancel should be a no-op; first error should be preserved")
        default:
            XCTFail("State should still be .cancelled")
        }
    }

    // MARK: - Single-Operation Batch

    func testSingleOperationBatch() {
        let batch = OperationBatch(batchID: BatchID(value: 42), totalChunks: 1)

        // Single-op batch: chunk 0 is the only chunk
        XCTAssertEqual(batch.pendingChunkIndices, [0])

        let idx = batch.dequeueNextChunk()
        XCTAssertEqual(idx, 0)
        XCTAssertTrue(batch.pendingChunkIndices.isEmpty)
        XCTAssertEqual(batch.inFlightChunkIndices, [0])

        // Complete the single chunk
        let data = Data([0xDE, 0xAD])
        batch.recordChunkCompletion(index: 0, data: data)

        XCTAssertTrue(batch.isComplete)
        XCTAssertEqual(batch.assembleData(), data)
    }

    // MARK: - Mark Completed

    func testMarkCompleted() {
        let batch = OperationBatch(batchID: BatchID(value: 1), totalChunks: 1)
        _ = batch.dequeueNextChunk()
        batch.recordChunkCompletion(index: 0, data: Data([0x01]))
        XCTAssertTrue(batch.isComplete)

        batch.markCompleted()

        switch batch.state {
        case .completed:
            break // expected
        default:
            XCTFail("State should be .completed after markCompleted(), got \(batch.state)")
        }
    }

    // MARK: - Buffer-Slice Mode

    func testBufferModeCreation() {
        let buffer = ReadBuffer(byteCount: 1024)
        let batch = OperationBatch(batchID: BatchID(value: 10), totalChunks: 4, buffer: buffer, chunkSize: 256)

        XCTAssertEqual(batch.batchID, BatchID(value: 10))

        switch batch.state {
        case .active:
            break // expected
        default:
            XCTFail("New buffer-mode batch should be in .active state, got \(batch.state)")
        }

        // Buffer mode still uses the standard pending/in-flight machinery.
        XCTAssertEqual(batch.pendingChunkIndices, [0, 1, 2, 3])
        XCTAssertTrue(batch.inFlightChunkIndices.isEmpty)
        XCTAssertFalse(batch.isComplete)
        XCTAssertFalse(batch.isCancelled)
    }

    func testBufferModeRecordSliceCompletion() {
        let totalBytes = 1024
        let chunkSize = 256
        let totalChunks = 4
        let buffer = ReadBuffer(byteCount: totalBytes)
        let batch = OperationBatch(
            batchID: BatchID(value: 11),
            totalChunks: totalChunks,
            buffer: buffer,
            chunkSize: chunkSize
        )

        // Dequeue and complete all slices.
        for chunkIndex in 0..<totalChunks {
            let dequeued = batch.dequeueNextChunk()
            XCTAssertEqual(dequeued, chunkIndex)
            // Simulate a full-sized slice completing.
            batch.recordSliceCompletion(index: chunkIndex, bytesWritten: chunkSize)
        }

        XCTAssertTrue(batch.isComplete, "Batch should be complete when all slices are recorded")
    }

    func testBufferModeIsCompleteReturnsFalseWithPartialSlices() {
        let buffer = ReadBuffer(byteCount: 1024)
        let batch = OperationBatch(
            batchID: BatchID(value: 12),
            totalChunks: 4,
            buffer: buffer,
            chunkSize: 256
        )

        _ = batch.dequeueNextChunk()
        batch.recordSliceCompletion(index: 0, bytesWritten: 256)
        _ = batch.dequeueNextChunk()
        batch.recordSliceCompletion(index: 1, bytesWritten: 256)

        XCTAssertFalse(batch.isComplete, "Batch should not be complete with two slices still pending")
    }

    func testBufferModeAssembleData() {
        // Write known bytes into a buffer across two slices,
        // then verify assembleData() wraps exactly those bytes.
        let chunkSize = 4
        let totalChunks = 2
        let buffer = ReadBuffer(byteCount: chunkSize * totalChunks)

        // Write test data directly into the buffer memory.
        let rawPtr = buffer.pointer
        rawPtr.storeBytes(of: UInt8(0xAA), toByteOffset: 0, as: UInt8.self)
        rawPtr.storeBytes(of: UInt8(0xBB), toByteOffset: 1, as: UInt8.self)
        rawPtr.storeBytes(of: UInt8(0xCC), toByteOffset: 2, as: UInt8.self)
        rawPtr.storeBytes(of: UInt8(0xDD), toByteOffset: 3, as: UInt8.self)
        rawPtr.storeBytes(of: UInt8(0x11), toByteOffset: 4, as: UInt8.self)
        rawPtr.storeBytes(of: UInt8(0x22), toByteOffset: 5, as: UInt8.self)
        rawPtr.storeBytes(of: UInt8(0x33), toByteOffset: 6, as: UInt8.self)
        rawPtr.storeBytes(of: UInt8(0x44), toByteOffset: 7, as: UInt8.self)

        let batch = OperationBatch(
            batchID: BatchID(value: 13),
            totalChunks: totalChunks,
            buffer: buffer,
            chunkSize: chunkSize
        )

        _ = batch.dequeueNextChunk()
        batch.recordSliceCompletion(index: 0, bytesWritten: 4)
        _ = batch.dequeueNextChunk()
        // Simulate the last slice returning only 3 bytes (short read at EOF).
        batch.recordSliceCompletion(index: 1, bytesWritten: 3)

        XCTAssertTrue(batch.isComplete)

        let assembled = batch.assembleData()

        // Total bytes = 4 + 3 = 7; buffer ownership should transfer.
        XCTAssertEqual(assembled.count, 7, "assembleData should return exactly totalBytesWritten bytes")
        XCTAssertEqual(assembled[0], 0xAA)
        XCTAssertEqual(assembled[1], 0xBB)
        XCTAssertEqual(assembled[2], 0xCC)
        XCTAssertEqual(assembled[3], 0xDD)
        XCTAssertEqual(assembled[4], 0x11)
        XCTAssertEqual(assembled[5], 0x22)
        XCTAssertEqual(assembled[6], 0x33)

        // After assembleData(), the buffer has been disowned; it must not free on deinit.
        XCTAssertFalse(buffer.isOwned, "Buffer should be disowned after assembleData()")
    }

    func testBufferModeAssembleDataDiscardsOnCancel() {
        let buffer = ReadBuffer(byteCount: 512)
        let batch = OperationBatch(
            batchID: BatchID(value: 14),
            totalChunks: 2,
            buffer: buffer,
            chunkSize: 256
        )

        _ = batch.dequeueNextChunk()
        batch.cancel(reason: POSIXError(.ECANCELED))

        // Cancellation after a slice was in-flight; buffer is still owned (not disowned).
        XCTAssertTrue(batch.isCancelled)
        XCTAssertTrue(buffer.isOwned, "Buffer should remain owned (and be freed by deinit) when cancelled")
    }

    func testLegacyModeStillWorks() {
        // Verify existing per-chunk Data mode is unaffected by the new buffer-slice mode.
        let batch = OperationBatch(batchID: BatchID(value: 99), totalChunks: 3)

        let idx0 = batch.dequeueNextChunk()!
        let idx1 = batch.dequeueNextChunk()!
        let idx2 = batch.dequeueNextChunk()!

        batch.recordChunkCompletion(index: idx0, data: Data([0x01, 0x02]))
        batch.recordChunkCompletion(index: idx1, data: Data([0x03, 0x04]))
        batch.recordChunkCompletion(index: idx2, data: Data([0x05, 0x06]))

        XCTAssertTrue(batch.isComplete)
        XCTAssertEqual(batch.assembleData(), Data([0x01, 0x02, 0x03, 0x04, 0x05, 0x06]))
    }
}

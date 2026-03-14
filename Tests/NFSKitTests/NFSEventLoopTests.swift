//
//  NFSEventLoopTests.swift
//  NFSKitTests
//
//  Tests for NFSEventLoop: lifecycle, type-level checks, and pipeline
//  controller integration.
//

import XCTest
import nfs
@testable import NFSKit

// MARK: - NFSEventLoop Lifecycle Tests

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class NFSEventLoopTests: XCTestCase {

    // MARK: 1. Event loop can be created (nfs_init_context succeeds)

    func testEventLoopCreation() throws {
        let loop = try NFSEventLoop(timeout: 30)
        XCTAssertNotNil(loop, "NFSEventLoop should initialize successfully")
    }

    // MARK: 2. Event loop conforms to Sendable (compile-time check)

    func testEventLoopIsSendable() throws {
        let loop = try NFSEventLoop(timeout: 30)
        let _: any Sendable = loop
        XCTAssertNotNil(loop)
    }

    // MARK: 3. Shutdown errors all pending continuations

    func testShutdownErrorsPendingContinuations() async throws {
        let loop = try NFSEventLoop(timeout: 30)

        let expectation = XCTestExpectation(description: "Continuation should be resumed with error")

        // Submit a stat operation. Since we're not connected to any server,
        // nfs_stat64_async may fail immediately or the continuation will
        // be left pending. Either way, shutdown should clean things up.
        let task = Task<Void, Never> {
            do {
                _ = try await loop.stat("/")
                XCTFail("Should have thrown an error")
            } catch {
                // Expected: error from immediate failure or shutdown
                expectation.fulfill()
            }
        }

        // Give the submit a moment to enqueue
        try await Task.sleep(nanoseconds: 50_000_000)

        loop.shutdown()

        await fulfillment(of: [expectation], timeout: 2.0)
        task.cancel()
    }

    // MARK: 4. Pipeline controllers are independent

    func testPipelineControllersAreIndependent() throws {
        let loop = try NFSEventLoop(timeout: 30)

        let (bulkDepth, metaDepth) = loop.pipelineDepths
        XCTAssertEqual(bulkDepth, 2, "Bulk controller should start at default depth")
        XCTAssertEqual(metaDepth, 2, "Metadata controller should start at default depth")
    }

    // MARK: 5. Multiple event loops can coexist

    func testMultipleEventLoopsCanCoexist() throws {
        let loop1 = try NFSEventLoop(timeout: 30)
        let loop2 = try NFSEventLoop(timeout: 60)
        XCTAssertNotNil(loop1)
        XCTAssertNotNil(loop2)
    }

    // MARK: 6. Shutdown is idempotent

    func testShutdownIsIdempotent() throws {
        let loop = try NFSEventLoop(timeout: 30)
        loop.shutdown()
        loop.shutdown()
    }

    // MARK: 7. Submit after shutdown throws

    func testSubmitAfterShutdownThrows() async throws {
        let loop = try NFSEventLoop(timeout: 30)
        loop.shutdown()

        do {
            _ = try await loop.stat("/")
            XCTFail("Submit after shutdown should throw")
        } catch {
            if let posixError = error as? POSIXError {
                XCTAssertEqual(posixError.code, .ENOTCONN,
                               "Submit after shutdown should throw ENOTCONN")
            }
        }
    }

    // MARK: 8. Performance tuning methods work pre-connect

    func testPerformanceTuningPreConnect() throws {
        let loop = try NFSEventLoop(timeout: 30)
        XCTAssertNoThrow(try loop.setReadMax(1_048_576 as Int))
        XCTAssertNoThrow(try loop.setAutoReconnect(3))
    }

    // MARK: 9. Version get/set round-trip

    func testVersionGetSetRoundTrip() throws {
        let loop = try NFSEventLoop(timeout: 30)
        let original = try loop.getVersion()
        XCTAssertEqual(original, 3, "Default NFS version should be 3")

        try loop.setVersion(4)
        let version = try loop.getVersion()
        XCTAssertEqual(version, 4, "Version should be 4 after setting it")
    }

    // MARK: 10. Callback data retains and releases correctly

    func testCallbackDataLifecycle() {
        let testQueue = DispatchQueue(label: "test.callback")
        var resumed = false
        let cbData = NFSEventLoop.CallbackData(
            continuationID: 1,
            queue: testQueue,
            dataHandler: { _, _ in .success(()) },
            resume: { _ in resumed = true }
        )

        let ptr = Unmanaged.passRetained(cbData).toOpaque()
        XCTAssertNotNil(ptr)

        let recovered = Unmanaged<NFSEventLoop.CallbackData>.fromOpaque(ptr).takeRetainedValue()
        testQueue.sync {
            recovered.resume(.success(42))
        }
        XCTAssertTrue(resumed, "Resume should have been called")
    }

    // MARK: 11. PendingOperation stores type correctly

    func testPendingOperationStoresType() {
        let op = NFSEventLoop.PendingOperation(
            id: 1,
            type: .read,
            execute: { _ in 0 },
            failureCleanup: { _, _ in }
        )
        XCTAssertEqual(op.type, .read)
        XCTAssertEqual(op.type.category, .bulk)
        XCTAssertEqual(op.id, 1)
    }

    // MARK: 12. In-flight count tracking

    func testInFlightCountTracking() throws {
        let loop = try NFSEventLoop(timeout: 30)
        let counts = loop.inFlightCounts
        XCTAssertEqual(counts[.bulk], 0, "Initial bulk in-flight count should be 0")
        XCTAssertEqual(counts[.metadata], 0, "Initial metadata in-flight count should be 0")
    }

    // MARK: 13. getReadMax returns a positive value after context creation

    func testGetReadMaxReturnsPositiveValue() throws {
        let loop = try NFSEventLoop(timeout: 30)
        let readMax = try loop.getReadMax()
        // libnfs defaults to some positive chunk size (e.g. 1048576 or 131072).
        XCTAssertGreaterThan(readMax, 0, "getReadMax() should return a positive byte count")
    }

    // MARK: 14. getReadMax reflects the value set by setReadMax

    func testGetReadMaxReflectsSetReadMax() throws {
        let loop = try NFSEventLoop(timeout: 30)
        let desiredReadMax = 131_072
        try loop.setReadMax(desiredReadMax)
        let readMax = try loop.getReadMax()
        XCTAssertEqual(readMax, desiredReadMax, "getReadMax() should reflect the value set by setReadMax()")
    }

    // MARK: 15. getReadMax throws after shutdown

    func testGetReadMaxThrowsAfterShutdown() throws {
        let loop = try NFSEventLoop(timeout: 30)
        loop.shutdown()
        // After shutdown, context is nil. Optional.unwrap() on nil throws ENODATA.
        XCTAssertThrowsError(try loop.getReadMax()) { error in
            XCTAssertNotNil(error as? POSIXError,
                            "getReadMax() should throw a POSIXError after shutdown")
        }
    }

    // MARK: 16. preadIntoBuffer throws ENOTCONN without a live connection

    func testPreadIntoBufferThrowsWithoutConnection() async throws {
        let loop = try NFSEventLoop(timeout: 30)
        // No connection — pread on a non-existent handle ID must throw EBADF.
        let buffer = ReadBuffer(byteCount: 1024)
        do {
            _ = try await loop.preadIntoBuffer(
                handleID: 9999,
                buffer: buffer.pointer,
                offset: 0,
                count: 1024
            )
            XCTFail("preadIntoBuffer should throw for an invalid handle ID")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .EBADF,
                           "Expected EBADF for an invalid handle ID, got \(error.code)")
        }
    }
}

// MARK: - CallbackData Tests

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class CallbackDataTests: XCTestCase {

    func testCallbackDataHandlerSuccess() {
        let testQueue = DispatchQueue(label: "test.callback.success")
        var receivedResult: Result<Any, Error>?
        let cbData = NFSEventLoop.CallbackData(
            continuationID: 42,
            queue: testQueue,
            dataHandler: { _, _ in
                return .success("hello")
            },
            resume: { result in
                receivedResult = result
            }
        )

        XCTAssertEqual(cbData.continuationID, 42)

        let handlerResult = cbData.dataHandler(0, nil as UnsafeMutableRawPointer?)
        testQueue.sync {
            cbData.resume(handlerResult)
        }

        if case .success(let value) = receivedResult {
            XCTAssertEqual(value as? String, "hello")
        } else {
            XCTFail("Expected success result")
        }
    }

    func testCallbackDataHandlerFailure() {
        let testQueue = DispatchQueue(label: "test.callback.failure")
        var receivedResult: Result<Any, Error>?
        let cbData = NFSEventLoop.CallbackData(
            continuationID: 1,
            queue: testQueue,
            dataHandler: { _, _ in
                return .failure(POSIXError(.EIO))
            },
            resume: { result in
                receivedResult = result
            }
        )

        let handlerResult = cbData.dataHandler(0, nil as UnsafeMutableRawPointer?)
        testQueue.sync {
            cbData.resume(handlerResult)
        }

        if case .failure(let error) = receivedResult {
            let posixError = error as? POSIXError
            XCTAssertEqual(posixError?.code, .EIO)
        } else {
            XCTFail("Expected failure result")
        }
    }
}

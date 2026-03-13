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
        XCTAssertNoThrow(try loop.setReadMax(1_048_576))
        XCTAssertNoThrow(try loop.setReadAhead(4096))
        XCTAssertNoThrow(try loop.setPageCache(pages: 256, ttl: 60))
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
        var resumed = false
        let cbData = NFSEventLoop.CallbackData(
            continuationID: 1,
            dataHandler: { _, _ in .success(()) },
            resume: { _ in resumed = true }
        )

        let ptr = Unmanaged.passRetained(cbData).toOpaque()
        XCTAssertNotNil(ptr)

        let recovered = Unmanaged<NFSEventLoop.CallbackData>.fromOpaque(ptr).takeRetainedValue()
        recovered.resume(.success(42))
        XCTAssertTrue(resumed, "Resume should have been called")
    }

    // MARK: 11. PendingOperation stores type correctly

    func testPendingOperationStoresType() {
        let op = NFSEventLoop.PendingOperation(
            id: 1,
            type: .read,
            execute: { _ in 0 }
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
}

// MARK: - CallbackData Tests

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class CallbackDataTests: XCTestCase {

    func testCallbackDataHandlerSuccess() {
        var receivedResult: Result<Any, Error>?
        let cbData = NFSEventLoop.CallbackData(
            continuationID: 42,
            dataHandler: { _, _ in
                return .success("hello")
            },
            resume: { result in
                receivedResult = result
            }
        )

        XCTAssertEqual(cbData.continuationID, 42)

        let handlerResult = cbData.dataHandler(0, nil)
        cbData.resume(handlerResult)

        if case .success(let value) = receivedResult {
            XCTAssertEqual(value as? String, "hello")
        } else {
            XCTFail("Expected success result")
        }
    }

    func testCallbackDataHandlerFailure() {
        var receivedResult: Result<Any, Error>?
        let cbData = NFSEventLoop.CallbackData(
            continuationID: 1,
            dataHandler: { _, _ in
                return .failure(POSIXError(.EIO))
            },
            resume: { result in
                receivedResult = result
            }
        )

        let handlerResult = cbData.dataHandler(0, nil)
        cbData.resume(handlerResult)

        if case .failure(let error) = receivedResult {
            let posixError = error as? POSIXError
            XCTAssertEqual(posixError?.code, .EIO)
        } else {
            XCTFail("Expected failure result")
        }
    }
}

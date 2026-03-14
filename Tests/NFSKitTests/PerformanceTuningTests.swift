//
//  PerformanceTuningTests.swift
//  NFSKitTests
//
//  Tests for the performance tuning API on NFSEventLoop and NFSClient.
//

import XCTest
@testable import NFSKit

// MARK: - NFSEventLoop extended performance tuning (libnfs 6.x)

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class NFSEventLoopPerformanceTuningTests: XCTestCase {

    private var eventLoop: NFSEventLoop!

    override func setUpWithError() throws {
        try super.setUpWithError()
        eventLoop = try NFSEventLoop(timeout: 10)
    }

    override func tearDown() {
        eventLoop = nil
        super.tearDown()
    }

    func testSetWriteMaxDoesNotThrow() throws {
        XCTAssertNoThrow(try eventLoop.setWriteMax(2_097_152))  // 2 MB
    }

    func testSetRetransmissionsDoesNotThrow() throws {
        XCTAssertNoThrow(try eventLoop.setRetransmissions(3))
    }

    func testSetTimeoutDoesNotThrow() throws {
        XCTAssertNoThrow(try eventLoop.setTimeout(5000))         // 5 seconds
    }
}

// MARK: - NFSClient.configurePerformance (throwing API)

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class NFSClientPerformanceTuningTests: XCTestCase {

    func testConfigurePerformanceDoesNotThrow() throws {
        let client = try XCTUnwrap(try NFSClient(url: URL(string: "nfs://localhost")!))
        XCTAssertNoThrow(try client.configurePerformance(readMax: 1024))
    }

    func testConfigurePerformanceAllNilsIsNoOp() throws {
        let client = try XCTUnwrap(try NFSClient(url: URL(string: "nfs://localhost")!))
        XCTAssertNoThrow(try client.configurePerformance())
    }

    func testConfigurePerformanceWithMultipleParams() throws {
        let client = try XCTUnwrap(try NFSClient(url: URL(string: "nfs://localhost")!))
        XCTAssertNoThrow(try client.configurePerformance(
            readMax: 1_048_576,
            autoReconnect: -1
        ))
    }

    func testConfigurePerformanceWithNewParams() throws {
        let client = try XCTUnwrap(try NFSClient(url: URL(string: "nfs://localhost")!))
        XCTAssertNoThrow(try client.configurePerformance(
            writeMax: 2_097_152,
            retransmissions: 3,
            timeout: 5000
        ))
    }
}

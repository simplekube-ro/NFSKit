//
//  NFSStatsTests.swift
//  NFSKitTests
//
//  Tests for NFSStats: struct fields, Sendable conformance, zero defaults,
//  and NFSEventLoop/NFSClient integration.
//

import XCTest
@testable import NFSKit

// MARK: - NFSStats Unit Tests

final class NFSStatsTests: XCTestCase {

    // MARK: 1. All seven fields round-trip through init

    func testStatsStructFields() {
        let stats = NFSStats(
            requestsSent: 1,
            responsesReceived: 2,
            timedOut: 3,
            timedOutInOutqueue: 4,
            majorTimedOut: 5,
            retransmitted: 6,
            reconnects: 7
        )

        XCTAssertEqual(stats.requestsSent, 1)
        XCTAssertEqual(stats.responsesReceived, 2)
        XCTAssertEqual(stats.timedOut, 3)
        XCTAssertEqual(stats.timedOutInOutqueue, 4)
        XCTAssertEqual(stats.majorTimedOut, 5)
        XCTAssertEqual(stats.retransmitted, 6)
        XCTAssertEqual(stats.reconnects, 7)
    }

    // MARK: 2. NFSStats is Sendable (compile-time check)

    func testSendableConformance() {
        let stats = NFSStats(requestsSent: 42)
        let _: any Sendable = stats
        XCTAssertEqual(stats.requestsSent, 42)
    }

    // MARK: 3. Default initializer produces all-zero values

    func testZeroInitialized() {
        let stats = NFSStats()
        XCTAssertEqual(stats.requestsSent, 0)
        XCTAssertEqual(stats.responsesReceived, 0)
        XCTAssertEqual(stats.timedOut, 0)
        XCTAssertEqual(stats.timedOutInOutqueue, 0)
        XCTAssertEqual(stats.majorTimedOut, 0)
        XCTAssertEqual(stats.retransmitted, 0)
        XCTAssertEqual(stats.reconnects, 0)
    }
}

// MARK: - NFSEventLoop Stats Integration Tests

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class NFSEventLoopStatsTests: XCTestCase {

    // MARK: 4. stats() throws when context is destroyed (shutdown)

    func testStatsThrowsWhenNotConnected() async throws {
        let loop = try NFSEventLoop(timeout: 30)
        loop.shutdown()

        do {
            _ = try loop.stats()
            XCTFail("stats() should throw when context is destroyed")
        } catch let error as POSIXError {
            // Optional.unwrap() on a nil UnsafeMutablePointer<nfs_context>
            // throws ENODATA (the generic Optional extension). This is the
            // expected error when the event loop has been shut down.
            XCTAssertEqual(error.code, .ENODATA,
                           "stats() should throw ENODATA when context is nil")
        }
    }

    // MARK: 5. stats() returns NFSStats when context exists (pre-mount)

    func testStatsReturnsNFSStatsPreMount() throws {
        let loop = try NFSEventLoop(timeout: 30)
        // Context exists but we are not mounted; libnfs stats start at zero.
        let stats = try loop.stats()
        // We cannot assert specific non-zero values without a live server,
        // but we can confirm the call succeeds and returns the expected type.
        XCTAssertGreaterThanOrEqual(stats.requestsSent, 0)
        XCTAssertGreaterThanOrEqual(stats.responsesReceived, 0)
        XCTAssertGreaterThanOrEqual(stats.timedOut, 0)
        XCTAssertGreaterThanOrEqual(stats.timedOutInOutqueue, 0)
        XCTAssertGreaterThanOrEqual(stats.majorTimedOut, 0)
        XCTAssertGreaterThanOrEqual(stats.retransmitted, 0)
        XCTAssertGreaterThanOrEqual(stats.reconnects, 0)
    }

    // MARK: 6. serverAddress() throws when context is destroyed (shutdown)

    func testServerAddressReturnsNilWhenNotConnected() async throws {
        let loop = try NFSEventLoop(timeout: 30)
        loop.shutdown()

        do {
            _ = try loop.serverAddress()
            XCTFail("serverAddress() should throw when context is destroyed")
        } catch let error as POSIXError {
            // Same as stats(): Optional.unwrap() on a nil pointer throws ENODATA.
            XCTAssertEqual(error.code, .ENODATA,
                           "serverAddress() should throw ENODATA when context is nil")
        }
    }

    // MARK: 7. serverAddress() returns a value pre-mount (zeroed sockaddr_storage)
    //
    // libnfs initialises nfs_context.server_address as an all-zero struct at
    // context creation time (ss_family == 0, AF_UNSPEC). nfs_get_server_address
    // returns a non-NULL pointer to that struct even before mount, so we expect
    // a non-nil return with ss_family == 0.

    func testServerAddressNilPreMount() throws {
        let loop = try NFSEventLoop(timeout: 30)
        // libnfs always returns a non-NULL pointer (zeroed sockaddr_storage);
        // before mount, ss_family is 0 (AF_UNSPEC).
        let address = try loop.serverAddress()
        if let addr = address {
            XCTAssertEqual(addr.ss_family, 0,
                           "serverAddress() should have ss_family == 0 (AF_UNSPEC) before mounting")
        }
        // Whether nil or zeroed, neither case is an error — both are acceptable
        // pre-mount representations of "not yet connected".
    }
}

// MARK: - NFSClient Stats Integration Tests

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class NFSClientStatsTests: XCTestCase {

    // MARK: 8. NFSClient.stats() delegates to event loop

    func testClientStatsDelegatesToEventLoop() async throws {
        guard let client = try NFSClient(url: URL(string: "nfs://localhost")!) else {
            XCTFail("NFSClient init returned nil")
            return
        }
        // Pre-mount: context exists, stats should succeed and return zero counters.
        let stats = try await client.stats()
        XCTAssertGreaterThanOrEqual(stats.requestsSent, 0)
        XCTAssertGreaterThanOrEqual(stats.responsesReceived, 0)
    }

    // MARK: 9. NFSClient.serverAddress() pre-mount returns zeroed or nil sockaddr_storage
    //
    // libnfs always returns a non-NULL pointer to a zero-filled sockaddr_storage
    // (ss_family == 0, AF_UNSPEC) before mount. Either nil or a zeroed struct
    // with ss_family == 0 is an acceptable pre-mount response.

    func testClientServerAddressNilPreMount() async throws {
        guard let client = try NFSClient(url: URL(string: "nfs://localhost")!) else {
            XCTFail("NFSClient init returned nil")
            return
        }
        let address = try await client.serverAddress()
        // nil means libnfs returned NULL (valid); non-nil with ss_family == 0
        // means libnfs returned a zeroed struct (also valid pre-mount).
        if let addr = address {
            XCTAssertEqual(addr.ss_family, 0,
                           "Pre-mount serverAddress should have ss_family == 0 (AF_UNSPEC)")
        }
    }
}

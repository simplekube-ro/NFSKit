//
//  PerformanceTuningTests.swift
//  NFSKitTests
//
//  Tests for the performance tuning API added in NFSContext and NFSClient.
//

import XCTest
@testable import NFSKit

final class NFSContextPerformanceTuningTests: XCTestCase {

    private var ctx: NFSContext!

    override func setUp() {
        super.setUp()
        ctx = try? NFSContext(timeout: 10)
    }

    override func tearDown() {
        ctx = nil
        super.tearDown()
    }

    // MARK: - NFSContext init sanity

    func testContextCreation() {
        XCTAssertNotNil(ctx, "NFSContext should initialize without a server connection")
    }

    // MARK: - setReadMax

    func testSetReadMaxDoesNotThrow() throws {
        let ctx = try XCTUnwrap(ctx)
        XCTAssertNoThrow(try ctx.setReadMax(1_048_576))       // 1 MB
    }

    func testSetReadMaxZero() throws {
        let ctx = try XCTUnwrap(ctx)
        XCTAssertNoThrow(try ctx.setReadMax(0))
    }

    // MARK: - setReadAhead

    func testSetReadAheadDoesNotThrow() throws {
        let ctx = try XCTUnwrap(ctx)
        XCTAssertNoThrow(try ctx.setReadAhead(4096))
    }

    func testSetReadAheadZeroDisables() throws {
        let ctx = try XCTUnwrap(ctx)
        XCTAssertNoThrow(try ctx.setReadAhead(0))
    }

    // MARK: - setPageCache

    func testSetPageCacheDoesNotThrow() throws {
        let ctx = try XCTUnwrap(ctx)
        XCTAssertNoThrow(try ctx.setPageCache(pages: 256, ttl: 60))
    }

    func testSetPageCacheDefaultTTL() throws {
        let ctx = try XCTUnwrap(ctx)
        // Uses the default ttl = 30 when not specified
        XCTAssertNoThrow(try ctx.setPageCache(pages: 128))
    }

    func testSetPageCacheZeroPagesDisables() throws {
        let ctx = try XCTUnwrap(ctx)
        XCTAssertNoThrow(try ctx.setPageCache(pages: 0))
    }

    // MARK: - setAutoReconnect

    func testSetAutoReconnectPositive() throws {
        let ctx = try XCTUnwrap(ctx)
        XCTAssertNoThrow(try ctx.setAutoReconnect(5))
    }

    func testSetAutoReconnectInfinite() throws {
        let ctx = try XCTUnwrap(ctx)
        XCTAssertNoThrow(try ctx.setAutoReconnect(-1))         // -1 = infinite retries
    }

    func testSetAutoReconnectDisabled() throws {
        let ctx = try XCTUnwrap(ctx)
        XCTAssertNoThrow(try ctx.setAutoReconnect(0))          // 0 = disabled
    }

    // MARK: - setVersion / getVersion round-trip

    func testSetAndGetVersion() throws {
        let ctx = try XCTUnwrap(ctx)
        // libnfs defaults to NFS version 3
        let original = try ctx.getVersion()
        XCTAssertEqual(original, 3, "Default version should be NFS v3")

        try ctx.setVersion(4)
        let version = try ctx.getVersion()
        XCTAssertEqual(version, 4, "Version should be 4 after setting it")
    }

    func testSetVersionReturnsValue() throws {
        let ctx = try XCTUnwrap(ctx)
        let result = try ctx.setVersion(4)
        // nfs_set_version returns the previous version
        XCTAssertTrue(result >= 0, "setVersion should return a non-negative value")
    }

    // MARK: - Multiple settings composed

    func testMultipleSettingsCanBeAppliedSequentially() throws {
        let ctx = try XCTUnwrap(ctx)
        XCTAssertNoThrow(try ctx.setReadMax(2_097_152))
        XCTAssertNoThrow(try ctx.setReadAhead(8192))
        XCTAssertNoThrow(try ctx.setPageCache(pages: 512, ttl: 120))
        XCTAssertNoThrow(try ctx.setAutoReconnect(3))
        XCTAssertNoThrow(try ctx.setVersion(3))
    }
}

// MARK: - NFSClient.configurePerformance

final class NFSClientPerformanceTuningTests: XCTestCase {

    func testConfigurePerformanceThrowsWhenNotConnected() throws {
        // NFSClient context.unwrap() checks fileDescriptor >= 0,
        // which is -1 before mount, so this should throw ENOTCONN.
        let client = try XCTUnwrap(try NFSClient(url: URL(string: "nfs://localhost")!))

        XCTAssertThrowsError(try client.configurePerformance(readMax: 1024)) { error in
            guard let posixError = error as? POSIXError else {
                XCTFail("Expected POSIXError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(posixError.code, .ENOTCONN,
                           "Should fail with ENOTCONN when not connected")
        }
    }

    func testConfigurePerformanceAllNilsThrowsWhenNotConnected() throws {
        // Even with all nil parameters, the method still calls context.unwrap()
        let client = try XCTUnwrap(try NFSClient(url: URL(string: "nfs://localhost")!))

        XCTAssertThrowsError(try client.configurePerformance()) { error in
            guard let posixError = error as? POSIXError else {
                XCTFail("Expected POSIXError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(posixError.code, .ENOTCONN)
        }
    }

    func testConfigurePerformanceWithMultipleParams() throws {
        let client = try XCTUnwrap(try NFSClient(url: URL(string: "nfs://localhost")!))

        // Verify that passing multiple parameters still hits the same guard
        XCTAssertThrowsError(try client.configurePerformance(
            readMax: 1_048_576,
            readAhead: 4096,
            pageCachePages: 256,
            pageCacheTTL: 60,
            autoReconnect: -1
        )) { error in
            guard let posixError = error as? POSIXError else {
                XCTFail("Expected POSIXError, got \(type(of: error))")
                return
            }
            XCTAssertEqual(posixError.code, .ENOTCONN)
        }
    }
}

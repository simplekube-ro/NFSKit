import XCTest
@testable import NFSKit

final class NFSKitTests: XCTestCase {

    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
    }
}

// MARK: - NFSClient.contents pre-allocated buffer path (unit-level)

/// These tests validate logic that can be exercised without a live NFS server.
/// Tests that require real I/O are left for integration testing.
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class NFSClientContentsTests: XCTestCase {

    /// Verify that the 64 MB threshold constant has the expected value.
    /// This is the dividing line between the pre-allocated buffer path and the
    /// legacy chunked path.
    func testContentsBufferThresholdValue() {
        XCTAssertEqual(NFSClient.contentsBufferThreshold, 67_108_864,
                       "Buffer threshold should be exactly 64 MB (67_108_864 bytes)")
    }

    /// Verify that files at the threshold boundary are classified correctly.
    func testContentsUsesBufferPathAtThreshold() {
        let atThreshold = Int64(NFSClient.contentsBufferThreshold)
        let justAbove = atThreshold + 1
        XCTAssertTrue(NFSClient.shouldUsePreallocatedBuffer(fileSize: atThreshold),
                      "Files at exactly 64 MB should use the pre-allocated buffer path")
        XCTAssertFalse(NFSClient.shouldUsePreallocatedBuffer(fileSize: justAbove),
                       "Files just above 64 MB should use the legacy chunked path")
    }

    func testContentsUsesBufferPathForSmallFiles() {
        XCTAssertTrue(NFSClient.shouldUsePreallocatedBuffer(fileSize: 1),
                      "1-byte file should use the pre-allocated buffer path")
        XCTAssertTrue(NFSClient.shouldUsePreallocatedBuffer(fileSize: 1_048_576),
                      "1 MB file should use the pre-allocated buffer path")
    }

    func testContentsUsesLegacyPathForLargeFiles() {
        let largeFile = Int64(100_000_000)
        XCTAssertFalse(NFSClient.shouldUsePreallocatedBuffer(fileSize: largeFile),
                       "100 MB file should use the legacy chunked path")
    }
}

// MARK: - NFSClient Sendable conformance

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class NFSClientSendableTests: XCTestCase {

    func testNFSClientIsSendable() throws {
        let client = try XCTUnwrap(try NFSClient(url: URL(string: "nfs://localhost")!))
        let _: any Sendable = client
        // If this compiles, Sendable conformance is verified
        XCTAssertNotNil(client)
    }

    func testNFSClientCreation() throws {
        let client = try XCTUnwrap(try NFSClient(url: URL(string: "nfs://localhost")!))
        XCTAssertEqual(client.url.host, "localhost")
    }

    func testNFSClientReturnsNilForBadURL() throws {
        // A URL with no host should return nil
        let client = try NFSClient(url: URL(string: "nfs://")!)
        XCTAssertNil(client)
    }

    func testNFSClientConfigurePerformanceDoesNotThrow() throws {
        let client = try XCTUnwrap(try NFSClient(url: URL(string: "nfs://localhost")!))
        try client.configurePerformance(readMax: 1024)
        try client.configurePerformance(autoReconnect: -1)
    }

    func testNFSClientConfigurePerformanceAllParams() throws {
        let client = try XCTUnwrap(try NFSClient(url: URL(string: "nfs://localhost")!))
        try client.configurePerformance(
            readMax: 1_048_576,
            autoReconnect: 3
        )
    }

    func testNFSClientConfigurePerformanceAllNils() throws {
        let client = try XCTUnwrap(try NFSClient(url: URL(string: "nfs://localhost")!))
        // All nil parameters - should be a no-op
        try client.configurePerformance()
    }
}

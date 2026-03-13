import XCTest
@testable import NFSKit

final class NFSKitTests: XCTestCase {

    func testExample() {
        // This is an example of a functional test case.
        // Use XCTAssert and related functions to verify your tests produce the correct
        // results.
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

    func testNFSClientConfigurePerformanceDoesNotCrash() throws {
        let client = try XCTUnwrap(try NFSClient(url: URL(string: "nfs://localhost")!))
        // configurePerformance is non-throwing and should not crash
        client.configurePerformance(readMax: 1024)
        client.configurePerformance(readAhead: 4096)
        client.configurePerformance(pageCachePages: 256, pageCacheTTL: 60)
        client.configurePerformance(autoReconnect: -1)
    }

    func testNFSClientConfigurePerformanceAllParams() throws {
        let client = try XCTUnwrap(try NFSClient(url: URL(string: "nfs://localhost")!))
        client.configurePerformance(
            readMax: 1_048_576,
            readAhead: 4096,
            pageCachePages: 256,
            pageCacheTTL: 60,
            autoReconnect: 3
        )
    }

    func testNFSClientConfigurePerformanceAllNils() throws {
        let client = try XCTUnwrap(try NFSClient(url: URL(string: "nfs://localhost")!))
        // All nil parameters - should be a no-op
        client.configurePerformance()
    }
}

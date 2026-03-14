import XCTest
@testable import NFSKit

/// Tests NFS connectivity: connecting, disconnecting, listing exports,
/// and post-connect diagnostics.
///
/// These tests manage their own client lifecycle (no auto-connect from base class).
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class ConnectionIntegrationTests: XCTestCase {

    private static let host: String = ProcessInfo.processInfo.environment["NFSKIT_TEST_HOST"] ?? ""
    private static let export: String = ProcessInfo.processInfo.environment["NFSKIT_TEST_EXPORT"] ?? "/share"

    private func skipIfUnavailable() throws {
        try XCTSkipUnless(!Self.host.isEmpty, "NFS test server not available (set NFSKIT_TEST_HOST)")
    }

    private func makeClient() throws -> NFSClient {
        try skipIfUnavailable()
        return try XCTUnwrap(try NFSClient(url: URL(string: "nfs://\(Self.host)")!))
    }

    // MARK: - Export Discovery

    func testListExports() async throws {
        let client = try makeClient()
        let exports = try await client.listExports()
        XCTAssertFalse(exports.isEmpty, "Server should have at least one export")
        XCTAssertTrue(exports.contains(Self.export), "Exports should contain \(Self.export)")
    }

    func testListExportsBeforeConnect() async throws {
        let client = try makeClient()
        // listExports should work without connecting first — it creates
        // its own RPC connection to the mount service.
        let exports = try await client.listExports()
        XCTAssertFalse(exports.isEmpty, "Server should have at least one export")
    }

    func testListExportsThenConnect() async throws {
        let client = try makeClient()
        // Verify that listing exports does not corrupt the NFS context,
        // so a subsequent mount still succeeds.
        let exports = try await client.listExports()
        XCTAssertFalse(exports.isEmpty)

        try await client.connect(export: Self.export)
        try await client.disconnect()
    }

    // MARK: - Connect / Disconnect

    func testConnectAndDisconnect() async throws {
        let client = try makeClient()
        try await client.connect(export: Self.export)
        try await client.disconnect()
    }

    func testConnectToInvalidExport() async throws {
        let client = try makeClient()

        do {
            try await client.connect(export: "/nonexistent-export-\(UUID())")
            XCTFail("Connecting to invalid export should throw")
        } catch {
            // Expected — libnfs rejects unknown exports
        }
    }

    func testMultipleConnectDisconnectCycles() async throws {
        // Each cycle needs a fresh client because disconnect destroys the context.
        for _ in 0..<3 {
            let client = try makeClient()
            try await client.connect(export: Self.export)
            try await client.disconnect()
        }
    }

    // MARK: - Post-Connect Diagnostics

    func testServerAddressPopulatedAfterConnect() async throws {
        let client = try makeClient()
        try await client.connect(export: Self.export)

        let address = try await client.serverAddress()
        XCTAssertNotNil(address, "Server address should be populated after connect")

        try await client.disconnect()
    }

    func testStatsShowActivityAfterConnect() async throws {
        let client = try makeClient()
        try await client.connect(export: Self.export)

        let stats = try await client.stats()
        XCTAssertGreaterThan(
            stats.requestsSent, 0,
            "Should have sent RPC requests during mount"
        )
        XCTAssertGreaterThan(
            stats.responsesReceived, 0,
            "Should have received RPC responses during mount"
        )

        try await client.disconnect()
    }
}

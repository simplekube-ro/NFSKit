import XCTest
@testable import NFSKit

/// Base class for NFSKit integration tests that require a running NFS server.
///
/// Provides a connected ``NFSClient`` and an isolated temporary directory for
/// each test. Tests are automatically skipped when `NFSKIT_TEST_HOST` is not set.
///
/// Run with: `./scripts/test-integration.sh`
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
class NFSIntegrationTestCase: XCTestCase {

    static let host: String = ProcessInfo.processInfo.environment["NFSKIT_TEST_HOST"] ?? ""
    static let export: String = ProcessInfo.processInfo.environment["NFSKIT_TEST_EXPORT"] ?? "/share"

    /// Whether a test NFS server is available.
    static var isServerAvailable: Bool { !host.isEmpty }

    /// Connected NFS client — available after setUp.
    var client: NFSClient!

    /// Isolated temporary directory for this test — created in setUp, removed in tearDown.
    var testDir: String!

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            Self.isServerAvailable,
            "NFS test server not available (set NFSKIT_TEST_HOST)"
        )

        guard let c = try NFSClient(url: URL(string: "nfs://\(Self.host)")!) else {
            XCTFail("Failed to create NFSClient — URL has no host")
            return
        }
        client = c
        try await client.connect(export: Self.export)

        testDir = "/test-\(UUID().uuidString.prefix(8))"
        try await client.createDirectory(atPath: testDir)
    }

    override func tearDown() async throws {
        if let dir = testDir, let c = client {
            try? await c.removeItem(atPath: dir)
            try? await c.disconnect()
        }
        client = nil
        testDir = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Create a file with known content in the test directory.
    @discardableResult
    func createTestFile(name: String, content: String) async throws -> String {
        let path = testDir + "/" + name
        try await client.write(data: Data(content.utf8), toPath: path)
        return path
    }

    /// Create a file with binary data in the test directory.
    @discardableResult
    func createTestFile(name: String, data: Data) async throws -> String {
        let path = testDir + "/" + name
        try await client.write(data: data, toPath: path)
        return path
    }
}

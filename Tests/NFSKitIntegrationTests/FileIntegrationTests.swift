import XCTest
import Foundation
@testable import NFSKit

/// Thread-safe flag for use in @Sendable progress callbacks.
private final class SendableFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false

    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _value }
        set { lock.lock(); defer { lock.unlock() }; _value = newValue }
    }
}

/// Tests NFS file operations: read, write, stat, move, truncate, and remove.
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class FileIntegrationTests: NFSIntegrationTestCase {

    // MARK: - Write & Read

    func testWriteAndReadSmallFile() async throws {
        let content = "Hello, NFS!"
        let path = try await createTestFile(name: "hello.txt", content: content)

        let data = try await client.contents(atPath: path)
        XCTAssertEqual(String(data: data, encoding: .utf8), content)
    }

    func testWriteAndReadEmptyFile() async throws {
        let path = testDir + "/empty.txt"
        try await client.write(data: Data(), toPath: path)

        let data = try await client.contents(atPath: path)
        XCTAssertTrue(data.isEmpty, "Empty file should return empty data")
    }

    func testWriteAndReadBinaryData() async throws {
        // Create binary data with all byte values
        var bytes = Data(count: 256)
        for i in 0..<256 {
            bytes[i] = UInt8(i)
        }
        let path = try await createTestFile(name: "binary.bin", data: bytes)

        let readBack = try await client.contents(atPath: path)
        XCTAssertEqual(readBack, bytes, "Binary data should round-trip exactly")
    }

    func testWriteOverwritesExistingFile() async throws {
        let path = try await createTestFile(name: "overwrite.txt", content: "original")

        try await client.write(data: Data("replaced".utf8), toPath: path)

        let data = try await client.contents(atPath: path)
        XCTAssertEqual(String(data: data, encoding: .utf8), "replaced")
    }

    func testLargerFileRoundTrip() async throws {
        // Create a ~1 MB file to exercise chunked read/write paths
        let chunkSize = 1024
        let chunks = 1024
        var payload = Data(capacity: chunkSize * chunks)
        for i in 0..<chunks {
            let line = String(format: "Line %04d: %@\n", i, String(repeating: "X", count: chunkSize - 16))
            payload.append(Data(line.utf8))
        }

        let path = try await createTestFile(name: "large.bin", data: payload)

        let readBack = try await client.contents(atPath: path)
        XCTAssertEqual(readBack.count, payload.count, "File size should match")
        XCTAssertEqual(readBack, payload, "File content should match exactly")
    }

    // MARK: - Progress Callback

    func testReadProgressCallback() async throws {
        let content = String(repeating: "A", count: 4096)
        let path = try await createTestFile(name: "progress.txt", content: content)

        let progressCalled = SendableFlag()
        let data = try await client.contents(atPath: path) { bytesRead, totalSize in
            progressCalled.value = true
            XCTAssertGreaterThan(totalSize, 0)
            XCTAssertGreaterThanOrEqual(bytesRead, 0)
            XCTAssertLessThanOrEqual(bytesRead, totalSize)
            return true
        }

        XCTAssertEqual(data.count, content.utf8.count)
        XCTAssertTrue(progressCalled.value, "Progress callback should be invoked")
    }

    func testWriteProgressCallback() async throws {
        let content = String(repeating: "B", count: 4096)
        let path = testDir + "/write-progress.txt"

        let progressCalled = SendableFlag()
        try await client.write(data: Data(content.utf8), toPath: path) { bytesWritten in
            progressCalled.value = true
            XCTAssertGreaterThan(bytesWritten, 0)
            return true
        }

        XCTAssertTrue(progressCalled.value, "Write progress callback should be invoked")
    }

    // MARK: - File Attributes

    func testFileAttributes() async throws {
        let content = "attribute check"
        let path = try await createTestFile(name: "attrs.txt", content: content)

        let attrs = try await client.attributesOfItem(atPath: path)

        XCTAssertEqual(attrs[.nameKey] as? String, "attrs.txt")
        XCTAssertEqual(attrs[.isRegularFileKey] as? Bool, true)
        XCTAssertEqual(attrs[.isDirectoryKey] as? Bool, false)
        XCTAssertEqual(attrs[.fileSizeKey] as? Int64, Int64(content.utf8.count))
        XCTAssertNotNil(attrs[.contentModificationDateKey], "Should have modification date")
    }

    func testDirectoryAttributes() async throws {
        let attrs = try await client.attributesOfItem(atPath: testDir)

        XCTAssertEqual(attrs[.isDirectoryKey] as? Bool, true)
        XCTAssertEqual(attrs[.isRegularFileKey] as? Bool, false)
    }

    // MARK: - Move / Rename

    func testMoveFile() async throws {
        let path = try await createTestFile(name: "moveme.txt", content: "moving")
        let newPath = testDir + "/moved.txt"

        try await client.moveItem(atPath: path, toPath: newPath)

        // Original should be gone
        do {
            _ = try await client.attributesOfItem(atPath: path)
            XCTFail("Original file should not exist after move")
        } catch {
            // Expected
        }

        // New location should have the content
        let data = try await client.contents(atPath: newPath)
        XCTAssertEqual(String(data: data, encoding: .utf8), "moving")
    }

    func testRenameDirectory() async throws {
        let oldPath = testDir + "/oldname"
        let newPath = testDir + "/newname"

        try await client.createDirectory(atPath: oldPath)
        try await client.write(data: Data("inside".utf8), toPath: oldPath + "/file.txt")

        try await client.moveItem(atPath: oldPath, toPath: newPath)

        let attrs = try await client.attributesOfItem(atPath: newPath)
        XCTAssertEqual(attrs[.isDirectoryKey] as? Bool, true)

        let data = try await client.contents(atPath: newPath + "/file.txt")
        XCTAssertEqual(String(data: data, encoding: .utf8), "inside")
    }

    // MARK: - Truncate

    func testTruncateFile() async throws {
        let path = try await createTestFile(name: "truncate.txt", content: "hello world")

        try await client.truncateFile(atPath: path, atOffset: 5)

        let data = try await client.contents(atPath: path)
        XCTAssertEqual(data.count, 5)
        XCTAssertEqual(String(data: data, encoding: .utf8), "hello")
    }

    func testTruncateToZero() async throws {
        let path = try await createTestFile(name: "trunczero.txt", content: "content")

        try await client.truncateFile(atPath: path, atOffset: 0)

        let data = try await client.contents(atPath: path)
        XCTAssertTrue(data.isEmpty, "Truncated-to-zero file should be empty")
    }

    // MARK: - Remove

    func testRemoveFile() async throws {
        let path = try await createTestFile(name: "removeme.txt", content: "bye")

        try await client.removeFile(atPath: path)

        do {
            _ = try await client.attributesOfItem(atPath: path)
            XCTFail("stat should fail after file removal")
        } catch {
            // Expected
        }
    }

    // MARK: - Error Cases

    func testReadNonExistentFile() async throws {
        do {
            _ = try await client.contents(atPath: testDir + "/does-not-exist.txt")
            XCTFail("Reading nonexistent file should throw")
        } catch {
            // Expected
        }
    }

    func testRemoveNonExistentFile() async throws {
        do {
            try await client.removeFile(atPath: testDir + "/ghost.txt")
            XCTFail("Removing nonexistent file should throw")
        } catch {
            // Expected
        }
    }
}

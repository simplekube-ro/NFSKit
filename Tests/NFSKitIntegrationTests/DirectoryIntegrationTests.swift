import XCTest
@testable import NFSKit

/// Tests NFS directory operations: create, list, remove, and nested structures.
@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class DirectoryIntegrationTests: NFSIntegrationTestCase {

    // MARK: - Create & Remove

    func testCreateAndRemoveDirectory() async throws {
        let dirPath = testDir + "/newdir"

        try await client.createDirectory(atPath: dirPath)

        let attrs = try await client.attributesOfItem(atPath: dirPath)
        XCTAssertEqual(attrs[.isDirectoryKey] as? Bool, true)

        try await client.removeDirectory(atPath: dirPath)

        do {
            _ = try await client.attributesOfItem(atPath: dirPath)
            XCTFail("stat should fail after removing directory")
        } catch {
            // Expected
        }
    }

    // MARK: - List Contents

    func testListDirectoryContents() async throws {
        try await createTestFile(name: "file1.txt", content: "hello")
        try await createTestFile(name: "file2.txt", content: "world")

        let contents = try await client.contentsOfDirectory(atPath: testDir)
        let names = contents.compactMap { $0[.nameKey] as? String }

        XCTAssertTrue(names.contains("file1.txt"), "Should list file1.txt")
        XCTAssertTrue(names.contains("file2.txt"), "Should list file2.txt")
    }

    func testListEmptyDirectory() async throws {
        let emptyDir = testDir + "/empty"
        try await client.createDirectory(atPath: emptyDir)

        let contents = try await client.contentsOfDirectory(atPath: emptyDir)
        // NFS readdir typically returns . and .. but NFSKit filters those
        // so an empty directory should return no entries (or only . and ..)
        let names = contents.compactMap { $0[.nameKey] as? String }
            .filter { $0 != "." && $0 != ".." }
        XCTAssertTrue(names.isEmpty, "Empty directory should have no user entries")
    }

    func testDirectoryContentsIncludeMetadata() async throws {
        try await createTestFile(name: "meta.txt", content: "metadata test")

        let contents = try await client.contentsOfDirectory(atPath: testDir)
        let entry = contents.first { ($0[.nameKey] as? String) == "meta.txt" }

        XCTAssertNotNil(entry, "Should find meta.txt in directory listing")
        XCTAssertEqual(entry?[.isRegularFileKey] as? Bool, true)
        XCTAssertEqual(entry?[.isDirectoryKey] as? Bool, false)

        if let size = entry?[.fileSizeKey] as? Int64 {
            XCTAssertEqual(size, Int64("metadata test".utf8.count))
        }
    }

    // MARK: - Nested Directories

    func testNestedDirectoryCreation() async throws {
        let parent = testDir + "/parent"
        let child = parent + "/child"
        let grandchild = child + "/grandchild"

        try await client.createDirectory(atPath: parent)
        try await client.createDirectory(atPath: child)
        try await client.createDirectory(atPath: grandchild)

        let attrs = try await client.attributesOfItem(atPath: grandchild)
        XCTAssertEqual(attrs[.isDirectoryKey] as? Bool, true)
    }

    func testListNestedDirectoryShowsSubdirectory() async throws {
        let subdir = testDir + "/subdir"
        try await client.createDirectory(atPath: subdir)
        try await createTestFile(name: "root-file.txt", content: "root")

        let contents = try await client.contentsOfDirectory(atPath: testDir)
        let names = contents.compactMap { $0[.nameKey] as? String }

        XCTAssertTrue(names.contains("subdir"), "Should list subdirectory")
        XCTAssertTrue(names.contains("root-file.txt"), "Should list file")

        // Verify the subdir entry is typed as directory
        let subdirEntry = contents.first { ($0[.nameKey] as? String) == "subdir" }
        XCTAssertEqual(subdirEntry?[.isDirectoryKey] as? Bool, true)
    }

    // MARK: - Error Cases

    func testRemoveNonEmptyDirectoryFails() async throws {
        let dir = testDir + "/nonempty"
        try await client.createDirectory(atPath: dir)
        try await client.write(data: Data("x".utf8), toPath: dir + "/file.txt")

        do {
            try await client.removeDirectory(atPath: dir)
            XCTFail("rmdir on non-empty directory should fail")
        } catch {
            // Expected — POSIX ENOTEMPTY
        }
    }

    func testRemoveItemRecursive() async throws {
        let dir = testDir + "/recursive"
        try await client.createDirectory(atPath: dir)
        try await client.createDirectory(atPath: dir + "/sub")
        try await client.write(data: Data("a".utf8), toPath: dir + "/file.txt")
        try await client.write(data: Data("b".utf8), toPath: dir + "/sub/nested.txt")

        try await client.removeItem(atPath: dir)

        do {
            _ = try await client.attributesOfItem(atPath: dir)
            XCTFail("stat should fail after recursive remove")
        } catch {
            // Expected
        }
    }
}

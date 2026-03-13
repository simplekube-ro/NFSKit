//
//  NFSFileHandleTests.swift
//  NFSKitTests
//
//  Tests for the token-based NFSFileHandle type.
//

import XCTest
@testable import NFSKit

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class NFSFileHandleTests: XCTestCase {

    // MARK: - Sendable conformance (compile-time check)

    func testFileHandleIsSendable() throws {
        let loop = try NFSEventLoop(timeout: 30)
        let handle = NFSFileHandle(handleID: 42, eventLoop: loop)
        let _: any Sendable = handle
        // If this compiles, Sendable conformance is verified
        XCTAssertNotNil(handle)
    }

    // MARK: - Handle ID storage

    func testFileHandleStoresHandleID() throws {
        let loop = try NFSEventLoop(timeout: 30)
        let handle = NFSFileHandle(handleID: 99, eventLoop: loop)
        XCTAssertEqual(handle.handleID, 99)
    }

    func testFileHandleStoresEventLoop() throws {
        let loop = try NFSEventLoop(timeout: 30)
        let handle = NFSFileHandle(handleID: 1, eventLoop: loop)
        XCTAssertTrue(handle.eventLoop === loop)
    }

    // MARK: - Multiple handles with different IDs

    func testMultipleHandlesHaveDistinctIDs() throws {
        let loop = try NFSEventLoop(timeout: 30)
        let h1 = NFSFileHandle(handleID: 1, eventLoop: loop)
        let h2 = NFSFileHandle(handleID: 2, eventLoop: loop)
        XCTAssertNotEqual(h1.handleID, h2.handleID)
    }

    // MARK: - Operations on invalid handle throw EBADF

    func testReadOnInvalidHandleThrowsEBADF() async throws {
        let loop = try NFSEventLoop(timeout: 30)
        let handle = NFSFileHandle(handleID: 9999, eventLoop: loop)

        do {
            _ = try await handle.read(count: 1024)
            XCTFail("Should have thrown EBADF")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .EBADF)
        }
    }

    func testWriteOnInvalidHandleThrowsEBADF() async throws {
        let loop = try NFSEventLoop(timeout: 30)
        let handle = NFSFileHandle(handleID: 9999, eventLoop: loop)

        do {
            _ = try await handle.write(data: Data([0x01, 0x02]))
            XCTFail("Should have thrown EBADF")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .EBADF)
        }
    }

    func testFstatOnInvalidHandleThrowsEBADF() async throws {
        let loop = try NFSEventLoop(timeout: 30)
        let handle = NFSFileHandle(handleID: 9999, eventLoop: loop)

        do {
            _ = try await handle.fstat()
            XCTFail("Should have thrown EBADF")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .EBADF)
        }
    }

    func testFsyncOnInvalidHandleThrowsEBADF() async throws {
        let loop = try NFSEventLoop(timeout: 30)
        let handle = NFSFileHandle(handleID: 9999, eventLoop: loop)

        do {
            try await handle.fsync()
            XCTFail("Should have thrown EBADF")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .EBADF)
        }
    }

    func testLseekOnInvalidHandleThrowsEBADF() async throws {
        let loop = try NFSEventLoop(timeout: 30)
        let handle = NFSFileHandle(handleID: 9999, eventLoop: loop)

        do {
            _ = try await handle.lseek(offset: 0, whence: SEEK_SET)
            XCTFail("Should have thrown EBADF")
        } catch let error as POSIXError {
            XCTAssertEqual(error.code, .EBADF)
        }
    }
}

import XCTest
@testable import NFSKit

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class ReadBufferTests: XCTestCase {

    func testAllocation() {
        let buffer = ReadBuffer(byteCount: 4096)
        XCTAssertNotNil(buffer.pointer)
        XCTAssertEqual(buffer.size, 4096)
    }

    func testIsOwnedDefaultsToTrue() {
        let buffer = ReadBuffer(byteCount: 64)
        XCTAssertTrue(buffer.isOwned)
    }

    func testDisownPreventsDeallocation() {
        let buffer = ReadBuffer(byteCount: 64)
        buffer.disown()
        XCTAssertFalse(buffer.isOwned)
        // Manually free the pointer since we transferred ownership
        buffer.pointer.deallocate()
    }

    func testSendableConformance() {
        let buffer = ReadBuffer(byteCount: 128)
        // Compile-time check: ReadBuffer must conform to Sendable
        let _: any Sendable = buffer
        XCTAssertNotNil(buffer)
    }
}

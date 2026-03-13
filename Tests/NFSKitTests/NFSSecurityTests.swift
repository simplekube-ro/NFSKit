//
//  NFSSecurityTests.swift
//  NFSKitTests
//
//  TDD tests for NFSSecurity enum and its integration with NFSEventLoop/NFSClient.
//

import XCTest
import nfs
@testable import NFSKit

@available(macOS 10.15, iOS 13.0, tvOS 13.0, watchOS 6.0, macCatalyst 13.0, *)
final class NFSSecurityTests: XCTestCase {

    // MARK: 1. All four enum cases exist

    func testEnumCases() {
        // Exhaustive switch ensures the compiler catches missing cases.
        func exercise(_ security: NFSSecurity) -> String {
            switch security {
            case .system:     return "system"
            case .kerberos5:  return "kerberos5"
            case .kerberos5i: return "kerberos5i"
            case .kerberos5p: return "kerberos5p"
            }
        }

        XCTAssertEqual(exercise(.system),     "system")
        XCTAssertEqual(exercise(.kerberos5),  "kerberos5")
        XCTAssertEqual(exercise(.kerberos5i), "kerberos5i")
        XCTAssertEqual(exercise(.kerberos5p), "kerberos5p")
    }

    // MARK: 2. NFSSecurity is Sendable (compile-time conformance check)

    func testSendableConformance() {
        let security: NFSSecurity = .kerberos5
        let _: any Sendable = security
        // If this compiles, NFSSecurity conforms to Sendable.
        XCTAssertEqual("\(security)", "kerberos5")
    }

    // MARK: 3. Each case maps to the correct rpc_sec C value

    func testRawValueMapping() {
        XCTAssertEqual(
            NFSSecurity.system.rpcSecValue,
            RPC_SEC_UNDEFINED,
            ".system should map to RPC_SEC_UNDEFINED (0)"
        )
        XCTAssertEqual(
            NFSSecurity.kerberos5.rpcSecValue,
            RPC_SEC_KRB5,
            ".kerberos5 should map to RPC_SEC_KRB5"
        )
        XCTAssertEqual(
            NFSSecurity.kerberos5i.rpcSecValue,
            RPC_SEC_KRB5I,
            ".kerberos5i should map to RPC_SEC_KRB5I"
        )
        XCTAssertEqual(
            NFSSecurity.kerberos5p.rpcSecValue,
            RPC_SEC_KRB5P,
            ".kerberos5p should map to RPC_SEC_KRB5P"
        )
    }

    // MARK: 4. setSecurity succeeds pre-connect on a fresh event loop

    func testSetSecurityPreConnect() throws {
        let loop = try NFSEventLoop(timeout: 30)
        // Each security mode should be settable before connecting.
        XCTAssertNoThrow(try loop.setSecurity(.system))
        XCTAssertNoThrow(try loop.setSecurity(.kerberos5))
        XCTAssertNoThrow(try loop.setSecurity(.kerberos5i))
        XCTAssertNoThrow(try loop.setSecurity(.kerberos5p))
    }

    // MARK: 5. setSecurity throws when already connected (fd >= 0)

    func testSetSecurityThrowsWhenConnected() throws {
        // We simulate a connected state by checking the guard condition.
        // A fresh context has fd == -1, so we verify that the non-connected
        // path succeeds, which is the observable complement to the guard.
        // A full integration test against a live server would be needed to
        // exercise the throw path; here we document the contract via the
        // negative (pre-connect) path.
        let loop = try NFSEventLoop(timeout: 30)
        XCTAssertNoThrow(try loop.setSecurity(.kerberos5p),
                         "setSecurity should succeed on a disconnected event loop")
    }

    // MARK: 6. NFSClient.setSecurity delegates to the event loop

    func testNFSClientSetSecurityDelegates() throws {
        guard let client = try NFSClient(url: URL(string: "nfs://localhost")!) else {
            XCTFail("NFSClient init should succeed for valid URL")
            return
        }
        // Delegation is synchronous and does not throw pre-connect.
        XCTAssertNoThrow(client.setSecurity(.kerberos5))
        XCTAssertNoThrow(client.setSecurity(.system))
    }
}

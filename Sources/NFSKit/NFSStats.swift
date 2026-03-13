//
//  NFSStats.swift
//  NFSKit
//
//  Point-in-time snapshot of RPC transport statistics. Value type, Sendable,
//  populated from libnfs `struct rpc_stats` via NFSEventLoop.stats().
//

import Foundation

/// Point-in-time snapshot of RPC transport statistics for an NFS connection.
///
/// Retrieve an instance via ``NFSClient/stats()`` or ``NFSEventLoop/stats()``.
/// All counters are cumulative since the last `nfs_context` was created.
///
/// - Note: Retransmitted requests are counted multiple times in ``requestsSent``.
public struct NFSStats: Sendable {

    /// Total RPC requests sent (includes retransmits).
    public let requestsSent: UInt64

    /// Total RPC responses received.
    public let responsesReceived: UInt64

    /// Requests that did not receive a response within the `timeo` window.
    public let timedOut: UInt64

    /// Requests that timed out while still in the send queue (never reached server).
    public let timedOutInOutqueue: UInt64

    /// Requests that still had no response after all `retrans` retries.
    public let majorTimedOut: UInt64

    /// Requests retransmitted due to timeout or reconnect.
    public let retransmitted: UInt64

    /// Number of reconnects triggered by a major timeout or a dropped connection.
    public let reconnects: UInt64

    /// Creates an `NFSStats` with explicit values. All parameters default to zero.
    public init(
        requestsSent: UInt64 = 0,
        responsesReceived: UInt64 = 0,
        timedOut: UInt64 = 0,
        timedOutInOutqueue: UInt64 = 0,
        majorTimedOut: UInt64 = 0,
        retransmitted: UInt64 = 0,
        reconnects: UInt64 = 0
    ) {
        self.requestsSent = requestsSent
        self.responsesReceived = responsesReceived
        self.timedOut = timedOut
        self.timedOutInOutqueue = timedOutInOutqueue
        self.majorTimedOut = majorTimedOut
        self.retransmitted = retransmitted
        self.reconnects = reconnects
    }
}

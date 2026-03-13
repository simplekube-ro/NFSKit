//
//  PipelineController.swift
//  NFSKit
//
//  Adaptive pipeline depth controller using TCP-style AIMD
//  (Additive Increase / Multiplicative Decrease).
//

/// Manages adaptive pipeline depth with TCP-style AIMD congestion control.
///
/// Two instances are used at runtime: one for bulk data operations and one
/// for metadata operations. Each adapts independently.
struct PipelineController: Sendable {

    /// The congestion-control phase.
    enum Phase: Sendable, Equatable {
        /// Exponential growth: depth doubles on each success.
        case slowStart
        /// Linear growth after threshold or failure.
        case steady
    }

    // MARK: - State

    /// Fractional pipeline depth for smooth AIMD arithmetic.
    private(set) var depth: Double

    /// Slow-start threshold. When `depth >= ssthresh` during slow start,
    /// the controller transitions to steady state.
    private(set) var ssthresh: Double

    /// Current congestion-control phase.
    private(set) var phase: Phase

    /// Minimum allowed effective depth.
    let minDepth: Int

    /// Maximum allowed effective depth.
    let maxDepth: Int

    // MARK: - Defaults

    private static let defaultDepth: Double = 2.0
    private static let defaultSsthresh: Double = 16.0
    private static let defaultPhase: Phase = .slowStart
    private static let defaultMinDepth: Int = 1
    private static let defaultMaxDepth: Int = 32

    // MARK: - Init

    init(
        depth: Double = defaultDepth,
        ssthresh: Double = defaultSsthresh,
        phase: Phase = defaultPhase,
        minDepth: Int = defaultMinDepth,
        maxDepth: Int = defaultMaxDepth
    ) {
        self.depth = depth
        self.ssthresh = ssthresh
        self.phase = phase
        self.minDepth = minDepth
        self.maxDepth = maxDepth
    }

    // MARK: - Computed

    /// The integer pipeline depth, clamped between `minDepth` and `maxDepth`.
    var effectiveDepth: Int {
        max(minDepth, min(Int(depth), maxDepth))
    }

    // MARK: - AIMD Methods

    /// Record a successful completion; grow the pipeline depth.
    mutating func recordSuccess() {
        switch phase {
        case .slowStart:
            depth *= 2
            if depth >= ssthresh {
                phase = .steady
            }
        case .steady:
            depth += 1.0 / depth
        }
        depth = min(depth, Double(maxDepth))
    }

    /// Record a failure (timeout or error); shrink the pipeline depth.
    mutating func recordFailure() {
        ssthresh = max(Double(minDepth), depth / 2.0)
        depth = max(Double(minDepth), depth / 2.0)
        phase = .steady // never re-enter slow start after failure
    }

    /// Reset to initial values (e.g. on reconnect).
    mutating func reset() {
        depth = Self.defaultDepth
        ssthresh = Self.defaultSsthresh
        phase = Self.defaultPhase
    }
}

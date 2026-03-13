//
//  PipelineControllerTests.swift
//  NFSKitTests
//
//  Tests for PipelineController (AIMD adaptive depth) and OperationType classification.
//

import XCTest
@testable import NFSKit

// MARK: - PipelineController Tests

final class PipelineControllerTests: XCTestCase {

    // MARK: 1. Initial values

    func testInitialValues() {
        let controller = PipelineController()
        XCTAssertEqual(controller.depth, 2.0, accuracy: .ulpOfOne)
        XCTAssertEqual(controller.ssthresh, 16.0, accuracy: .ulpOfOne)
        XCTAssertEqual(controller.effectiveDepth, 2)
        XCTAssertEqual(controller.phase, .slowStart)
    }

    // MARK: 2. Slow start doubles depth

    func testSlowStartDoublesDepth() {
        var controller = PipelineController()
        // depth: 2 -> 4 -> 8 -> 16
        controller.recordSuccess()
        XCTAssertEqual(controller.depth, 4.0, accuracy: .ulpOfOne)

        controller.recordSuccess()
        XCTAssertEqual(controller.depth, 8.0, accuracy: .ulpOfOne)

        controller.recordSuccess()
        XCTAssertEqual(controller.depth, 16.0, accuracy: .ulpOfOne)
    }

    // MARK: 3. Slow start transitions to steady at threshold

    func testSlowStartTransitionsToSteadyAtThreshold() {
        var controller = PipelineController()
        // depth starts at 2, ssthresh=16
        // 2 -> 4 -> 8 -> 16 (reaches ssthresh, should transition)
        controller.recordSuccess() // 4
        controller.recordSuccess() // 8
        XCTAssertEqual(controller.phase, .slowStart)

        controller.recordSuccess() // 16 >= ssthresh(16)
        XCTAssertEqual(controller.phase, .steady)
    }

    // MARK: 4. Steady state additive increase

    func testSteadyStateAdditiveIncrease() {
        var controller = PipelineController()
        // Drive into steady state first
        controller.recordSuccess() // 4
        controller.recordSuccess() // 8
        controller.recordSuccess() // 16, transitions to steady

        let depthBefore = controller.depth
        controller.recordSuccess()
        // In steady state: depth += 1/depth
        let expected = depthBefore + 1.0 / depthBefore
        XCTAssertEqual(controller.depth, expected, accuracy: 1e-10)
    }

    // MARK: 5. Multiplicative decrease on failure

    func testMultiplicativeDecreaseOnFailure() {
        var controller = PipelineController()
        // Drive to depth=8 in slow start
        controller.recordSuccess() // 4
        controller.recordSuccess() // 8

        let depthBefore = controller.depth // 8
        controller.recordFailure()

        let expectedDepth = max(1.0, depthBefore / 2.0) // 4
        let expectedSsthresh = max(1.0, depthBefore / 2.0) // 4
        XCTAssertEqual(controller.depth, expectedDepth, accuracy: .ulpOfOne)
        XCTAssertEqual(controller.ssthresh, expectedSsthresh, accuracy: .ulpOfOne)
    }

    // MARK: 6. Failure transitions to steady

    func testFailureTransitionsToSteady() {
        var controller = PipelineController()
        XCTAssertEqual(controller.phase, .slowStart)

        controller.recordFailure()
        XCTAssertEqual(controller.phase, .steady,
                       "Phase must be .steady after failure; never re-enter slow start")
    }

    // MARK: 7. Depth never below minimum

    func testDepthNeverBelowMinimum() {
        var controller = PipelineController()
        // Repeated failures should clamp at minDepth=1
        for _ in 0..<20 {
            controller.recordFailure()
        }
        XCTAssertGreaterThanOrEqual(controller.depth, Double(controller.minDepth))
        XCTAssertEqual(controller.effectiveDepth, controller.minDepth)
    }

    // MARK: 8. Depth never above maximum

    func testDepthNeverAboveMaximum() {
        var controller = PipelineController()
        // Repeated successes should clamp at maxDepth=32.
        // Slow start: 3 iterations to reach 16, then steady state
        // needs ~384 additive-increase steps to reach 32.
        for _ in 0..<500 {
            controller.recordSuccess()
        }
        XCTAssertLessThanOrEqual(controller.depth, Double(controller.maxDepth))
        XCTAssertEqual(controller.effectiveDepth, controller.maxDepth)
    }

    // MARK: 9. Reset restores initial values

    func testResetRestoresInitialValues() {
        var controller = PipelineController()
        // Modify state
        controller.recordSuccess()
        controller.recordSuccess()
        controller.recordSuccess()
        controller.recordFailure()

        // Reset
        controller.reset()

        XCTAssertEqual(controller.depth, 2.0, accuracy: .ulpOfOne)
        XCTAssertEqual(controller.ssthresh, 16.0, accuracy: .ulpOfOne)
        XCTAssertEqual(controller.phase, .slowStart)
        XCTAssertEqual(controller.effectiveDepth, 2)
    }

    // MARK: 10. effectiveDepth is Int of depth, clamped

    func testEffectiveDepthIsIntOfDepthClamped() {
        var controller = PipelineController()

        // At initial depth=2.0, effectiveDepth should be 2
        XCTAssertEqual(controller.effectiveDepth, 2)

        // After one slow-start success: depth=4.0
        controller.recordSuccess()
        XCTAssertEqual(controller.effectiveDepth, 4)

        // Drive to steady and get a fractional depth
        controller.recordSuccess() // 8
        controller.recordSuccess() // 16, -> steady
        controller.recordSuccess() // 16 + 1/16 = 16.0625
        // Int(16.0625) = 16
        XCTAssertEqual(controller.effectiveDepth, 16)

        // Verify clamping at min: repeated failures
        for _ in 0..<50 {
            controller.recordFailure()
        }
        XCTAssertEqual(controller.effectiveDepth, 1)

        // Verify clamping at max
        controller.reset()
        for _ in 0..<500 {
            controller.recordSuccess()
        }
        XCTAssertEqual(controller.effectiveDepth, 32)
    }
}

// MARK: - OperationType Classification Tests

final class OperationTypeTests: XCTestCase {

    // MARK: 11. Bulk operations

    func testBulkOperations() {
        let bulkOps: [OperationType] = [.read, .pread, .write, .pwrite]
        for op in bulkOps {
            XCTAssertEqual(op.category, .bulk,
                           "\(op) should be classified as .bulk")
        }
    }

    // MARK: 12. Metadata operations

    func testMetadataOperations() {
        let metadataOps: [OperationType] = [
            .stat, .statvfs, .readlink,
            .mkdir, .rmdir, .unlink, .rename, .truncate,
            .open, .close, .fsync,
            .opendir,
            .mount, .umount
        ]
        for op in metadataOps {
            XCTAssertEqual(op.category, .metadata,
                           "\(op) should be classified as .metadata")
        }
    }
}

// MARK: - Sendable Conformance Tests

final class SendableConformanceTests: XCTestCase {

    // MARK: 13. PipelineController is Sendable

    func testPipelineControllerIsSendable() {
        // Compile-time check: pass PipelineController to a Sendable closure
        let controller = PipelineController()
        let sendableCheck: @Sendable () -> Int = {
            return controller.effectiveDepth
        }
        XCTAssertEqual(sendableCheck(), 2)
    }

    // MARK: 14. OperationType is Sendable

    func testOperationTypeIsSendable() {
        // Compile-time check: pass OperationType to a Sendable closure
        let op = OperationType.read
        let sendableCheck: @Sendable () -> OperationCategory = {
            return op.category
        }
        XCTAssertEqual(sendableCheck(), .bulk)
    }
}

import XCTest
@testable import SplatCoachCapture

@MainActor
final class CoverageManagerTests: XCTestCase {
    func testWalkingEvidenceProducesAdequateStartWallCoverage() {
        let manager = CoverageManager()
        manager.startScan(initialAttitude: nil)

        manager.update(with: telemetry(
            yaw: 0, saved: 7, angles: 2, movement: .walking,
            linearImpulse: 1.1, rotationImpulse: 0.25, rotationDominance: 0.18
        ))

        let start = manager.summary.sectors.first { $0.sectorID == .startWall }
        XCTAssertEqual(start?.level, .adequate)
        XCTAssertEqual(start?.savedFrames, 7)
        XCTAssertEqual(start?.newAngleFrames, 2)
        XCTAssertEqual(start?.stableFrames, 7)
    }

    func testRotationOnlyEvidenceIsStronglyDiscounted() {
        let manager = CoverageManager()
        manager.startScan(initialAttitude: nil)

        manager.update(with: telemetry(
            yaw: 0, saved: 14, angles: 5, movement: .rotatingInPlace,
            linearImpulse: 0.1, rotationImpulse: 2.0, rotationDominance: 0.9
        ))

        let start = manager.summary.sectors.first { $0.sectorID == .startWall }
        XCTAssertEqual(start?.level, .sparse)
        XCTAssertEqual(start?.savedFrames, 3.5)
        XCTAssertEqual(start?.newAngleFrames, 1.25)
        XCTAssertEqual(manager.summary.recommendation.phase, .startup)
        XCTAssertEqual(manager.summary.recommendation.text, "Continue one steady perimeter pass.")
    }

    func testFourFractionalRotationContributionsAccumulateToOne() throws {
        let manager = CoverageManager()
        manager.startScan(initialAttitude: nil)

        for count in 1...4 {
            manager.update(with: telemetry(
                yaw: 0, saved: count, angles: 0, movement: .rotatingInPlace,
                linearImpulse: 0.1, rotationImpulse: 2.0, rotationDominance: 0.9
            ))
        }

        let start = try XCTUnwrap(manager.summary.sectors.first { $0.sectorID == .startWall })
        XCTAssertEqual(start.savedFrames, 1.0, accuracy: 0.000_001)
        XCTAssertGreaterThan(start.stableFrames, 0)
    }

    func testRotationDominantWalkingLabelDoesNotReceiveFullWeight() throws {
        let manager = CoverageManager()
        manager.startScan(initialAttitude: nil)
        manager.update(with: telemetry(
            yaw: 0, saved: 8, angles: 4, movement: .walking,
            linearImpulse: 0.5, rotationImpulse: 2.2, rotationDominance: 0.82
        ))

        let start = try XCTUnwrap(manager.summary.sectors.first { $0.sectorID == .startWall })
        XCTAssertEqual(start.savedFrames, 2.0, accuracy: 0.000_001)
        XCTAssertNotEqual(start.level, .strong)
    }

    func testStationaryHoldCannotMakeSectorStrong() throws {
        let manager = CoverageManager()
        manager.startScan(initialAttitude: nil)
        manager.update(with: telemetry(
            yaw: 0, saved: 40, angles: 30, movement: .stopped,
            linearImpulse: 0.05, rotationImpulse: 0.1, rotationDominance: 0.2
        ))

        let start = try XCTUnwrap(manager.summary.sectors.first { $0.sectorID == .startWall })
        XCTAssertEqual(start.savedFrames, 4.0, accuracy: 0.000_001)
        XCTAssertEqual(start.level, .sparse)
    }

    func testWeakPulseWalkingLabelIsTreatedAsStationaryHold() throws {
        let manager = CoverageManager()
        manager.startScan(initialAttitude: nil)
        manager.update(with: telemetry(
            yaw: 0, saved: 20, angles: 15, movement: .walking,
            linearImpulse: 0.4, rotationImpulse: 0.2, rotationDominance: 0.33
        ))

        let start = try XCTUnwrap(manager.summary.sectors.first { $0.sectorID == .startWall })
        XCTAssertEqual(start.savedFrames, 2.0, accuracy: 0.000_001)
        XCTAssertEqual(start.level, .sparse)
    }

    func testControlledRotationHoldsRetainDirectionalEvidence() {
        let manager = CoverageManager()
        manager.startScan(initialAttitude: nil)

        let rawYaw = [0.0, -.pi / 2, -.pi, -3 * .pi / 2]
        for (index, yaw) in rawYaw.enumerated() {
            manager.update(with: telemetry(
                yaw: yaw, saved: (index + 1) * 4, angles: (index + 1) * 2,
                movement: .rotatingInPlace, linearImpulse: 0.1,
                rotationImpulse: 2.0, rotationDominance: 0.9
            ))
        }

        XCTAssertTrue(manager.summary.sectors.allSatisfy { $0.savedFrames > 0 })
        XCTAssertTrue(manager.summary.sectors.allSatisfy { $0.level == .sparse })
    }

    private func telemetry(
        yaw: Double,
        saved: Int,
        angles: Int,
        movement: MovementClassification,
        linearImpulse: Double,
        rotationImpulse: Double,
        rotationDominance: Double
    ) -> CoverageTelemetry {
        CoverageTelemetry(
            timestamp: Date(),
            isScanning: true,
            yawRadians: yaw,
            savedFrameCount: saved,
            savedNewAngleCount: angles,
            currentScanHealth: .capturing,
            movementClassification: movement,
            recentLinearMotionImpulse: linearImpulse,
            recentRotationImpulse: rotationImpulse,
            rotationDominance: rotationDominance,
            viewChangeScore: 1.5
        )
    }
}

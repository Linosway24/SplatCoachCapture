import XCTest
@testable import SplatCoachCapture

@MainActor
final class CoverageManagerTests: XCTestCase {
    func testWalkingEvidenceProducesAdequateStartWallCoverage() {
        let manager = CoverageManager()
        manager.startScan(initialAttitude: nil)

        manager.update(with: telemetry(yaw: 0, saved: 7, angles: 2, movement: .walking))

        let start = manager.summary.sectors.first { $0.sectorID == .startWall }
        XCTAssertEqual(start?.level, .adequate)
        XCTAssertEqual(start?.savedFrames, 7)
        XCTAssertEqual(start?.newAngleFrames, 2)
        XCTAssertEqual(start?.stableFrames, 7)
    }

    func testRotationOnlyEvidenceIsStronglyDiscounted() {
        let manager = CoverageManager()
        manager.startScan(initialAttitude: nil)

        manager.update(with: telemetry(yaw: 0, saved: 14, angles: 5, movement: .rotatingInPlace))

        let start = manager.summary.sectors.first { $0.sectorID == .startWall }
        XCTAssertEqual(start?.level, .sparse)
        XCTAssertEqual(start?.savedFrames, 1)
        XCTAssertEqual(start?.newAngleFrames, 0)
        XCTAssertEqual(manager.summary.recommendation.priority, .important)
    }

    private func telemetry(
        yaw: Double,
        saved: Int,
        angles: Int,
        movement: MovementClassification
    ) -> CoverageTelemetry {
        CoverageTelemetry(
            timestamp: Date(),
            isScanning: true,
            yawRadians: yaw,
            savedFrameCount: saved,
            savedNewAngleCount: angles,
            currentScanHealth: .capturing,
            movementClassification: movement,
            viewChangeScore: 1.5
        )
    }
}

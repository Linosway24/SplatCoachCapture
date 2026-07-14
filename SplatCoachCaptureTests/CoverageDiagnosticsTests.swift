import XCTest
@testable import SplatCoachCapture

@MainActor
final class CoverageDiagnosticsTests: XCTestCase {
    func testPerFrameDiagnosticsExposeFourControlledDirections() throws {
        let manager = CoverageManager()
        manager.startScan(initialAttitude: nil)
        manager.update(with: telemetry(yaw: 0, saved: 0))

        let directions: [(Double, CoverageSectorID)] = [
            (0, .startWall),
            (-.pi / 2, .rightSide),
            (.pi, .oppositeWall),
            (.pi / 2, .leftSide),
            (-2 * .pi, .startWall)
        ]

        for (index, direction) in directions.enumerated() {
            manager.recordFrameDiagnostic(
                frameNumber: index + 1,
                timestamp: Date(timeIntervalSince1970: Double(index)),
                absoluteYawRadians: direction.0,
                outcome: "saved-saved-new-angle-rotation",
                exclusionReason: nil,
                viewChangeScore: 1.5,
                movementClassification: .walking,
                recentLinearMotionImpulse: 1.1,
                recentRotationImpulse: 0.2,
                rotationDominance: 0.15,
                scanHealth: .capturing
            )
        }

        let diagnostics = manager.diagnostics
        XCTAssertEqual(diagnostics.perFrame.map(\.assignedSector), directions.map { $0.1 })
        let finalYaw = try XCTUnwrap(diagnostics.perFrame.last?.normalizedYawDegrees)
        XCTAssertEqual(finalYaw, 0, accuracy: 0.000_001)
        XCTAssertEqual(diagnostics.perFrame.first?.evidenceWeight, 1.0)
        XCTAssertTrue(diagnostics.perFrame.allSatisfy(\.newAngleDecision))
        XCTAssertEqual(diagnostics.sectorBoundaries.count, 4)
        XCTAssertEqual(diagnostics.controlledTestProcedure.count, 5)
    }

    func testExcludedFrameKeepsReasonAndMovementWeight() {
        let manager = CoverageManager()
        manager.startScan(initialAttitude: nil)
        manager.update(with: telemetry(yaw: 0, saved: 0))

        manager.recordFrameDiagnostic(
            frameNumber: 12,
            timestamp: Date(),
            absoluteYawRadians: -.pi / 2,
            outcome: "rejected-too-blurry",
            exclusionReason: "Too blurry",
            viewChangeScore: nil,
            movementClassification: .rotatingInPlace,
            scanHealth: .hold
        )

        let frame = manager.diagnostics.perFrame.first
        XCTAssertEqual(frame?.assignedSector, .rightSide)
        XCTAssertEqual(frame?.exclusionReason, "Too blurry")
        XCTAssertEqual(frame?.evidenceWeight, 0.25)
        XCTAssertEqual(frame?.saved, false)
        XCTAssertEqual(frame?.excluded, true)
        XCTAssertEqual(frame?.newAngleDecision, false)
        XCTAssertEqual(frame?.overlapDecision, false)
    }

    func testCoverageDiagnosticsEncodeAuditableJSONAndCSVFields() throws {
        let manager = CoverageManager()
        manager.startScan(initialAttitude: nil)
        manager.update(with: CoverageTelemetry(
            timestamp: Date(),
            isScanning: true,
            yawRadians: 0,
            savedFrameCount: 1,
            savedNewAngleCount: 1,
            currentScanHealth: .capturing,
            movementClassification: .rotatingInPlace,
            recentLinearMotionImpulse: 0.1,
            recentRotationImpulse: 2.0,
            rotationDominance: 0.9,
            viewChangeScore: 1.5
        ))
        manager.recordFrameDiagnostic(
            frameNumber: 42,
            timestamp: Date(timeIntervalSince1970: 42),
            absoluteYawRadians: .pi,
            outcome: "saved-saved-overlap",
            exclusionReason: nil,
            viewChangeScore: 0.75,
            movementClassification: .walking,
            recentLinearMotionImpulse: 1.1,
            recentRotationImpulse: 0.2,
            rotationDominance: 0.15,
            scanHealth: .capturing
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(manager.diagnostics)
        let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))
        XCTAssertTrue(json.contains("\"normalizedYawDegrees\""))
        XCTAssertTrue(json.contains("\"sectorBoundaries\""))
        XCTAssertTrue(json.contains("\"controlledTestProcedure\""))
        XCTAssertTrue(json.contains("\"coachingThresholds\""))
        XCTAssertTrue(json.contains("\"coachingChanges\""))
        XCTAssertTrue(json.contains("\"phase\":\"startup\""))
        XCTAssertTrue(json.contains("\"recommendationKey\":\"startup.perimeter-pass\""))
        XCTAssertTrue(json.contains("\"perFrame\""))
        XCTAssertTrue(json.contains("\"savedFrames\":0.25"))

        let csvData = try XCTUnwrap(
            CoverageFrameDiagnosticsCSVEncoder.encode(manager.diagnostics.perFrame)
        )
        let csv = try XCTUnwrap(String(data: csvData, encoding: .utf8))
        XCTAssertTrue(csv.hasPrefix(CoverageFrameDiagnosticsCSVEncoder.columns.joined(separator: ",")))
        XCTAssertTrue(csv.contains("oppositeWall"))
        XCTAssertTrue(csv.contains(",true,false,,1.000000,0.750000,false,true,walking,capturing"))
    }

    func testCoachingDiagnosticsRecordTargetSeverityAndChangeReason() {
        let manager = CoverageManager()
        let start = Date(timeIntervalSince1970: 100)
        manager.startScan(initialAttitude: nil)

        let samples: [(TimeInterval, Double, Int, Int)] = [
            (0, 0, 4, 1),
            (4, -.pi / 2, 8, 2),
            (9, .pi, 12, 3)
        ]
        for sample in samples {
            manager.update(with: CoverageTelemetry(
                timestamp: start.addingTimeInterval(sample.0),
                isScanning: true,
                yawRadians: sample.1,
                savedFrameCount: sample.2,
                savedNewAngleCount: sample.3,
                currentScanHealth: .capturing,
                movementClassification: .walking,
                recentLinearMotionImpulse: 1.1,
                recentRotationImpulse: 0.2,
                rotationDominance: 0.15,
                viewChangeScore: 1.5
            ))
        }

        let diagnostics = manager.diagnostics
        XCTAssertEqual(diagnostics.summary.recommendation.phase, .correcting)
        XCTAssertEqual(diagnostics.summary.recommendation.targetSector, .leftSide)
        XCTAssertEqual(diagnostics.summary.recommendation.deficitSeverity, .large)
        XCTAssertEqual(diagnostics.summary.recommendation.changeReason, "startup-evidence-ready")
        XCTAssertEqual(diagnostics.summary.recommendation.changedAt, start.addingTimeInterval(9))
        XCTAssertEqual(diagnostics.coachingChanges.map(\.phase), [.startup, .correcting])
        XCTAssertEqual(diagnostics.coachingChanges.last?.recommendationKey, "correcting.leftSide.large")
    }

    private func telemetry(yaw: Double, saved: Int) -> CoverageTelemetry {
        CoverageTelemetry(
            timestamp: Date(),
            isScanning: true,
            yawRadians: yaw,
            savedFrameCount: saved,
            savedNewAngleCount: 0,
            currentScanHealth: .capturing,
            movementClassification: .walking,
            recentLinearMotionImpulse: 1.1,
            recentRotationImpulse: 0.2,
            rotationDominance: 0.15,
            viewChangeScore: 0
        )
    }
}

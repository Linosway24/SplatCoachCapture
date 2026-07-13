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
            (.pi / 2, .rightSide),
            (.pi, .oppositeWall),
            (3 * .pi / 2, .leftSide),
            (2 * .pi, .startWall)
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
            absoluteYawRadians: .pi / 2,
            outcome: "rejected-too-blurry",
            exclusionReason: "Too blurry",
            viewChangeScore: nil,
            movementClassification: .rotatingInPlace,
            scanHealth: .hold
        )

        let frame = manager.diagnostics.perFrame.first
        XCTAssertEqual(frame?.assignedSector, .rightSide)
        XCTAssertEqual(frame?.exclusionReason, "Too blurry")
        XCTAssertEqual(frame?.evidenceWeight, 0.08)
        XCTAssertEqual(frame?.saved, false)
        XCTAssertEqual(frame?.excluded, true)
        XCTAssertEqual(frame?.newAngleDecision, false)
        XCTAssertEqual(frame?.overlapDecision, false)
    }

    func testCoverageDiagnosticsEncodeAuditableJSONAndCSVFields() throws {
        let manager = CoverageManager()
        manager.startScan(initialAttitude: nil)
        manager.update(with: telemetry(yaw: 0, saved: 0))
        manager.recordFrameDiagnostic(
            frameNumber: 42,
            timestamp: Date(timeIntervalSince1970: 42),
            absoluteYawRadians: .pi,
            outcome: "saved-saved-overlap",
            exclusionReason: nil,
            viewChangeScore: 0.75,
            movementClassification: .walking,
            scanHealth: .capturing
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let jsonData = try encoder.encode(manager.diagnostics)
        let json = try XCTUnwrap(String(data: jsonData, encoding: .utf8))
        XCTAssertTrue(json.contains("\"normalizedYawDegrees\""))
        XCTAssertTrue(json.contains("\"sectorBoundaries\""))
        XCTAssertTrue(json.contains("\"controlledTestProcedure\""))
        XCTAssertTrue(json.contains("\"perFrame\""))

        let csvData = try XCTUnwrap(
            CoverageFrameDiagnosticsCSVEncoder.encode(manager.diagnostics.perFrame)
        )
        let csv = try XCTUnwrap(String(data: csvData, encoding: .utf8))
        XCTAssertTrue(csv.hasPrefix(CoverageFrameDiagnosticsCSVEncoder.columns.joined(separator: ",")))
        XCTAssertTrue(csv.contains("oppositeWall"))
        XCTAssertTrue(csv.contains(",true,false,,1.000000,0.750000,false,true,walking,capturing"))
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
            viewChangeScore: 0
        )
    }
}

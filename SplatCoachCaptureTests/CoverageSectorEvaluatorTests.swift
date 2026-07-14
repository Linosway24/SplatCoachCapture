import XCTest
@testable import SplatCoachCapture

final class CoverageSectorEvaluatorTests: XCTestCase {
    private let evaluator = CoverageSectorEvaluator()

    func testCardinalDirectionsMapToFourExpectedSectors() {
        XCTAssertEqual(evaluator.sector(for: radians(0)), .startWall)
        // Raw Core Motion yaw decreases for a physical right turn.
        XCTAssertEqual(evaluator.sector(for: radians(-90)), .rightSide)
        XCTAssertEqual(evaluator.sector(for: radians(180)), .oppositeWall)
        XCTAssertEqual(evaluator.sector(for: radians(90)), .leftSide)
    }

    func testBoundariesAreHalfOpenAndDeterministic() {
        XCTAssertEqual(evaluator.sector(for: radians(-44.999)), .startWall)
        XCTAssertEqual(evaluator.sector(for: radians(-45)), .rightSide)
        XCTAssertEqual(evaluator.sector(for: radians(-134.999)), .rightSide)
        XCTAssertEqual(evaluator.sector(for: radians(-135)), .oppositeWall)
        XCTAssertEqual(evaluator.sector(for: radians(135.001)), .oppositeWall)
        XCTAssertEqual(evaluator.sector(for: radians(135)), .leftSide)
        XCTAssertEqual(evaluator.sector(for: radians(45.001)), .leftSide)
        XCTAssertEqual(evaluator.sector(for: radians(45)), .startWall)
    }

    func testYawWrapsAcrossPositiveAndNegativeFullRotations() {
        XCTAssertEqual(evaluator.sector(for: radians(360)), .startWall)
        XCTAssertEqual(evaluator.sector(for: radians(-360)), .startWall)
        XCTAssertEqual(evaluator.sector(for: radians(180)), .oppositeWall)
        XCTAssertEqual(evaluator.sector(for: radians(-180)), .oppositeWall)
        XCTAssertEqual(evaluator.sector(for: radians(450)), .leftSide)
        XCTAssertEqual(evaluator.sector(for: radians(-450)), .rightSide)
    }

    func testControlledRightTurnSequenceReturnsToStart() {
        let rawCoreMotionYawDegrees = [0.0, -90, -180, -270, -360]
        XCTAssertEqual(
            rawCoreMotionYawDegrees.map { evaluator.sector(for: radians($0)) },
            [.startWall, .rightSide, .oppositeWall, .leftSide, .startWall]
        )
    }

    private func radians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }
}

import XCTest
@testable import SplatCoachCapture

final class CoverageSectorEvaluatorTests: XCTestCase {
    private let evaluator = CoverageSectorEvaluator()

    func testCardinalDirectionsMapToFourExpectedSectors() {
        XCTAssertEqual(evaluator.sector(for: radians(0)), .startWall)
        XCTAssertEqual(evaluator.sector(for: radians(90)), .rightSide)
        XCTAssertEqual(evaluator.sector(for: radians(180)), .oppositeWall)
        XCTAssertEqual(evaluator.sector(for: radians(270)), .leftSide)
    }

    func testBoundariesAreHalfOpenAndDeterministic() {
        XCTAssertEqual(evaluator.sector(for: radians(44.999)), .startWall)
        XCTAssertEqual(evaluator.sector(for: radians(45)), .rightSide)
        XCTAssertEqual(evaluator.sector(for: radians(134.999)), .rightSide)
        XCTAssertEqual(evaluator.sector(for: radians(135)), .oppositeWall)
        XCTAssertEqual(evaluator.sector(for: radians(224.999)), .oppositeWall)
        XCTAssertEqual(evaluator.sector(for: radians(225)), .leftSide)
        XCTAssertEqual(evaluator.sector(for: radians(314.999)), .leftSide)
        XCTAssertEqual(evaluator.sector(for: radians(315)), .startWall)
    }

    func testYawWrapsAcrossPositiveAndNegativeFullRotations() {
        XCTAssertEqual(evaluator.sector(for: radians(360)), .startWall)
        XCTAssertEqual(evaluator.sector(for: radians(-90)), .leftSide)
        XCTAssertEqual(evaluator.sector(for: radians(450)), .rightSide)
        XCTAssertEqual(evaluator.sector(for: radians(-270)), .rightSide)
    }

    private func radians(_ degrees: Double) -> Double {
        degrees * .pi / 180
    }
}

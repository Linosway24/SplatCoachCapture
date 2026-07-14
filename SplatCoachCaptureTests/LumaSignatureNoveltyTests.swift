import XCTest
@testable import SplatCoachCapture

final class LumaSignatureNoveltyTests: XCTestCase {
    func testGlobalBrightnessChangeDoesNotCountAsStructuralViewChange() {
        let original = [10.0, 20.0, 30.0, 40.0]
        let brighter = original.map { $0 + 25 }

        XCTAssertEqual(
            LumaSignatureNovelty.viewChangeScore(previous: original, current: brighter),
            0,
            accuracy: 0.000_001
        )
    }

    func testMinorStationaryLumaNoiseStaysBelowNoveltyThreshold() {
        let original = [10.0, 20.0, 30.0, 40.0]
        let noisy = [10.5, 19.5, 30.4, 39.6]
        let score = LumaSignatureNovelty.viewChangeScore(previous: original, current: noisy)

        XCTAssertLessThan(score, CaptureTuning.minimumOverlapViewChangeScore)
        var evaluator = FrameNoveltyEvaluator()
        let result = evaluator.evaluate(
            isFirstSave: false,
            timestamp: Date(),
            rotationDelta: 0,
            viewChangeScore: score
        )
        XCTAssertEqual(result.decision, .overlap)
    }

    func testMeaningfulSpatialChangeRemainsNovelAfterExposureNormalization() {
        let original = [10.0, 20.0, 30.0, 40.0]
        let changed = [40.0, 30.0, 20.0, 10.0]
        let score = LumaSignatureNovelty.viewChangeScore(previous: original, current: changed)

        XCTAssertGreaterThanOrEqual(score, CaptureTuning.minimumOverlapViewChangeScore)
        var evaluator = FrameNoveltyEvaluator()
        let result = evaluator.evaluate(
            isFirstSave: false,
            timestamp: Date(),
            rotationDelta: 0,
            viewChangeScore: score
        )
        XCTAssertEqual(result.decision, .newAngleViewChange)
    }

    func testRealRotationStillTakesPrecedence() {
        var evaluator = FrameNoveltyEvaluator()
        let result = evaluator.evaluate(
            isFirstSave: false,
            timestamp: Date(),
            rotationDelta: CaptureTuning.minimumRotationChangeRadians,
            viewChangeScore: 0
        )
        XCTAssertEqual(result.decision, .newAngleRotation)
    }

    func testSidewaysStructuralMovementRemainsDetectable() {
        let original = [8.0, 12.0, 18.0, 30.0, 42.0, 55.0]
        let shifted = [18.0, 30.0, 42.0, 55.0, 8.0, 12.0]
        let score = LumaSignatureNovelty.viewChangeScore(previous: original, current: shifted)
        var evaluator = FrameNoveltyEvaluator()
        let result = evaluator.evaluate(
            isFirstSave: false,
            timestamp: Date(),
            rotationDelta: 0,
            viewChangeScore: score
        )

        XCTAssertGreaterThan(score, CaptureTuning.minimumOverlapViewChangeScore)
        XCTAssertEqual(result.decision, .newAngleViewChange)
    }
}

final class CoverageEvidenceFormattingTests: XCTestCase {
    func testEvidenceAlwaysDisplaysOneDecimalPlace() {
        XCTAssertEqual(formattedCoverageEvidence(5.6000000000000005), "5.6")
        XCTAssertEqual(formattedCoverageEvidence(5.6999999999999997), "5.7")
        XCTAssertEqual(formattedCoverageEvidence(4.0), "4.0")
    }
}

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
        XCTAssertEqual(
            FrameNoveltyDecision.evaluate(
                isFirstSave: false,
                rotationDelta: 0,
                viewChangeScore: score
            ),
            .overlap
        )
    }

    func testMeaningfulSpatialChangeRemainsNovelAfterExposureNormalization() {
        let original = [10.0, 20.0, 30.0, 40.0]
        let changed = [40.0, 30.0, 20.0, 10.0]
        let score = LumaSignatureNovelty.viewChangeScore(previous: original, current: changed)

        XCTAssertGreaterThanOrEqual(score, CaptureTuning.minimumOverlapViewChangeScore)
        XCTAssertEqual(
            FrameNoveltyDecision.evaluate(
                isFirstSave: false,
                rotationDelta: 0,
                viewChangeScore: score
            ),
            .newAngleViewChange
        )
    }

    func testRealRotationStillTakesPrecedence() {
        XCTAssertEqual(
            FrameNoveltyDecision.evaluate(
                isFirstSave: false,
                rotationDelta: CaptureTuning.minimumRotationChangeRadians,
                viewChangeScore: 0
            ),
            .newAngleRotation
        )
    }
}

final class CoverageEvidenceFormattingTests: XCTestCase {
    func testEvidenceAlwaysDisplaysOneDecimalPlace() {
        XCTAssertEqual(formattedCoverageEvidence(5.6000000000000005), "5.6")
        XCTAssertEqual(formattedCoverageEvidence(5.6999999999999997), "5.7")
        XCTAssertEqual(formattedCoverageEvidence(4.0), "4.0")
    }
}

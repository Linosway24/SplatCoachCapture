import XCTest
@testable import SplatCoachCapture

final class FrameNoveltyDecisionTests: XCTestCase {
    func testFirstFrameIsOverlapRegardlessOfNoveltySignals() {
        XCTAssertEqual(
            FrameNoveltyDecision.evaluate(isFirstSave: true, rotationDelta: 1, viewChangeScore: 10),
            .overlap
        )
    }

    func testRotationAtCurrentThresholdIsNewAngle() {
        XCTAssertEqual(
            FrameNoveltyDecision.evaluate(
                isFirstSave: false,
                rotationDelta: CaptureTuning.minimumRotationChangeRadians,
                viewChangeScore: 0
            ),
            .newAngleRotation
        )
    }

    func testViewChangeAtCurrentThresholdIsNewAngle() {
        XCTAssertEqual(
            FrameNoveltyDecision.evaluate(
                isFirstSave: false,
                rotationDelta: 0,
                viewChangeScore: CaptureTuning.minimumOverlapViewChangeScore
            ),
            .newAngleViewChange
        )
    }

    func testSubthresholdSignalsRemainOverlap() {
        XCTAssertEqual(
            FrameNoveltyDecision.evaluate(
                isFirstSave: false,
                rotationDelta: CaptureTuning.minimumRotationChangeRadians.nextDown,
                viewChangeScore: CaptureTuning.minimumOverlapViewChangeScore.nextDown
            ),
            .overlap
        )
    }

    func testRotationTakesDiagnosticPrecedenceWhenBothSignalsPass() {
        XCTAssertEqual(
            FrameNoveltyDecision.evaluate(isFirstSave: false, rotationDelta: 1, viewChangeScore: 10),
            .newAngleRotation
        )
    }
}

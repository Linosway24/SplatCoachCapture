import XCTest
@testable import SplatCoachCapture

final class FrameNoveltyDecisionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)

    func testFirstFrameIsOverlapRegardlessOfNoveltySignals() {
        var evaluator = FrameNoveltyEvaluator()
        let result = evaluator.evaluate(
            isFirstSave: true,
            timestamp: start,
            rotationDelta: 1,
            viewChangeScore: 10
        )

        XCTAssertEqual(result.decision, .overlap)
    }

    func testRotationAtCurrentThresholdIsNewAngle() {
        var evaluator = FrameNoveltyEvaluator()
        let result = evaluator.evaluate(
            isFirstSave: false,
            timestamp: start,
            rotationDelta: CaptureTuning.minimumRotationChangeRadians,
            viewChangeScore: 0
        )

        XCTAssertEqual(result.decision, .newAngleRotation)
    }

    func testMinorStationaryFluctuationsDoNotTriggerNovelty() {
        var evaluator = FrameNoveltyEvaluator()
        let scores = [0.4, 0.9, 1.4, 2.2, CaptureTuning.minimumOverlapViewChangeScore.nextDown]

        for (index, score) in scores.enumerated() {
            let result = evaluator.evaluate(
                isFirstSave: false,
                timestamp: start.addingTimeInterval(Double(index) * 0.4),
                rotationDelta: 0,
                viewChangeScore: score
            )
            XCTAssertEqual(result.decision, .overlap)
        }
    }

    func testMeaningfulLumaChangeTriggersOnceThenCooldownSuppressesSimilarFrame() throws {
        var evaluator = FrameNoveltyEvaluator()
        let first = evaluator.evaluate(
            isFirstSave: false,
            timestamp: start,
            rotationDelta: 0,
            viewChangeScore: 6
        )
        let continued = evaluator.evaluate(
            isFirstSave: false,
            timestamp: start.addingTimeInterval(0.4),
            rotationDelta: 0,
            viewChangeScore: 5
        )

        XCTAssertEqual(first.decision, .newAngleViewChange)
        XCTAssertEqual(continued.decision, .lumaSuppressedCooldown)
        XCTAssertEqual(continued.suppressionReason, "cooldown")
        let elapsed = try XCTUnwrap(continued.elapsedSincePriorLumaNovelty)
        XCTAssertEqual(elapsed, 0.4, accuracy: 0.000_001)
    }

    func testContinuedHighScoreAfterCooldownIsSuppressedUntilRearmed() {
        var evaluator = FrameNoveltyEvaluator()
        _ = evaluator.evaluate(
            isFirstSave: false,
            timestamp: start,
            rotationDelta: 0,
            viewChangeScore: 6
        )
        let result = evaluator.evaluate(
            isFirstSave: false,
            timestamp: start.addingTimeInterval(1.3),
            rotationDelta: 0,
            viewChangeScore: 5
        )

        XCTAssertEqual(result.decision, .lumaSuppressedNotRearmed)
        XCTAssertEqual(result.suppressionReason, "not-rearmed")
        XCTAssertFalse(result.lumaArmedBeforeDecision)
    }

    func testLowScoreRearmsAndLaterMeaningfulChangeTriggersAfterCooldown() {
        var evaluator = FrameNoveltyEvaluator()
        _ = evaluator.evaluate(
            isFirstSave: false,
            timestamp: start,
            rotationDelta: 0,
            viewChangeScore: 6
        )
        let reset = evaluator.evaluate(
            isFirstSave: false,
            timestamp: start.addingTimeInterval(0.8),
            rotationDelta: 0,
            viewChangeScore: CaptureTuning.lumaNoveltyResetScore
        )
        let tooSoon = evaluator.evaluate(
            isFirstSave: false,
            timestamp: start.addingTimeInterval(1.0),
            rotationDelta: 0,
            viewChangeScore: 6
        )
        let later = evaluator.evaluate(
            isFirstSave: false,
            timestamp: start.addingTimeInterval(1.3),
            rotationDelta: 0,
            viewChangeScore: 6
        )

        XCTAssertEqual(reset.lumaThresholdState, .belowReset)
        XCTAssertTrue(reset.lumaArmedAfterDecision)
        XCTAssertEqual(tooSoon.decision, .lumaSuppressedCooldown)
        XCTAssertEqual(later.decision, .newAngleViewChange)
    }

    func testRotationTriggersImmediatelyDuringLumaCooldown() {
        var evaluator = FrameNoveltyEvaluator()
        _ = evaluator.evaluate(
            isFirstSave: false,
            timestamp: start,
            rotationDelta: 0,
            viewChangeScore: 6
        )
        let rotation = evaluator.evaluate(
            isFirstSave: false,
            timestamp: start.addingTimeInterval(0.4),
            rotationDelta: CaptureTuning.minimumRotationChangeRadians,
            viewChangeScore: 6
        )

        XCTAssertEqual(rotation.decision, .newAngleRotation)
        XCTAssertEqual(evaluator.lastLumaNoveltyAt, start)
    }

    func testResetRestoresInitialState() {
        var evaluator = FrameNoveltyEvaluator()
        _ = evaluator.evaluate(
            isFirstSave: false,
            timestamp: start,
            rotationDelta: 0,
            viewChangeScore: 6
        )
        evaluator.reset()

        XCTAssertTrue(evaluator.isLumaArmed)
        XCTAssertNil(evaluator.lastLumaNoveltyAt)
    }
}

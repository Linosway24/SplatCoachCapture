import XCTest
@testable import SplatCoachCapture

final class FrameNoveltyDiagnosticsTests: XCTestCase {
    func testSuppressedLumaDiagnosticEncodesThresholdAndCooldownState() throws {
        let start = Date(timeIntervalSince1970: 100)
        var evaluator = FrameNoveltyEvaluator()
        _ = evaluator.evaluate(
            isFirstSave: false,
            timestamp: start,
            rotationDelta: 0,
            viewChangeScore: 6
        )
        let suppressed = evaluator.evaluate(
            isFirstSave: false,
            timestamp: start.addingTimeInterval(0.4),
            rotationDelta: 0,
            viewChangeScore: 5
        )

        let data = try JSONEncoder().encode(suppressed)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(object["decision"] as? String, "lumaSuppressedCooldown")
        XCTAssertEqual(object["suppressionReason"] as? String, "cooldown")
        let elapsed = try XCTUnwrap(object["elapsedSincePriorLumaNovelty"] as? Double)
        XCTAssertEqual(elapsed, 0.4, accuracy: 0.000_001)
        XCTAssertEqual(object["lumaScore"] as? Double, 5)
        XCTAssertEqual(object["lumaEnterThreshold"] as? Double, 3)
        XCTAssertEqual(object["lumaResetThreshold"] as? Double, 1.5)
        XCTAssertEqual(object["lumaCooldownDuration"] as? Double, 1.2)
        XCTAssertEqual(object["lumaThresholdState"] as? String, "atOrAboveEnter")
        XCTAssertEqual(object["lumaArmedBeforeDecision"] as? Bool, false)
        XCTAssertEqual(object["lumaArmedAfterDecision"] as? Bool, false)
    }
}

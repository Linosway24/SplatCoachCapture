import XCTest
@testable import SplatCoachCapture

@MainActor
final class CaptureIdleTimerCoordinatorTests: XCTestCase {
    func testIdleTimerRequiresVisibleActiveScanningState() {
        var changes: [Bool] = []
        let coordinator = CaptureIdleTimerCoordinator { changes.append($0) }

        coordinator.setCaptureViewVisible(true)
        coordinator.setSceneActive(true)
        XCTAssertTrue(changes.isEmpty)

        coordinator.setScanning(true)
        XCTAssertEqual(changes, [true])

        coordinator.setSceneActive(false)
        XCTAssertEqual(changes, [true, false])

        coordinator.setSceneActive(true)
        coordinator.setScanning(false)
        XCTAssertEqual(changes, [true, false, true, false])
    }

    func testDisappearingCaptureViewRestoresAutoLock() {
        var changes: [Bool] = []
        let coordinator = CaptureIdleTimerCoordinator { changes.append($0) }
        coordinator.setCaptureViewVisible(true)
        coordinator.setSceneActive(true)
        coordinator.setScanning(true)

        coordinator.setCaptureViewVisible(false)

        XCTAssertEqual(changes, [true, false])
        XCTAssertFalse(coordinator.isIdleTimerDisabled)
    }
}

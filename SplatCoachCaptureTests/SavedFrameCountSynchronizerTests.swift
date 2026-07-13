import XCTest
@testable import SplatCoachCapture

final class SavedFrameCountSynchronizerTests: XCTestCase {
    func testCountAlwaysMatchesAuthoritativeSavedImageList() {
        let urls = [
            URL(fileURLWithPath: "/tmp/frame-1.jpg"),
            URL(fileURLWithPath: "/tmp/frame-2.jpg"),
            URL(fileURLWithPath: "/tmp/frame-3.jpg")
        ]

        XCTAssertEqual(SavedFrameCountSynchronizer.count(for: urls), 3)
        XCTAssertEqual(SavedFrameCountSynchronizer.count(for: []), 0)
    }
}

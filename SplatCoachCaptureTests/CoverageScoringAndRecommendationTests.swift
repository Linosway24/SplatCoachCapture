import XCTest
@testable import SplatCoachCapture

final class CoverageScoringAndRecommendationTests: XCTestCase {
    private let scoring = CoverageScoringEngine()
    private let recommendations = CoverageRecommendationEngine()

    func testEvidenceThresholdsRequireAllInputsAtEachLevel() {
        XCTAssertEqual(scoring.level(savedFrames: 0, newAngleFrames: 0, stableFrames: 0, viewChangeTotal: 0), .none)
        XCTAssertEqual(scoring.level(savedFrames: 1, newAngleFrames: 0, stableFrames: 1, viewChangeTotal: 0), .sparse)
        XCTAssertEqual(scoring.level(savedFrames: 7, newAngleFrames: 2, stableFrames: 4, viewChangeTotal: 0), .adequate)
        XCTAssertEqual(scoring.level(savedFrames: 14, newAngleFrames: 5, stableFrames: 8, viewChangeTotal: 0), .strong)
        XCTAssertEqual(scoring.level(savedFrames: 14, newAngleFrames: 4, stableFrames: 8, viewChangeTotal: 0), .adequate)
    }

    func testRecommendationReturnsUserToWeakestSector() {
        let sectors = [
            evidence(.startWall, level: .adequate, saved: 8, angles: 3),
            evidence(.rightSide, level: .sparse, saved: 3, angles: 1),
            evidence(.oppositeWall, level: .none, saved: 0, angles: 0),
            evidence(.leftSide, level: .adequate, saved: 8, angles: 3)
        ]

        let result = recommendations.recommendation(for: sectors, movementClassification: .walking)
        XCTAssertEqual(result.text, "Return to the opposite wall.")
        XCTAssertEqual(result.priority, .important)
    }

    func testRecommendationMarksCoverageCompleteWhenAllSectorsAreAdequate() {
        let sectors = CoverageSectorID.allCases.map {
            evidence($0, level: .adequate, saved: 7, angles: 2)
        }
        let result = recommendations.recommendation(for: sectors, movementClassification: .walking)
        XCTAssertEqual(result.text, "Coverage appears complete.")
        XCTAssertEqual(result.priority, .complete)
    }

    func testRotationInPlaceOverridesCoverageRecommendation() {
        let result = recommendations.recommendation(
            for: CoverageSummary.empty.sectors,
            movementClassification: .rotatingInPlace
        )
        XCTAssertEqual(result.text, "Continue one steady perimeter pass.")
        XCTAssertEqual(result.priority, .important)
    }

    private func evidence(
        _ sector: CoverageSectorID,
        level: CoverageEvidenceLevel,
        saved: Double,
        angles: Double
    ) -> CoverageEvidence {
        CoverageEvidence(
            sectorID: sector,
            title: sector.title,
            savedFrames: saved,
            newAngleFrames: angles,
            stableFrames: saved,
            viewChangeTotal: Double(angles),
            lastUpdatedAt: Date(),
            level: level,
            rationale: "test"
        )
    }
}

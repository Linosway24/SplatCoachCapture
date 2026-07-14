import XCTest
@testable import SplatCoachCapture

final class CoverageScoringAndRecommendationTests: XCTestCase {
    private let scoring = CoverageScoringEngine()
    private let start = Date(timeIntervalSince1970: 1_000)

    func testEvidenceThresholdsRequireAllInputsAtEachLevel() {
        XCTAssertEqual(scoring.level(savedFrames: 0, newAngleFrames: 0, stableFrames: 0, viewChangeTotal: 0), .none)
        XCTAssertEqual(scoring.level(savedFrames: 1, newAngleFrames: 0, stableFrames: 1, viewChangeTotal: 0), .sparse)
        XCTAssertEqual(scoring.level(savedFrames: 7, newAngleFrames: 2, stableFrames: 4, viewChangeTotal: 0), .adequate)
        XCTAssertEqual(scoring.level(savedFrames: 14, newAngleFrames: 5, stableFrames: 8, viewChangeTotal: 0), .strong)
        XCTAssertEqual(scoring.level(savedFrames: 14, newAngleFrames: 4, stableFrames: 8, viewChangeTotal: 0), .adequate)
    }

    func testCorrectiveCoachingDoesNotAppearImmediatelyAfterScanStart() {
        let engine = CoverageRecommendationEngine()
        let result = engine.recommendation(
            for: sectors(left: evidence(.leftSide, level: .none, saved: 0, angles: 0)),
            movementClassification: .walking,
            context: context(elapsed: 1, saved: 20, currentSector: .startWall)
        )

        XCTAssertEqual(result.phase, .startup)
        XCTAssertEqual(result.text, "Continue one steady perimeter pass.")
        XCTAssertNil(result.targetSector)
    }

    func testStartupRequiresTimeFramesAndThreeSectorsWithEvidence() {
        let engine = CoverageRecommendationEngine()
        let onlyTwoSectors = [
            evidence(.startWall, level: .adequate, saved: 7, angles: 2),
            evidence(.rightSide, level: .adequate, saved: 7, angles: 2),
            evidence(.oppositeWall, level: .none, saved: 0, angles: 0),
            evidence(.leftSide, level: .none, saved: 0, angles: 0)
        ]

        let result = engine.recommendation(
            for: onlyTwoSectors,
            movementClassification: .walking,
            context: context(elapsed: 20, saved: 30, currentSector: .startWall)
        )

        XCTAssertEqual(result.phase, .startup)
        XCTAssertEqual(result.key, "startup.perimeter-pass")
    }

    func testStartupDoesNotEndWhenElapsedTimeAndSectorDiversityHaveTooFewFrames() {
        let engine = CoverageRecommendationEngine()
        let threeSectorsWithEvidence = [
            evidence(.startWall, level: .sparse, saved: 1, angles: 0),
            evidence(.rightSide, level: .sparse, saved: 1, angles: 0),
            evidence(.oppositeWall, level: .sparse, saved: 1, angles: 0),
            evidence(.leftSide, level: .none, saved: 0, angles: 0)
        ]

        let result = engine.recommendation(
            for: threeSectorsWithEvidence,
            movementClassification: .walking,
            context: context(elapsed: 20, saved: 3, currentSector: .oppositeWall)
        )

        XCTAssertEqual(result.phase, .startup)
        XCTAssertEqual(result.text, "Continue one steady perimeter pass.")
    }

    func testSmallDeficitUsesFewMoreViewsLanguage() {
        let result = recommendationForLeftDeficit(
            evidence(.leftSide, level: .sparse, saved: 6.5, angles: 1.7, stable: 3.5)
        )

        XCTAssertEqual(result.deficitSeverity, .small)
        XCTAssertEqual(result.text, "Capture a few more views on the left side.")
    }

    func testModerateDeficitUsesContinueAlongLanguage() {
        let result = recommendationForLeftDeficit(
            evidence(.leftSide, level: .sparse, saved: 3, angles: 1, stable: 2)
        )

        XCTAssertEqual(result.deficitSeverity, .moderate)
        XCTAssertEqual(result.text, "Continue along the left side.")
    }

    func testLargeDeficitUsesAnotherPassLanguage() {
        let result = recommendationForLeftDeficit(
            evidence(.leftSide, level: .none, saved: 0, angles: 0, stable: 0)
        )

        XCTAssertEqual(result.deficitSeverity, .large)
        XCTAssertEqual(result.text, "Make another pass along the left side.")
    }

    func testEnteringTargetSectorAcknowledgesActiveCoverage() {
        let engine = CoverageRecommendationEngine()
        let evidence = sectors(
            left: self.evidence(.leftSide, level: .sparse, saved: 3, angles: 1, stable: 2)
        )
        _ = engine.recommendation(
            for: evidence,
            movementClassification: .walking,
            context: context(elapsed: 9, saved: 30, currentSector: .startWall)
        )
        let active = engine.recommendation(
            for: evidence,
            movementClassification: .walking,
            context: context(elapsed: 9.4, saved: 31, currentSector: .leftSide)
        )

        XCTAssertEqual(active.text, "Good—keep covering the left side.")
        XCTAssertEqual(active.targetSector, .leftSide)
        XCTAssertEqual(active.changeReason, "entered-target-sector")
    }

    func testSatisfyingTargetShowsImprovementAcknowledgement() {
        let engine = CoverageRecommendationEngine()
        _ = engine.recommendation(
            for: sectors(left: evidence(.leftSide, level: .sparse, saved: 3, angles: 1, stable: 2)),
            movementClassification: .walking,
            context: context(elapsed: 9, saved: 30, currentSector: .startWall)
        )
        let completed = engine.recommendation(
            for: sectors(left: evidence(.leftSide, level: .adequate, saved: 7, angles: 2, stable: 4)),
            movementClassification: .walking,
            context: context(elapsed: 10, saved: 34, currentSector: .leftSide)
        )

        XCTAssertEqual(completed.phase, .completed)
        XCTAssertEqual(completed.text, "Left-side coverage improved. Continue forward.")
        XCTAssertEqual(completed.changeReason, "target-satisfied")
    }

    func testCompletionAcknowledgementPersistsBrieflyBeforeNextGap() {
        let engine = CoverageRecommendationEngine()
        _ = engine.recommendation(
            for: sectors(left: evidence(.leftSide, level: .sparse, saved: 3, angles: 1, stable: 2)),
            movementClassification: .walking,
            context: context(elapsed: 9, saved: 30, currentSector: .startWall)
        )
        let rightGap = [
            evidence(.startWall, level: .adequate, saved: 7, angles: 2),
            evidence(.rightSide, level: .sparse, saved: 3, angles: 1, stable: 2),
            evidence(.oppositeWall, level: .adequate, saved: 7, angles: 2),
            evidence(.leftSide, level: .adequate, saved: 7, angles: 2)
        ]
        _ = engine.recommendation(
            for: rightGap,
            movementClassification: .walking,
            context: context(elapsed: 10, saved: 34, currentSector: .leftSide)
        )
        let duringAcknowledgement = engine.recommendation(
            for: rightGap,
            movementClassification: .walking,
            context: context(elapsed: 11.5, saved: 35, currentSector: .startWall)
        )
        let afterward = engine.recommendation(
            for: rightGap,
            movementClassification: .walking,
            context: context(elapsed: 12.1, saved: 36, currentSector: .startWall)
        )

        XCTAssertEqual(duringAcknowledgement.phase, .completed)
        XCTAssertEqual(afterward.phase, .correcting)
        XCTAssertEqual(afterward.targetSector, .rightSide)
    }

    func testRecommendationDoesNotAlternateBetweenSimilarWeakSectors() {
        let engine = CoverageRecommendationEngine()
        let first = [
            evidence(.startWall, level: .adequate, saved: 7, angles: 2),
            evidence(.rightSide, level: .sparse, saved: 3, angles: 1, stable: 2),
            evidence(.oppositeWall, level: .adequate, saved: 7, angles: 2),
            evidence(.leftSide, level: .sparse, saved: 3.2, angles: 1.1, stable: 2.1)
        ]
        let second = [
            evidence(.startWall, level: .adequate, saved: 7, angles: 2),
            evidence(.rightSide, level: .sparse, saved: 3.2, angles: 1.1, stable: 2.1),
            evidence(.oppositeWall, level: .adequate, saved: 7, angles: 2),
            evidence(.leftSide, level: .sparse, saved: 3, angles: 1, stable: 2)
        ]

        let initial = engine.recommendation(
            for: first,
            movementClassification: .walking,
            context: context(elapsed: 9, saved: 30, currentSector: .startWall)
        )
        let retained = engine.recommendation(
            for: second,
            movementClassification: .walking,
            context: context(elapsed: 9.4, saved: 31, currentSector: .startWall)
        )

        XCTAssertEqual(initial.targetSector, .rightSide)
        XCTAssertEqual(retained.targetSector, .rightSide)
    }

    func testRecommendationMarksCoverageCompleteWhenAllSectorsAreAdequate() {
        let engine = CoverageRecommendationEngine()
        let allAdequate = CoverageSectorID.allCases.map {
            evidence($0, level: .adequate, saved: 7, angles: 2)
        }
        let result = engine.recommendation(
            for: allAdequate,
            movementClassification: .walking,
            context: context(elapsed: 9, saved: 28, currentSector: .startWall)
        )

        XCTAssertEqual(result.text, "Coverage appears complete.")
        XCTAssertEqual(result.priority, .complete)
    }

    func testRotationInPlaceRetainsPerimeterInstructionAfterStartup() {
        let engine = CoverageRecommendationEngine()
        let result = engine.recommendation(
            for: sectors(left: evidence(.leftSide, level: .none, saved: 0, angles: 0)),
            movementClassification: .rotatingInPlace,
            context: context(elapsed: 9, saved: 30, currentSector: .startWall)
        )

        XCTAssertEqual(result.text, "Continue one steady perimeter pass.")
        XCTAssertEqual(result.priority, .important)
        XCTAssertEqual(result.phase, .normal)
    }

    private func recommendationForLeftDeficit(_ left: CoverageEvidence) -> CoverageRecommendation {
        CoverageRecommendationEngine().recommendation(
            for: sectors(left: left),
            movementClassification: .walking,
            context: context(elapsed: 9, saved: 30, currentSector: .startWall)
        )
    }

    private func sectors(left: CoverageEvidence) -> [CoverageEvidence] {
        [
            evidence(.startWall, level: .adequate, saved: 7, angles: 2),
            evidence(.rightSide, level: .adequate, saved: 7, angles: 2),
            evidence(.oppositeWall, level: .adequate, saved: 7, angles: 2),
            left
        ]
    }

    private func context(
        elapsed: TimeInterval,
        saved: Int,
        currentSector: CoverageSectorID?
    ) -> CoverageCoachingContext {
        CoverageCoachingContext(
            timestamp: start.addingTimeInterval(elapsed),
            scanStartedAt: start,
            savedFrameCount: saved,
            currentSector: currentSector
        )
    }

    private func evidence(
        _ sector: CoverageSectorID,
        level: CoverageEvidenceLevel,
        saved: Double,
        angles: Double,
        stable: Double? = nil
    ) -> CoverageEvidence {
        CoverageEvidence(
            sectorID: sector,
            title: sector.title,
            savedFrames: saved,
            newAngleFrames: angles,
            stableFrames: stable ?? saved,
            viewChangeTotal: Double(angles),
            lastUpdatedAt: start,
            level: level,
            rationale: "test"
        )
    }
}

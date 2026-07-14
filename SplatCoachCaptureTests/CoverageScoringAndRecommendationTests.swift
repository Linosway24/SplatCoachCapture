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
        _ = engine.recommendation(
            for: evidence,
            movementClassification: .walking,
            context: context(elapsed: 9.4, saved: 30, currentSector: .leftSide)
        )
        let active = engine.recommendation(
            for: evidence,
            movementClassification: .walking,
            context: context(elapsed: 10.5, saved: 31, currentSector: .leftSide)
        )

        XCTAssertEqual(active.text, "Good—keep covering the left side.")
        XCTAssertEqual(active.targetSector, .leftSide)
        XCTAssertEqual(active.changeReason, "target-entry-debounced")
    }

    func testTargetEntryRequiresContinuousDwell() {
        let engine = CoverageRecommendationEngine()
        let leftGap = sectors(
            left: evidence(.leftSide, level: .sparse, saved: 3, angles: 1, stable: 2)
        )
        _ = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 9, saved: 30, currentSector: .startWall)
        )
        let pending = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 9.2, saved: 30, currentSector: .leftSide)
        )
        let stillPending = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 10.1, saved: 30, currentSector: .leftSide)
        )
        let entered = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 10.2, saved: 30, currentSector: .leftSide)
        )

        XCTAssertEqual(pending.text, "Continue along the left side.")
        XCTAssertEqual(stillPending.text, "Continue along the left side.")
        XCTAssertEqual(entered.text, "Good—keep covering the left side.")
        XCTAssertTrue(engine.diagnosticState.debouncedInTarget)
    }

    func testBriefBoundaryCrossingsDoNotOscillateCoaching() {
        let engine = CoverageRecommendationEngine()
        let leftGap = sectors(
            left: evidence(.leftSide, level: .sparse, saved: 3, angles: 1, stable: 2)
        )
        _ = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 9, saved: 30, currentSector: .startWall)
        )
        _ = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 9.1, saved: 30, currentSector: .leftSide)
        )
        let active = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 10.1, saved: 30, currentSector: .leftSide)
        )
        let boundaryCrossing = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 10.3, saved: 30, currentSector: .oppositeWall)
        )
        let returned = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 10.8, saved: 30, currentSector: .leftSide)
        )

        XCTAssertEqual(active.key, "correcting.leftSide.active")
        XCTAssertEqual(boundaryCrossing.key, "correcting.leftSide.active")
        XCTAssertEqual(returned.key, "correcting.leftSide.active")
        XCTAssertEqual(engine.changeHistory.filter { $0.reason == "target-exit-debounced" }.count, 0)
    }

    func testTargetExitRequiresContinuousDwell() {
        let engine = CoverageRecommendationEngine()
        let leftGap = sectors(
            left: evidence(.leftSide, level: .sparse, saved: 3, angles: 1, stable: 2)
        )
        _ = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 9, saved: 30, currentSector: .startWall)
        )
        _ = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 9.1, saved: 30, currentSector: .leftSide)
        )
        _ = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 10.1, saved: 30, currentSector: .leftSide)
        )
        let pendingExit = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 10.2, saved: 30, currentSector: .oppositeWall)
        )
        let stillInside = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 11.6, saved: 30, currentSector: .oppositeWall)
        )
        let exited = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 11.7, saved: 30, currentSector: .oppositeWall)
        )

        XCTAssertEqual(pendingExit.key, "correcting.leftSide.active")
        XCTAssertEqual(stillInside.key, "correcting.leftSide.active")
        XCTAssertEqual(exited.text, "Continue along the left side.")
        XCTAssertEqual(exited.changeReason, "target-exit-debounced")
        XCTAssertFalse(engine.diagnosticState.debouncedInTarget)
    }

    func testImprovingEvidenceSuppressesRepeatedDirectionalGuidance() {
        let engine = CoverageRecommendationEngine()
        let initial = sectors(
            left: evidence(.leftSide, level: .sparse, saved: 3, angles: 1, stable: 2)
        )
        let improved = sectors(
            left: evidence(.leftSide, level: .sparse, saved: 3.5, angles: 1.2, stable: 2.5)
        )
        _ = engine.recommendation(
            for: initial,
            movementClassification: .walking,
            context: context(elapsed: 9, saved: 30, currentSector: .startWall)
        )
        _ = engine.recommendation(
            for: initial,
            movementClassification: .walking,
            context: context(elapsed: 9.1, saved: 30, currentSector: .leftSide)
        )
        let improving = engine.recommendation(
            for: improved,
            movementClassification: .walking,
            context: context(elapsed: 10.1, saved: 31, currentSector: .leftSide)
        )
        let boundaryJitter = engine.recommendation(
            for: improved,
            movementClassification: .walking,
            context: context(elapsed: 10.4, saved: 31, currentSector: .oppositeWall)
        )
        let quiet = engine.recommendation(
            for: improved,
            movementClassification: .walking,
            context: context(elapsed: 12.2, saved: 31, currentSector: .leftSide)
        )

        XCTAssertEqual(improving.text, "Good—left-side coverage is improving.")
        XCTAssertEqual(boundaryJitter.text, "Good—left-side coverage is improving.")
        XCTAssertEqual(quiet.text, "Keep moving to new viewpoints.")
        XCTAssertTrue(engine.diagnosticState.progressImproving)
        XCTAssertGreaterThanOrEqual(engine.diagnosticState.targetEvidenceDelta, 0.05)
    }

    func testStalledEvidenceRestoresDirectionalGuidance() {
        let engine = CoverageRecommendationEngine()
        let leftGap = sectors(
            left: evidence(.leftSide, level: .sparse, saved: 3, angles: 1, stable: 2)
        )
        _ = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 9, saved: 30, currentSector: .startWall)
        )
        _ = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 9.1, saved: 30, currentSector: .leftSide)
        )
        _ = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 10.1, saved: 30, currentSector: .leftSide)
        )
        let stalled = engine.recommendation(
            for: leftGap,
            movementClassification: .walking,
            context: context(elapsed: 13.1, saved: 30, currentSector: .leftSide)
        )

        XCTAssertEqual(stalled.text, "Continue along the left side.")
        XCTAssertTrue(engine.diagnosticState.progressStalled)
        XCTAssertEqual(
            engine.diagnosticState.guidanceDecisionReason,
            "directional-guidance-repeated-target-evidence-stalled"
        )
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

//
//  CoverageManager.swift
//  SplatCoachCapture
//
//  Created by OpenAI on 7/8/26.
//

import Combine
import CoreMotion
import Foundation

@MainActor
final class CoverageManager: ObservableObject {
    @Published private(set) var summary: CoverageSummary = .empty

    private let sectorEvaluator = CoverageSectorEvaluator()
    private let scoringEngine = CoverageScoringEngine()
    private let recommendationEngine = CoverageRecommendationEngine()
    private var startingYawRadians: Double?
    private var lastSavedFrameCount = 0
    private var lastSavedNewAngleCount = 0
    private var samples: [CoverageSample] = []
    private var lastMovementClassification: MovementClassification = .unknown

    func startScan(initialAttitude: CMAttitude?) {
        startingYawRadians = initialAttitude?.yaw
        lastSavedFrameCount = 0
        lastSavedNewAngleCount = 0
        samples = []
        lastMovementClassification = .unknown
        summary = makeSummary()
    }

    func stopScan() {
        summary = makeSummary()
    }

    func reset() {
        startingYawRadians = nil
        lastSavedFrameCount = 0
        lastSavedNewAngleCount = 0
        samples = []
        lastMovementClassification = .unknown
        summary = .empty
    }

    func update(with telemetry: CoverageTelemetry) {
        guard telemetry.isScanning else { return }
        lastMovementClassification = telemetry.movementClassification

        if startingYawRadians == nil, let yaw = telemetry.yawRadians {
            startingYawRadians = yaw
        }

        let savedDelta = max(telemetry.savedFrameCount - lastSavedFrameCount, 0)
        let newAngleDelta = max(telemetry.savedNewAngleCount - lastSavedNewAngleCount, 0)
        lastSavedFrameCount = telemetry.savedFrameCount
        lastSavedNewAngleCount = telemetry.savedNewAngleCount

        guard savedDelta > 0 || newAngleDelta > 0 else {
            return
        }

        guard let yaw = telemetry.yawRadians, let origin = startingYawRadians else {
            return
        }

        let sample = CoverageSample(
            timestamp: telemetry.timestamp,
            sectorID: sectorEvaluator.sector(for: yaw - origin),
            savedFrameDelta: savedDelta,
            newAngleDelta: newAngleDelta,
            isStable: telemetry.currentScanHealth == .capturing || telemetry.currentScanHealth == .coach,
            movementClassification: telemetry.movementClassification,
            viewChangeScore: telemetry.viewChangeScore.isFinite ? telemetry.viewChangeScore : 0
        )

        samples.append(sample)
        summary = makeSummary()
    }

    private func makeSummary() -> CoverageSummary {
        let sectorEvidence = CoverageSectorID.allCases.map { sectorID in
            evidence(for: sectorID)
        }
        return CoverageSummary(
            sectors: sectorEvidence,
            recommendation: recommendationEngine.recommendation(
                for: sectorEvidence,
                movementClassification: lastMovementClassification
            )
        )
    }

    private func evidence(for sectorID: CoverageSectorID) -> CoverageEvidence {
        let sectorSamples = samples.filter { $0.sectorID == sectorID }
        let weightedSamples = sectorSamples.map(weightedSample)
        let savedFrames = weightedSamples.reduce(0) { $0 + $1.savedFrames }
        let newAngleFrames = weightedSamples.reduce(0) { $0 + $1.newAngleFrames }
        let stableFrames = weightedSamples.reduce(0) { $0 + $1.stableFrames }
        let viewChangeTotal = weightedSamples.reduce(0) { $0 + $1.viewChange }
        let level = scoringEngine.level(
            savedFrames: savedFrames,
            newAngleFrames: newAngleFrames,
            stableFrames: stableFrames,
            viewChangeTotal: viewChangeTotal
        )

        return CoverageEvidence(
            sectorID: sectorID,
            title: sectorID.title,
            savedFrames: savedFrames,
            newAngleFrames: newAngleFrames,
            stableFrames: stableFrames,
            viewChangeTotal: viewChangeTotal,
            lastUpdatedAt: sectorSamples.last?.timestamp,
            level: level,
            rationale: scoringEngine.rationale(
                level: level,
                savedFrames: savedFrames,
                newAngleFrames: newAngleFrames,
                stableFrames: stableFrames,
                viewChangeTotal: viewChangeTotal
            )
        )
    }

    private func weightedSample(_ sample: CoverageSample) -> (
        savedFrames: Int,
        newAngleFrames: Int,
        stableFrames: Int,
        viewChange: Double
    ) {
        let movementWeight: Double
        switch sample.movementClassification {
        case .walking:
            movementWeight = 1.0
        case .smallAreaPacing:
            movementWeight = 0.45
        case .unknown:
            movementWeight = 0.3
        case .stopped:
            movementWeight = 0.15
        case .rotatingInPlace:
            movementWeight = 0.08
        }

        return (
            savedFrames: Int((Double(sample.savedFrameDelta) * movementWeight).rounded()),
            newAngleFrames: Int((Double(sample.newAngleDelta) * movementWeight).rounded()),
            stableFrames: sample.isStable ? Int((Double(sample.savedFrameDelta) * movementWeight).rounded()) : 0,
            viewChange: sample.viewChangeScore * movementWeight
        )
    }

    var diagnostics: CoverageDiagnostics {
        CoverageDiagnostics(
            methodology: CoverageTuning.methodology,
            assumptions: CoverageTuning.assumptions,
            thresholds: .current,
            summary: summary
        )
    }
}

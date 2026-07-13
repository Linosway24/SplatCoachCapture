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
    private var frameDiagnostics: [CoverageFrameDiagnostic] = []
    private var lastMovementClassification: MovementClassification = .unknown

    func startScan(initialAttitude: CMAttitude?) {
        startingYawRadians = initialAttitude?.yaw
        lastSavedFrameCount = 0
        lastSavedNewAngleCount = 0
        samples = []
        frameDiagnostics = []
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
        frameDiagnostics = []
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
        let movementWeight = Self.evidenceWeight(for: sample.movementClassification)

        return (
            savedFrames: Int((Double(sample.savedFrameDelta) * movementWeight).rounded()),
            newAngleFrames: Int((Double(sample.newAngleDelta) * movementWeight).rounded()),
            stableFrames: sample.isStable ? Int((Double(sample.savedFrameDelta) * movementWeight).rounded()) : 0,
            viewChange: sample.viewChangeScore * movementWeight
        )
    }

    func recordFrameDiagnostic(
        frameNumber: Int,
        timestamp: Date,
        absoluteYawRadians: Double?,
        outcome: String,
        exclusionReason: String?,
        viewChangeScore: Double?,
        movementClassification: MovementClassification,
        scanHealth: ScanHealthState
    ) {
        let yaw = absoluteYawRadians.flatMap { $0.isFinite ? $0 : nil }
        let relativeYaw = yaw.flatMap { yaw in
            startingYawRadians.map { yaw - $0 }
        }
        let normalizedYaw = relativeYaw.map(sectorEvaluator.normalizedDegrees(for:))
        let assignedSector = relativeYaw.map(sectorEvaluator.sector(for:))
        let boundary = assignedSector.flatMap(sectorEvaluator.boundary(for:))
        let saved = outcome.hasPrefix("saved-")

        frameDiagnostics.append(
            CoverageFrameDiagnostic(
                frameNumber: frameNumber,
                timestamp: timestamp,
                absoluteYawRadians: yaw,
                absoluteYawDegrees: yaw.map { $0 * 180.0 / .pi },
                startYawRadians: startingYawRadians,
                startYawDegrees: startingYawRadians.map { $0 * 180.0 / .pi },
                startRelativeYawRadians: relativeYaw,
                startRelativeYawDegrees: relativeYaw.map { $0 * 180.0 / .pi },
                normalizedYawDegrees: normalizedYaw,
                assignedSector: assignedSector,
                assignedSectorStartDegrees: boundary?.startDegrees,
                assignedSectorEndDegrees: boundary?.endDegrees,
                saved: saved,
                excluded: !saved,
                exclusionReason: saved ? nil : exclusionReason ?? outcome,
                evidenceWeight: Self.evidenceWeight(for: movementClassification),
                viewChangeScore: viewChangeScore.flatMap { $0.isFinite ? $0 : nil },
                newAngleDecision: saved && outcome.contains("new-angle"),
                overlapDecision: saved && outcome.contains("overlap"),
                movementClassification: movementClassification,
                scanHealth: scanHealth.rawValue
            )
        )
    }

    static func evidenceWeight(for movementClassification: MovementClassification) -> Double {
        switch movementClassification {
        case .walking: 1.0
        case .smallAreaPacing: 0.45
        case .unknown: 0.3
        case .stopped: 0.15
        case .rotatingInPlace: 0.08
        }
    }

    var diagnostics: CoverageDiagnostics {
        CoverageDiagnostics(
            methodology: CoverageTuning.methodology,
            assumptions: CoverageTuning.assumptions,
            thresholds: .current,
            sectorBoundaries: sectorEvaluator.sectors,
            controlledTestProcedure: CoverageTuning.controlledTestProcedure,
            summary: summary,
            perFrame: frameDiagnostics
        )
    }
}

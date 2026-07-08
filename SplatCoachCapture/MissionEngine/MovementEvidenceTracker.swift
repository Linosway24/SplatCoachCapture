//
//  MovementEvidenceTracker.swift
//  SplatCoachCapture
//
//  Created by OpenAI on 7/8/26.
//

import Foundation

struct MovementEvidenceSnapshot: Equatable {
    static let empty = MovementEvidenceSnapshot(
        recentLinearMotionImpulse: 0,
        recentRotationImpulse: 0,
        rotationDominance: 0,
        movementClassification: .unknown,
        translationEvidenceLevel: .none
    )

    let recentLinearMotionImpulse: Double
    let recentRotationImpulse: Double
    let rotationDominance: Double
    let movementClassification: MovementClassification
    let translationEvidenceLevel: MissionEvidenceLevel
}

struct MovementEvidenceTracker {
    private struct Sample {
        let timestamp: Date
        let linearAccelerationMagnitude: Double
        let rotationRateMagnitude: Double
        let attitudeRotationDelta: Double
        let savedFrameCount: Int
        let savedNewAngleCount: Int
        let viewChangeScore: Double?
    }

    private let windowDuration: TimeInterval = 7.0
    private var samples: [Sample] = []

    mutating func reset() {
        samples.removeAll()
    }

    mutating func record(
        timestamp: Date,
        linearAccelerationMagnitude: Double,
        rotationRateMagnitude: Double,
        attitudeRotationDelta: Double,
        savedFrameCount: Int,
        savedNewAngleCount: Int,
        viewChangeScore: Double?
    ) -> MovementEvidenceSnapshot {
        let sample = Sample(
            timestamp: timestamp,
            linearAccelerationMagnitude: linearAccelerationMagnitude.finiteOrZero,
            rotationRateMagnitude: rotationRateMagnitude.finiteOrZero,
            attitudeRotationDelta: attitudeRotationDelta.finiteOrZero,
            savedFrameCount: savedFrameCount,
            savedNewAngleCount: savedNewAngleCount,
            viewChangeScore: viewChangeScore.flatMap { $0.isFinite ? $0 : nil }
        )
        samples.append(sample)
        samples.removeAll { timestamp.timeIntervalSince($0.timestamp) > windowDuration }
        return snapshot()
    }

    func snapshot() -> MovementEvidenceSnapshot {
        guard samples.count >= 6, let first = samples.first, let last = samples.last else {
            return .empty
        }

        let duration = max(last.timestamp.timeIntervalSince(first.timestamp), 0.1)
        let linearImpulse = average(\.linearAccelerationMagnitude) * duration
        let rotationImpulse = average(\.rotationRateMagnitude) * duration
        let attitudeChange = samples.map(\.attitudeRotationDelta).filter(\.isFinite).max() ?? 0
        let linearPulseFraction = fraction { $0.linearAccelerationMagnitude >= 0.045 }
        let rotationBurstFraction = fraction { $0.rotationRateMagnitude >= 0.22 }
        let rotationDominance = rotationImpulse / max(linearImpulse + rotationImpulse, 0.001)
        let savedGrowth = max(last.savedFrameCount - first.savedFrameCount, 0)
        let newAngleGrowth = max(last.savedNewAngleCount - first.savedNewAngleCount, 0)
        let averageViewChange = samples.compactMap(\.viewChangeScore).averageValue

        let classification = classify(
            duration: duration,
            linearImpulse: linearImpulse,
            rotationImpulse: rotationImpulse,
            attitudeChange: attitudeChange,
            linearPulseFraction: linearPulseFraction,
            rotationBurstFraction: rotationBurstFraction,
            savedGrowth: savedGrowth,
            newAngleGrowth: newAngleGrowth,
            averageViewChange: averageViewChange
        )

        return MovementEvidenceSnapshot(
            recentLinearMotionImpulse: linearImpulse,
            recentRotationImpulse: max(rotationImpulse, attitudeChange),
            rotationDominance: rotationDominance,
            movementClassification: classification,
            translationEvidenceLevel: evidenceLevel(
                for: classification,
                linearImpulse: linearImpulse,
                savedGrowth: savedGrowth,
                newAngleGrowth: newAngleGrowth
            )
        )
    }

    private func classify(
        duration: TimeInterval,
        linearImpulse: Double,
        rotationImpulse: Double,
        attitudeChange: Double,
        linearPulseFraction: Double,
        rotationBurstFraction: Double,
        savedGrowth: Int,
        newAngleGrowth: Int,
        averageViewChange: Double
    ) -> MovementClassification {
        guard duration >= 1.5 else { return .unknown }

        let rotationEvidence = max(rotationImpulse, attitudeChange)
        let hasLinearMovement = linearImpulse >= 0.36
        let hasSustainedLinearMovement = linearImpulse >= 0.7
        let hasRotation = rotationEvidence >= 1.1
        let hasStrongRotation = rotationEvidence >= 2.0
        let isProducingViews = newAngleGrowth >= 2 || averageViewChange >= CaptureTuning.minimumOverlapViewChangeScore
        let isSaving = savedGrowth >= 2
        let hasRepeatedLinearPulses = linearPulseFraction >= 0.18
        let hasSustainedRotation = rotationBurstFraction >= 0.45
        let hasRotationBurst = rotationBurstFraction >= 0.12

        if !hasLinearMovement, !hasRepeatedLinearPulses, !hasRotation, !isSaving {
            return .stopped
        }

        if hasSustainedRotation, !hasRepeatedLinearPulses, linearImpulse < 0.28, isProducingViews {
            return .rotatingInPlace
        }

        if hasSustainedLinearMovement, isSaving, newAngleGrowth <= 1, averageViewChange < CaptureTuning.minimumOverlapViewChangeScore * 0.55 {
            return .smallAreaPacing
        }

        if (hasSustainedLinearMovement || hasRepeatedLinearPulses), isSaving, isProducingViews {
            return .walking
        }

        if hasRepeatedLinearPulses, isSaving, hasRotationBurst, !hasSustainedRotation {
            return .walking
        }

        if hasLinearMovement, !hasSustainedRotation {
            return .walking
        }

        if hasStrongRotation, hasSustainedRotation, linearImpulse < rotationEvidence * 0.18 {
            return .rotatingInPlace
        }

        return .unknown
    }

    private func evidenceLevel(
        for classification: MovementClassification,
        linearImpulse: Double,
        savedGrowth: Int,
        newAngleGrowth: Int
    ) -> MissionEvidenceLevel {
        switch classification {
        case .walking:
            if linearImpulse >= 1.1, savedGrowth >= 4, newAngleGrowth >= 2 {
                return .strong
            }
            return .steady
        case .smallAreaPacing:
            return .building
        case .rotatingInPlace, .stopped, .unknown:
            return .none
        }
    }

    private func average(_ keyPath: KeyPath<Sample, Double>) -> Double {
        let values = samples.map { $0[keyPath: keyPath] }.filter(\.isFinite)
        return values.averageValue
    }

    private func fraction(where predicate: (Sample) -> Bool) -> Double {
        guard !samples.isEmpty else { return 0 }
        let count = samples.filter(predicate).count
        return Double(count) / Double(samples.count)
    }
}

private extension Double {
    var finiteOrZero: Double {
        isFinite ? self : 0
    }
}

private extension Array where Element == Double {
    var averageValue: Double {
        guard !isEmpty else { return 0 }
        return reduce(0, +) / Double(count)
    }
}

//
//  CoverageRecommendationEngine.swift
//  SplatCoachCapture
//
//  Created by OpenAI on 7/8/26.
//

import Foundation

struct CoverageCoachingContext: Equatable {
    let timestamp: Date
    let scanStartedAt: Date
    let savedFrameCount: Int
    let currentSector: CoverageSectorID?
}

final class CoverageRecommendationEngine {
    private(set) var changeHistory: [CoverageCoachingChange] = []

    private var hasExitedStartup = false
    private var currentTarget: CoverageSectorID?
    private var completedTarget: CoverageSectorID?
    private var completionStartedAt: Date?
    private var currentRecommendation: CoverageRecommendation?

    func reset() {
        changeHistory = []
        hasExitedStartup = false
        currentTarget = nil
        completedTarget = nil
        completionStartedAt = nil
        currentRecommendation = nil
    }

    func recommendation(
        for sectors: [CoverageEvidence],
        movementClassification: MovementClassification,
        context: CoverageCoachingContext
    ) -> CoverageRecommendation {
        if !hasExitedStartup {
            guard startupEvidenceIsReady(sectors: sectors, context: context) else {
                return publish(
                    text: "Continue one steady perimeter pass.",
                    priority: .normal,
                    phase: .startup,
                    target: nil,
                    severity: nil,
                    key: "startup.perimeter-pass",
                    defaultReason: "scan-started",
                    at: context.timestamp
                )
            }
            hasExitedStartup = true
        }

        if let completedTarget, let completionStartedAt {
            let elapsed = context.timestamp.timeIntervalSince(completionStartedAt)
            if elapsed < CoverageTuning.coachingCompletionAcknowledgementDuration {
                return completionRecommendation(for: completedTarget, at: context.timestamp)
            }
            self.completedTarget = nil
            self.completionStartedAt = nil
        }

        if let target = currentTarget,
           let evidence = sectors.first(where: { $0.sectorID == target }) {
            if evidence.level >= .adequate {
                currentTarget = nil
                completedTarget = target
                completionStartedAt = context.timestamp
                return completionRecommendation(for: target, at: context.timestamp)
            }

            return correctionRecommendation(
                for: evidence,
                currentSector: context.currentSector,
                defaultReason: context.currentSector == target
                    ? "target-sector-active"
                    : "target-retained",
                at: context.timestamp
            )
        }

        if movementClassification == .rotatingInPlace {
            return publish(
                text: "Continue one steady perimeter pass.",
                priority: .important,
                phase: .normal,
                target: nil,
                severity: nil,
                key: "normal.perimeter-pass",
                defaultReason: "rotation-in-place",
                at: context.timestamp
            )
        }

        if sectors.allSatisfy({ $0.level >= .adequate }) {
            return publish(
                text: "Coverage appears complete.",
                priority: .complete,
                phase: .completed,
                target: nil,
                severity: nil,
                key: "completed.all-sectors",
                defaultReason: "coverage-complete",
                at: context.timestamp
            )
        }

        guard let weakest = weakestSector(in: sectors) else {
            return publish(
                text: "Continue one steady perimeter pass.",
                priority: .normal,
                phase: .normal,
                target: nil,
                severity: nil,
                key: "normal.perimeter-pass",
                defaultReason: "no-actionable-deficit",
                at: context.timestamp
            )
        }

        currentTarget = weakest.sectorID
        return correctionRecommendation(
            for: weakest,
            currentSector: context.currentSector,
            defaultReason: "target-selected",
            at: context.timestamp
        )
    }

    private func startupEvidenceIsReady(
        sectors: [CoverageEvidence],
        context: CoverageCoachingContext
    ) -> Bool {
        let elapsed = context.timestamp.timeIntervalSince(context.scanStartedAt)
        let sectorsWithEvidence = sectors.filter { $0.level != .none }.count
        return elapsed >= CoverageTuning.coachingStartupMinimumDuration &&
            context.savedFrameCount >= CoverageTuning.coachingStartupMinimumSavedFrames &&
            sectorsWithEvidence >= CoverageTuning.coachingStartupMinimumSectorsWithEvidence
    }

    private func weakestSector(in sectors: [CoverageEvidence]) -> CoverageEvidence? {
        sectors
            .filter { $0.level < .adequate }
            .sorted {
                if $0.level != $1.level { return $0.level < $1.level }
                let lhsProgress = adequacyProgress(for: $0)
                let rhsProgress = adequacyProgress(for: $1)
                if lhsProgress != rhsProgress { return lhsProgress < rhsProgress }
                if $0.newAngleFrames != $1.newAngleFrames {
                    return $0.newAngleFrames < $1.newAngleFrames
                }
                return ($0.lastUpdatedAt ?? .distantPast) < ($1.lastUpdatedAt ?? .distantPast)
            }
            .first
    }

    private func correctionRecommendation(
        for evidence: CoverageEvidence,
        currentSector: CoverageSectorID?,
        defaultReason: String,
        at timestamp: Date
    ) -> CoverageRecommendation {
        let severity = deficitSeverity(for: evidence)
        let location = evidence.sectorID.coachingLocation

        if currentSector == evidence.sectorID {
            return publish(
                text: "Good—keep covering \(location).",
                priority: .important,
                phase: .correcting,
                target: evidence.sectorID,
                severity: severity,
                key: "correcting.\(evidence.sectorID.rawValue).active",
                defaultReason: defaultReason,
                at: timestamp
            )
        }

        let text: String
        switch severity {
        case .small:
            text = "Capture a few more views on \(location)."
        case .moderate:
            text = "Continue along \(location)."
        case .large:
            text = "Make another pass along \(location)."
        }

        return publish(
            text: text,
            priority: .important,
            phase: .correcting,
            target: evidence.sectorID,
            severity: severity,
            key: "correcting.\(evidence.sectorID.rawValue).\(severity.rawValue)",
            defaultReason: defaultReason,
            at: timestamp
        )
    }

    private func completionRecommendation(
        for sector: CoverageSectorID,
        at timestamp: Date
    ) -> CoverageRecommendation {
        publish(
            text: "\(sector.coachingCompletionSubject) coverage improved. Continue forward.",
            priority: .complete,
            phase: .completed,
            target: sector,
            severity: nil,
            key: "completed.\(sector.rawValue).improved",
            defaultReason: "target-satisfied",
            at: timestamp
        )
    }

    private func deficitSeverity(for evidence: CoverageEvidence) -> CoverageDeficitSeverity {
        if evidence.level == .none || evidence.savedFrames == 0 {
            return .large
        }
        return adequacyProgress(for: evidence) >= CoverageTuning.coachingSmallDeficitMinimumProgress
            ? .small
            : .moderate
    }

    private func adequacyProgress(for evidence: CoverageEvidence) -> Double {
        min(
            evidence.savedFrames / Double(CoverageTuning.adequateSavedFrames),
            evidence.newAngleFrames / Double(CoverageTuning.adequateNewAngleFrames),
            evidence.stableFrames / Double(CoverageTuning.adequateStableFrames),
            1
        )
    }

    private func publish(
        text: String,
        priority: CoverageRecommendationPriority,
        phase: CoverageCoachingPhase,
        target: CoverageSectorID?,
        severity: CoverageDeficitSeverity?,
        key: String,
        defaultReason: String,
        at timestamp: Date
    ) -> CoverageRecommendation {
        if let currentRecommendation,
           currentRecommendation.text == text,
           currentRecommendation.priority == priority,
           currentRecommendation.phase == phase,
           currentRecommendation.targetSector == target,
           currentRecommendation.deficitSeverity == severity,
           currentRecommendation.key == key {
            return currentRecommendation
        }

        let reason = changeReason(
            from: currentRecommendation,
            toPhase: phase,
            target: target,
            severity: severity,
            key: key,
            fallback: defaultReason
        )
        let recommendation = CoverageRecommendation(
            text: text,
            priority: priority,
            phase: phase,
            targetSector: target,
            deficitSeverity: severity,
            key: key,
            changeReason: reason,
            changedAt: timestamp
        )
        currentRecommendation = recommendation
        changeHistory.append(
            CoverageCoachingChange(
                phase: phase,
                targetSector: target,
                deficitSeverity: severity,
                recommendationText: text,
                recommendationKey: key,
                reason: reason,
                timestamp: timestamp
            )
        )
        return recommendation
    }

    private func changeReason(
        from previous: CoverageRecommendation?,
        toPhase phase: CoverageCoachingPhase,
        target: CoverageSectorID?,
        severity: CoverageDeficitSeverity?,
        key: String,
        fallback: String
    ) -> String {
        guard let previous else { return fallback }
        if previous.phase == .startup, phase != .startup { return "startup-evidence-ready" }
        if phase == .completed, target == previous.targetSector { return "target-satisfied" }
        if previous.targetSector != target { return "target-changed" }
        if previous.key.hasSuffix(".active"), !key.hasSuffix(".active") { return "left-target-sector" }
        if !previous.key.hasSuffix(".active"), key.hasSuffix(".active") { return "entered-target-sector" }
        if previous.deficitSeverity != severity { return "deficit-severity-changed" }
        return fallback
    }
}

private extension CoverageSectorID {
    var coachingLocation: String {
        switch self {
        case .startWall: "the start wall"
        case .rightSide: "the right side"
        case .oppositeWall: "the opposite wall"
        case .leftSide: "the left side"
        }
    }

    var coachingCompletionSubject: String {
        switch self {
        case .startWall: "Start-wall"
        case .rightSide: "Right-side"
        case .oppositeWall: "Opposite-wall"
        case .leftSide: "Left-side"
        }
    }
}
